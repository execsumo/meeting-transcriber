import AVFoundation
import Accelerate
import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Dictation")

/// Thread-safe audio sample buffer for real-time capture.
final class ThreadSafeAudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.withLock { samples.append(contentsOf: newSamples) }
    }

    func getAll() -> [Float] {
        lock.withLock { samples }
    }

    func count() -> Int {
        lock.withLock { samples.count }
    }

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }
}

/// Orchestrates mic capture, streaming transcription, and text insertion for dictation.
///
/// Uses a dual-manager pattern:
/// - Streaming manager (lightweight, no vocab boost) for real-time partial results
/// - Final manager (with vocab boost) for accurate end-of-dictation transcription
@MainActor
@Observable
final class DictationService {
    enum State: String {
        case idle
        case recording
        case finalizing
    }

    // MARK: - Public State

    private(set) var state: State = .idle
    /// Partial transcription from streaming (updated in real-time).
    private(set) var partialText: String = ""
    /// Final transcription after stop (with vocabulary boosting).
    private(set) var finalText: String = ""

    var isActive: Bool { state != .idle }

    // MARK: - Dependencies

    private let transcriptionEngine: FluidTranscriptionEngine

    // MARK: - Audio Capture

    private var engine: AVAudioEngine?
    private let audioBuffer = ThreadSafeAudioBuffer()
    private static let tapBufferSize: AVAudioFrameCount = 4096
    /// Minimum samples for transcription (1 second at 16kHz).
    private static let minSamples = 16000

    // MARK: - Streaming

    private var streamingManager: AsrManager?
    private var streamingTask: Task<Void, Never>?
    /// Streaming chunk interval in seconds.
    private static let chunkInterval: TimeInterval = 0.6

    // MARK: - Focus

    /// PID of the app that was focused when dictation started.
    private var targetPID: pid_t?

    init(transcriptionEngine: FluidTranscriptionEngine) {
        self.transcriptionEngine = transcriptionEngine
    }

    // MARK: - Start / Stop

    /// Start dictation: capture mic audio + stream transcription.
    func start(micDeviceUID: String? = nil) async {
        guard state == .idle else { return }
        guard transcriptionEngine.modelState == .loaded else {
            logger.warning("Cannot start dictation — model not loaded")
            return
        }

        // Capture focus before we do anything
        targetPID = TextInsertionService.captureFocusedPID()

        state = .recording
        audioBuffer.reset()
        partialText = ""
        finalText = ""

        do {
            try startAudioCapture(deviceUID: micDeviceUID)
            await startStreamingManager()
            startStreamingLoop()
            logger.info("Dictation started")
        } catch {
            logger.error("Failed to start dictation: \(error)")
            cleanup()
        }
    }

    /// Stop dictation: finalize transcription + insert text.
    func stop(customVocabulary: [String] = []) async {
        guard state == .recording else { return }
        state = .finalizing

        // Stop audio capture
        stopAudioCapture()

        // Stop streaming
        streamingTask?.cancel()
        streamingTask = nil

        // Get final buffer
        let samples = audioBuffer.getAll()

        guard samples.count >= Self.minSamples else {
            logger.info("Dictation too short (\(samples.count) samples), discarding")
            cleanup()
            return
        }

        // Final transcription with vocabulary boosting
        do {
            let text = try await finalTranscription(samples: samples, customVocabulary: customVocabulary)
            finalText = text

            if !text.isEmpty, let pid = targetPID {
                // Restore focus and insert text
                TextInsertionService.activateApp(pid: pid)
                // Small delay for app to regain focus
                try? await Task.sleep(for: .milliseconds(50))
                TextInsertionService.insertText(text)
                logger.info("Dictation complete: \(text.count) characters inserted")
            }
        } catch {
            logger.error("Final transcription failed: \(error)")
        }

        cleanup()
    }

    /// Cancel dictation without inserting text.
    func cancel() {
        guard state != .idle else { return }
        logger.info("Dictation cancelled")
        stopAudioCapture()
        streamingTask?.cancel()
        streamingTask = nil
        cleanup()
    }

    // MARK: - Audio Capture

    private func startAudioCapture(deviceUID: String?) throws {
        let engine = AVAudioEngine()

        if let uid = deviceUID {
            try MicRecorder.setInputDevice(uid: uid, on: engine)
        }

        let inputNode = engine.inputNode

        // Request 16kHz mono for direct ML consumption
        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16000,
            channels: 1
        )

        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: tapFormat
        ) { [audioBuffer] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            audioBuffer.append(samples)
        }

        try engine.start()
        self.engine = engine
        logger.info("Audio capture started (16kHz mono)")
    }

    private func stopAudioCapture() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - Streaming Transcription

    private func startStreamingManager() async {
        do {
            let manager = AsrManager()
            // Initialize with the same model the engine uses
            let version: AsrModelVersion = transcriptionEngine.modelVariant.contains("-v3-") ? .v3 : .v2
            let models = try await AsrModels.downloadAndLoad(version: version)
            try await manager.initialize(models: models)
            streamingManager = manager
            logger.info("Streaming ASR manager ready")
        } catch {
            logger.error("Failed to initialize streaming manager: \(error)")
        }
    }

    private func startStreamingLoop() {
        streamingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.chunkInterval))
                guard !Task.isCancelled else { break }
                await self?.processStreamingChunk()
            }
        }
    }

    private func processStreamingChunk() async {
        guard let manager = streamingManager else { return }

        let samples = audioBuffer.getAll()
        guard samples.count >= Self.minSamples else { return }

        do {
            nonisolated(unsafe) let unsafeManager = manager
            let result = try await unsafeManager.transcribeStreaming(samples, source: .microphone)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                partialText = text
            }
        } catch {
            // Streaming errors are non-fatal — just skip this chunk
            logger.debug("Streaming chunk error: \(error)")
        }
    }

    // MARK: - Final Transcription

    private func finalTranscription(samples: [Float], customVocabulary: [String]) async throws -> String {
        // Configure vocabulary boosting on the main engine
        if !customVocabulary.isEmpty {
            try await transcriptionEngine.configureVocabulary(customVocabulary)
        }

        // Write samples to a temp WAV file for the engine
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).wav")

        try writeSamplesToWAV(samples, url: tempURL, sampleRate: 16000)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let segments = try await transcriptionEngine.transcribeSegments(audioPath: tempURL)
        return segments.map(\.text).joined(separator: " ")
    }

    /// Write Float32 samples to a WAV file.
    private func writeSamplesToWAV(_ samples: [Float], url: URL, sampleRate: Double) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw DictationError.audioFormatFailed
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw DictationError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }

        try file.write(from: buffer)
    }

    // MARK: - Cleanup

    private func cleanup() {
        state = .idle
        streamingManager = nil
        targetPID = nil
    }
}

enum DictationError: LocalizedError {
    case audioFormatFailed
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .audioFormatFailed: "Failed to create audio format"
        case .bufferCreationFailed: "Failed to create audio buffer"
        }
    }
}

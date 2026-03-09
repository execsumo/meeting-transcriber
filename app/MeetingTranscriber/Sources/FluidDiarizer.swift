import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer")

/// CoreML-based speaker diarization using FluidAudio (on-device, no HuggingFace token needed).
class FluidDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?

    var isAvailable: Bool { true }

    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> MeetingTranscriber.DiarizationResult {
        var config = OfflineDiarizerConfig()
        if let n = numSpeakers, n > 0 {
            config = config.withSpeakers(exactly: n)
        }

        if manager == nil {
            manager = OfflineDiarizerManager(config: config)
            try await manager!.prepareModels()
            logger.info("FluidAudio models ready")
        }

        logger.info("Starting diarization: \(audioPath.lastPathComponent)")
        let fluidResult = try await manager!.process(audioPath)

        // Convert FluidAudio segments to our DiarizationResult.Segment
        // speakerId is a String like "Speaker 0" — we normalize to "SPEAKER_0"
        let segments = fluidResult.segments.map { seg in
            let normalizedSpeaker = seg.speakerId
                .replacingOccurrences(of: "Speaker ", with: "SPEAKER_")
            return MeetingTranscriber.DiarizationResult.Segment(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                speaker: normalizedSpeaker
            )
        }

        // Compute speaking times
        var speakingTimes: [String: TimeInterval] = [:]
        for seg in segments {
            speakingTimes[seg.speaker, default: 0] += seg.end - seg.start
        }

        // Convert speaker database embeddings (normalize keys too)
        var embeddings: [String: [Float]]?
        if let db = fluidResult.speakerDatabase {
            embeddings = [:]
            for (id, emb) in db {
                let normalizedKey = id.replacingOccurrences(of: "Speaker ", with: "SPEAKER_")
                embeddings![normalizedKey] = emb
            }
        }

        logger.info("Diarization complete: \(segments.count) segments, \(speakingTimes.count) speakers")

        return MeetingTranscriber.DiarizationResult(
            segments: segments,
            speakingTimes: speakingTimes,
            autoNames: [:],
            embeddings: embeddings
        )
    }
}

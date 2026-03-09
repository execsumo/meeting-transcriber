# Native Diarization: Replace Python pyannote with FluidAudio (CoreML)

## Goal

Replace the Python-based pyannote diarization subprocess with FluidAudio, a native Swift
SPM package that runs the same pyannote models on CoreML/ANE. This eliminates the 700 MB
Python bundle, removes the HuggingFace token requirement, and makes the app App Store
compatible (no subprocess).

## Architecture

```
Before:
  PipelineQueue → DiarizationProcess → Process() → python3 diarize.py → stdout JSON
                                       ↕ IPC files (speaker_request.json / speaker_response.json)
                                    IPCPoller → Speaker-Naming-Popup

After:
  PipelineQueue → FluidDiarizer → OfflineDiarizerManager → CoreML/ANE
                       ↓ direct Swift call
                  Speaker-Naming-Popup
```

## Key Facts

- **Package:** `https://github.com/FluidInference/FluidAudio.git` (v0.12.2+)
- **Models:** ~254 MB CoreML, auto-downloaded on first run, cached in
  `~/Library/Application Support/FluidAudio/Models/`
- **License:** CC-BY-4.0 (no token required, fully public)
- **Performance:** ~150x real-time on M2 ANE, ~60x on M1
- **Embeddings:** 256-dim WeSpeaker (same family as pyannote, but not binary-compatible
  with old speakers.json)
- **Min platform:** macOS 14+ (already our target)

## Components

### 1. FluidDiarizer (new, replaces DiarizationProcess)

Implements `DiarizationProvider` protocol. Wraps `OfflineDiarizerManager`.

```swift
class FluidDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?

    var isAvailable: Bool { true }  // Always available, models download on demand

    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult {
        if manager == nil {
            let config = OfflineDiarizerConfig()
            if let n = numSpeakers, n > 0 {
                config.clustering.numSpeakers = n
            }
            manager = OfflineDiarizerManager(config: config)
            try await manager!.prepareModels()
        }

        let result = try await manager!.process(audioPath)

        // Convert FluidAudio result to our DiarizationResult
        let segments = result.segments.map {
            DiarizationResult.Segment(
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds),
                speaker: "SPEAKER_\($0.speakerId)"
            )
        }

        // Build speaking times from segments
        var speakingTimes: [String: TimeInterval] = [:]
        for seg in segments {
            speakingTimes[seg.speaker, default: 0] += seg.end - seg.start
        }

        return DiarizationResult(
            segments: segments,
            speakingTimes: speakingTimes,
            autoNames: [:],
            embeddings: result.speakerDatabase  // Pass through for speaker matching
        )
    }
}
```

### 2. SpeakerMatcher (new, replaces diarize.py speaker matching)

Handles speaker recognition against stored profiles and the naming popup trigger.

```swift
class SpeakerMatcher {
    private let dbPath: URL  // AppPaths.speakersDB

    /// Match diarization embeddings against stored speakers.
    /// Returns mapping: { "SPEAKER_0": "Roman Passler", "SPEAKER_1": "SPEAKER_1" }
    func match(embeddings: [String: [Float]]) -> [String: String]

    /// Save new/updated speaker embeddings to DB.
    func save(mapping: [String: String], embeddings: [String: [Float]])

    /// Load stored speakers from disk.
    func loadDB() -> [StoredSpeaker]
}

struct StoredSpeaker: Codable {
    let name: String
    let embedding: [Float]  // 256-dim
}
```

### 3. DiarizationResult (modified)

Add optional embeddings field for passing to SpeakerMatcher:

```swift
struct DiarizationResult {
    let segments: [Segment]
    let speakingTimes: [String: TimeInterval]
    let autoNames: [String: String]
    let embeddings: [String: [Float]]?  // NEW: per-speaker averaged embeddings
}
```

### 4. PipelineQueue changes

The diarization section in `processNext()` changes to:
1. Run FluidDiarizer → get DiarizationResult with embeddings
2. Run SpeakerMatcher.match() → get auto-name mapping
3. If unmatched speakers exist → show Speaker-Naming-Popup directly (no IPC)
4. Apply final mapping to transcript segments

The popup is triggered by setting a published property on PipelineQueue or via
NotificationCenter, same pattern as now but without IPCPoller.

## Files to Change

### New files:
- `Sources/FluidDiarizer.swift` — DiarizationProvider implementation
- `Sources/SpeakerMatcher.swift` — Speaker recognition + DB

### Modified files:
- `Package.swift` — add FluidAudio dependency
- `Sources/DiarizationProcess.swift` — keep `assignSpeakers()` static method, remove rest
  (or inline into FluidDiarizer)
- `Sources/PipelineQueue.swift` — direct popup trigger instead of IPC
- `Sources/MeetingTranscriberApp.swift` — remove IPCPoller, wire up direct popup trigger
- `Sources/AppSettings.swift` — remove HF token related properties
- `Sources/SettingsView.swift` — remove HF token UI
- `Sources/KeychainHelper.swift` — keep (may be used for other secrets later)

### Remove files:
- `Sources/IPCPoller.swift` — no longer needed
- `Sources/IPCManager.swift` — no longer needed (or keep if used elsewhere)
- `Sources/SpeakerRequest.swift` — no longer needed
- `tools/diarize/diarize.py` — replaced by FluidDiarizer
- `tools/diarize/requirements.txt` — no longer needed

### Build changes:
- `scripts/build_release.sh` — remove entire Step 4 (python-diarize venv), remove
  `--no-diarize` flag, remove python codesigning
- `.github/workflows/release.yml` — remove `--no-diarize` flag
- Bundle size: ~700 MB → ~260 MB (models) or ~6 MB (models downloaded on first launch)

## Speaker-Naming Flow (new)

```
1. PipelineQueue.processNext()
2.   FluidDiarizer.run() → DiarizationResult (segments + embeddings)
3.   SpeakerMatcher.match(embeddings) → mapping with auto-matched names
4.   If any speaker unmatched:
5.     Set pipelineQueue.pendingSpeakerNaming = (mapping, embeddings, jobID)
6.     NotificationCenter.post(.showSpeakerNaming)
7.     await continuation (suspended until user responds)
8.   Apply final mapping to transcript
9.   SpeakerMatcher.save(mapping, embeddings)
10.  Continue to protocol generation
```

The key difference: step 7 uses a Swift async continuation instead of polling
JSON files. The pipeline suspends until the user closes the naming dialog.

## speakers.json Format (new)

```json
[
  {
    "name": "Roman Passler",
    "embedding": [0.014, -0.155, ...]
  },
  {
    "name": "Teams",
    "embedding": [0.042, 0.087, ...]
  }
]
```

256-dim WeSpeaker embeddings. Old pyannote-format speakers.json is incompatible
and will be reset on first FluidAudio diarization run.

## Migration

- Delete old `speakers.json` on first run (or rename to `speakers.json.bak`)
- Remove HF_TOKEN from settings (no longer needed)
- Show one-time notification: "Speaker profiles reset — speakers will be re-learned"

## Testing

- Existing `DiarizationProcessTests` for `assignSpeakers()` stay (logic unchanged)
- New `FluidDiarizerTests`: mock `OfflineDiarizerManager`, verify conversion
- New `SpeakerMatcherTests`: test match/save/load with known embeddings
- Integration test: real FluidAudio on test fixture WAV (mark as slow)

## What This Enables

- App Store submission (no subprocess, no Python)
- No HuggingFace token setup for users
- 150x real-time diarization (vs ~10x with PyTorch)
- ~450 MB smaller bundle (or ~700 MB smaller if models download on demand)
- Simpler codebase (no IPC, no Python, no torchcodec/ffmpeg issues)

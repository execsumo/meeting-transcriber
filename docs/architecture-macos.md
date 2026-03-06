# Meeting Transcriber — macOS Architecture

## Overview

Native SwiftUI menu bar application that orchestrates meeting detection, recording, transcription, diarization, and protocol generation. Runs a background watch loop (`WatchLoop`) polling for active meetings and implementing a complete end-to-end pipeline.

**Key pattern:** Observable state models (`@Observable`) with file-based IPC for cross-process communication.

---

## Pipeline

```
Meeting Window Detected (CGWindowListCopyWindowInfo)
  → DualSourceRecorder (audiotap + mic)
    → AudioMixer (resample 48kHz → 16kHz)
      → WhisperKit (CoreML/ANE transcription)
        → [DiarizationProcess (pyannote subprocess)]
          → ProtocolGenerator (Claude CLI)
            → Markdown protocol + transcript
```

---

## Source Files

### App Entry & UI

| File | Role |
|------|------|
| `MeetingTranscriberApp.swift` | `@main` entry point, scene management, WatchLoop lifecycle |
| `MenuBarView.swift` | Menu bar dropdown (state, actions, meeting info) |
| `SettingsView.swift` | Settings window (apps, recording, transcription, diarization) |
| `SpeakerNamingView.swift` | Speaker naming dialog after diarization |
| `SpeakerCountView.swift` | Speaker count selection dialog |
| `AppSettings.swift` | `@Observable` settings persisted to UserDefaults |

### Core Pipeline

| File | Role |
|------|------|
| `WatchLoop.swift` | Main orchestrator: detect → record → transcribe → diarize → protocol |
| `MeetingDetector.swift` | Window polling, pattern matching, confirmation counting, cooldown |
| `MeetingPatterns.swift` | Regex patterns for Teams, Zoom, Webex |
| `DualSourceRecorder.swift` | Orchestrates audiotap + mic, mixes tracks |
| `WhisperKitEngine.swift` | Native WhisperKit transcription (single/dual-source/segments) |
| `DiarizationProcess.swift` | Python subprocess for pyannote speaker identification |
| `ProtocolGenerator.swift` | Claude CLI invocation, stream-json parsing |

### Audio Processing

| File | Role |
|------|------|
| `AudioMixer.swift` | Resampling, mixing, echo suppression, mute masking, WAV I/O |
| `MicRecorder.swift` | Microphone recording via AVAudioEngine |
| `MuteDetector.swift` | Teams mute state via Accessibility API |
| `tools/audiotap/Sources/main.swift` | CATapDescription-based app audio capture (standalone binary) |

### Support

| File | Role |
|------|------|
| `TranscriberStatus.swift` | Status + state enum models |
| `IPCManager.swift` | JSON file-based IPC for speaker dialogs |
| `SpeakerRequest.swift` | Speaker IPC data models |
| `NotificationManager.swift` | macOS notifications |
| `KeychainHelper.swift` | Keychain CRUD for HF token |
| `Permissions.swift` | Mic/accessibility permissions, project root detection |
| `ParticipantReader.swift` | Teams participant extraction via Accessibility API |

---

## State Machine

```
idle → watching → recording → transcribing → [diarizing] → generatingProtocol → done (30s) → watching
                                                                                  ↳ error (30s) → watching
```

**Transitions** are observable via `WatchLoop.state` and trigger:
- Menu bar icon/label updates
- macOS notifications (recording started, protocol ready, error)

---

## Audio Pipeline

### Capture

```
audiotap binary (CATapDescription)
├─ Input: App PID → CoreAudio process tap → aggregate device
├─ Output: Interleaved float32 stereo → stdout (raw PCM)
├─ Mic: AVAudioEngine → mono WAV file (--mic flag)
└─ Metadata: MIC_DELAY, ACTUAL_RATE → stderr
```

**Key:** CATapDescription requires NO Screen Recording permission (purple dot indicator only). Handles output device changes by recreating tap automatically.

### Processing (DualSourceRecorder.stop())

```
Raw float32 stereo → mono (channel average)
  → Save app.wav (at actual hardware rate)
  → Resample to 48kHz if hardware rate differs
  → Load mic.wav
  → Apply mute mask (zero mic during muted periods)
  → Echo suppression (RMS-based gate, 20ms windows)
  → Delay alignment (prepend zeros by MIC_DELAY)
  → Mix (average tracks)
  → Save mix.wav (48kHz mono)
```

### Resampling for WhisperKit

```
48kHz WAV → AudioMixer.resample(from: 48000, to: 16000) → 16kHz WAV
```

WhisperKit requires 16kHz mono input. Both app and mic tracks are resampled before transcription.

---

## Transcription

### WhisperKit Engine

- **Model:** `openai_whisper-large-v3-v20240930_turbo` (CoreML/ANE)
- **Pre-loading:** Model downloaded and loaded at app launch
- **Lazy fallback:** `ensureModel()` loads on-demand if not ready

### Modes

1. **Single source:** `transcribe(audioPath:)` → `[MM:SS] text` lines
2. **Dual source:** `transcribeDualSource(appAudio:micAudio:)` → merged `[MM:SS] Speaker: text`
   - App segments labeled "Remote"
   - Mic segments labeled with user's mic name (default "Me")
3. **Segments:** `transcribeSegments(audioPath:)` → `[TimestampedSegment]` with start/end/text

### Post-processing

- **Token stripping:** Regex `<\|[^|]*\|>` removes `<|startoftranscript|>`, `<|en|>`, etc.
- **Hallucination filtering:** Skip consecutive identical segments

---

## Diarization

### Flow

```
DiarizationProcess.isAvailable?
  → Bundle: Resources/python-diarize/
  → Dev mode: .venv/bin/python + tools/diarize/diarize.py

diarize.py <mix_16k.wav> --speakers N --ipc-dir ~/.meeting-transcriber/ --meeting-title "..."
  → JSON output: { segments, speaking_times, auto_names }

DiarizationProcess.assignSpeakers(transcript, diarization)
  → Maximum temporal overlap matching
  → Each transcript segment gets best-matching speaker label
```

### Speaker Assignment Algorithm

For each transcript segment, find the diarization segment with the longest temporal overlap:
```
overlap = max(0, min(seg.end, dSeg.end) - max(seg.start, dSeg.start))
```
Segment inherits speaker label of the diarization segment with maximum overlap. No overlap → "UNKNOWN".

### IPC for Speaker Dialogs

Python writes JSON to `~/.meeting-transcriber/`:
1. `speaker_count_request.json` → App shows count dialog → `speaker_count_response.json`
2. `speaker_request.json` → App shows naming dialog → `speaker_response.json`

---

## Protocol Generation

### Claude CLI Invocation

```bash
/usr/bin/env claude -p - --output-format stream-json --verbose --model sonnet
```

- **Input:** German protocol prompt + transcript piped to stdin
- **Output:** Stream-json parsed line-by-line (content_block_delta + assistant message)
- **Environment:** `CLAUDECODE` env var stripped to allow nested invocation
- **Timeout:** 10 minutes

### Output Structure

```markdown
# Meeting Protocol - [Title]
## Summary
## Participants
## Topics Discussed
## Decisions
## Tasks (table)
## Open Questions

---

## Full Transcript
[appended automatically]
```

---

## Data Flow

### Observable State Propagation

```
AppSettings (UserDefaults)
  → WatchLoop (@Observable: state, detail, currentMeeting, lastError)
    → MeetingTranscriberApp (computed: currentStatus, currentStateLabel, currentStateIcon)
      → MenuBarView (receives status + callbacks)
      → SettingsView (receives @Bindable settings)
```

### File Locations

| Content | Path |
|---------|------|
| Recordings | `~/Library/Application Support/MeetingTranscriber/recordings/` |
| Protocols | `~/Library/Application Support/MeetingTranscriber/protocols/` |
| IPC | `~/.meeting-transcriber/` |
| Bundle diarize | `MeetingTranscriber.app/Contents/Resources/python-diarize/` |
| Bundle audiotap | `MeetingTranscriber.app/Contents/Resources/audiotap` |
| Dev audiotap | `tools/audiotap/.build/release/audiotap` |
| Dev diarize | `tools/diarize/diarize.py` |

---

## Testing Hooks

| Component | Injection Point |
|-----------|----------------|
| MeetingDetector | `windowListProvider` closure (mock window list) |
| MuteDetector | `muteStateProvider` closure |
| DiarizationProcess | `pythonPath`, `scriptPath`, `ipcDir` constructor params |
| ProtocolGenerator | `claudeBin` parameter |
| IPCManager | `baseDir` parameter |

---

## Permissions

| Permission | Required For | Notes |
|------------|-------------|-------|
| Screen Recording | Meeting detection (window titles) | CGWindowListCopyWindowInfo |
| Microphone | Mic recording | AVAudioEngine |
| Accessibility | Mute detection, participant reading | Teams AX tree |
| None | App audio capture | CATapDescription (purple dot only) |

---

## Key Architectural Decisions

1. **@Observable over @StateObject** — Fine-grained reactivity, macOS 14+
2. **File-based IPC** — Decouples Python diarization from Swift UI without tight coupling
3. **audiotap as separate binary** — Process isolation for real-time audio callback
4. **Dual-source recording** — Enables speaker separation without diarization (app=Remote, mic=Me)
5. **Graceful degradation** — Diarization optional, mute detection optional, continues on partial failure
6. **Pre-loaded model** — WhisperKit loaded at app launch, prevents delay on first meeting
7. **60s cooldown** — Prevents re-detecting same meeting window after handling

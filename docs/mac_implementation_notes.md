# macOS Meeting Transcriber – Implementation Notes

## Overview

`meeting_transcriber_mac.py` is the macOS version of the Meeting Transcriber.
Standalone script, no imports from the Windows file (`Meeting_transcriber.py`).

**Pipeline:** App audio (ProcTap/ScreenCaptureKit) + microphone (sounddevice) → mix → WAV → pywhispercpp → Claude CLI → protocol (.txt + .md)

## Project Structure

```
Meeting_transcriber.py      # Windows original (pyaudiowpatch/WASAPI Loopback, faster_whisper)
meeting_transcriber_mac.py  # macOS version (ProcTap/ScreenCaptureKit, pywhispercpp)
test_e2e_app_audio.py       # E2E test (fully automated, incl. real app audio capture)
.venv/                      # Python 3.14 venv (homebrew)
protocols/                 # Output directory
docs/                       # This documentation
```

## Setup

```bash
/opt/homebrew/bin/python3.14 -m venv .venv
source .venv/bin/activate
pip install proc-tap pywhispercpp sounddevice numpy rich
```

### Build ProcTap Swift Binary (IMPORTANT!)

The pip installation contains ONLY the Swift source code, not the compiled binary.
Without the build you get: `ctypes Core Audio bindings not available`

```bash
cd .venv/lib/python3.14/site-packages/proctap/swift/screencapture-audio
swift build -c release
```

The binary ends up at:
`.build/arm64-apple-macosx/release/screencapture-audio`

ProcTap finds it automatically (searches dev-build paths).

### Screen Recording Permission (IMPORTANT!)

ScreenCaptureKit requires the permission:
**System Settings → Privacy & Security → Screen Recording → enable Terminal**

Without this permission: ProcTap connects and returns format info,
but delivers 0 audio chunks. The `screencapture-audio` binary explicitly shows:
`ERROR: Screen Recording permission not granted`

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| proc-tap | 1.0.3 | ScreenCaptureKit audio capture from individual apps |
| pywhispercpp | 1.4.1 | whisper.cpp Python bindings, Metal GPU on Apple Silicon |
| sounddevice | 0.5.5 | Microphone recording (simpler than pyaudio on Mac) |
| numpy | 2.4.2 | Audio processing |
| rich | 14.3.3 | CLI output |
| pyobjc-core + pyobjc-framework-Cocoa | 12.1 | NSWorkspace for app listing (comes as proc-tap dependency) |

## CLI Interface

```bash
# Live: app audio + microphone
python meeting_transcriber_mac.py --app "Microsoft Teams" --title "Standup"

# By PID
python meeting_transcriber_mac.py --pid 13977 --title "Standup"

# List apps
python meeting_transcriber_mac.py --list-apps

# Microphone only
python meeting_transcriber_mac.py --mic-only --title "Meeting"

# Transcribe audio file
python meeting_transcriber_mac.py --file recording.mp3 --title "Sprint Review"

# Process transcript directly (skip Whisper)
python meeting_transcriber_mac.py --file transcript.txt --title "Team Meeting"

# Different Whisper model
python meeting_transcriber_mac.py --model base --title "Quick Test"
```

## Audio Formats & Data Flow

```
ProcTap delivers:    48kHz, stereo, float32 interleaved (10ms chunks = 960 floats/chunk)
Microphone delivers: 16kHz, mono, float32

Pipeline:
1. App audio: Stereo → Mono (mean axis=1)
2. App audio: Resample 48kHz → 16kHz (np.interp)
3. Mix: (mic + app) / 2, append remainder if different lengths
4. Clip + Convert: float32 [-1,1] → int16
5. WAV: 16kHz, mono, 16-bit (what Whisper expects)
```

## ProcTap API Details

```python
from proctap import ProcessAudioCapture

def on_data(pcm: bytes, frames: int) -> None:
    # pcm = float32 interleaved stereo, frames often -1 (bug in core.py)
    pass

tap = ProcessAudioCapture(pid=12345, on_data=on_data)
tap.start()
fmt = tap.get_format()  # {'sample_rate': 48000, 'channels': 2, 'bits_per_sample': 32, 'sample_format': 'float32'}
# ... record ...
tap.close()
```

**Backend selection (automatic):**
1. ScreenCaptureKit (preferred, macOS 13+) – requires Swift binary
2. PyObjC (fallback) – DOES NOT WORK with Python 3.14 (ctypes incompatibility)

## App Listing

Uses `NSWorkspace.sharedWorkspace().runningApplications()` via pyobjc.
Filters on `NSApplicationActivationPolicyRegular` (GUI apps with Dock icon only).

**Not used:** osascript/AppleScript – returns too many background processes
and parsing the output is error-prone (single line with two comma-separated lists).

## Whisper (pywhispercpp)

```python
from pywhispercpp.model import Model

model = Model("large-v3-turbo-q5_0", n_threads=8, print_realtime=False, print_progress=False)
segments = model.transcribe("audio.wav", language="de")
text = " ".join(seg.text for seg in segments)
```

- Models are automatically downloaded to `~/Library/Application Support/pywhispercpp/models/`
- Default model: `large-v3-turbo-q5_0`
- Metal GPU acceleration on Apple Silicon automatically active
- Expects 16kHz mono WAV

## Claude CLI Protocol Generation

```python
subprocess.run(["claude", "--print"], stdin=fin, stdout=fout, timeout=300)
```

- NO `shell=True` (unlike Windows original)
- Prompt is written to temp file (bypasses argument length limit)
- Output is read from temp file

## Pain Points & Solutions

### 1. ProcTap Swift binary missing after pip install
**Problem:** `pip install proc-tap` installs only Python code + Swift source code, not the compiled binary.
**Symptom:** `screencapture-audio binary not found`, fallback to PyObjC, then `ctypes Core Audio bindings not available` (Python 3.14).
**Solution:** Build Swift binary manually (see Setup above).

### 2. Screen Recording Permission
**Problem:** ScreenCaptureKit requires the permission, but the error is not obvious.
**Symptom:** ProcTap connects successfully (format is returned!), but 0 audio chunks.
**Diagnosis:** Run `screencapture-audio` binary directly → shows explicit error message.
**Solution:** System Settings → Privacy & Security → Screen Recording → enable Terminal.

### 3. ScreenCaptureKit doesn't see all apps
**Problem:** ScreenCaptureKit only lists apps that:
- Have a valid bundle ID
- Have at least one window (`LSUIElement=true` apps are invisible!)
- Are not just CLI tools (`afplay`, `say` etc. have no bundle ID)

**Consequence for tests:** You can't simply use `afplay` or a Python subprocess as audio source.
**Solution in test:** Custom Swift app with:
- Real .app bundle + Info.plist with CFBundleIdentifier
- `NSApplication.shared` + `setActivationPolicy(.regular)`
- A (1x1 pixel) window via `NSWindow`
- Ad-hoc code signature (`codesign --force --sign -`)

### 4. Python subprocesses have no bundle ID
**Problem:** Even with `NSApplication.sharedApplication()`, a Python subprocess doesn't get a bundle ID that ScreenCaptureKit recognizes.
**Attempt:** Player helper in Python with PyObjC → `lsappinfo` shows `CFBundleIdentifier = NULL`.
**Solution:** Swift-based player (see above).

### 5. osascript/AppleScript Automation Timeout
**Problem:** AppleScript to QuickTime Player or Music hangs (Automation Permission).
**Symptom:** `osascript -e 'tell application "QuickTime Player" to play document 1'` → Timeout.
**Solution:** Don't use AppleScript, use custom player app instead.

### 6. `global WHISPER_MODEL` SyntaxError
**Problem:** `global` must come BEFORE any access to the variable in the function.
**Symptom:** `SyntaxError: name 'WHISPER_MODEL' is used prior to global declaration`
**Solution:** Put `global WHISPER_MODEL` at the start of `main()`, before the argparse default.

### 7. `wave` can't read AIFF
**Problem:** `say` generates AIFF by default, `wave.open()` expects RIFF/WAV.
**Symptom:** `wave.Error: file does not start with RIFF id`
**Solution:** `say -o file.wav --file-format=WAVE --data-format=LEI16`

## E2E Test (`test_e2e_app_audio.py`)

Fully automated test of the entire pipeline:

```bash
python test_e2e_app_audio.py            # German
python test_e2e_app_audio.py --lang en  # English
python test_e2e_app_audio.py --pid 13977  # Capture from specific app
```

**6 Steps:**
1. `say` generates speech as WAV (16-bit PCM)
2. WAV → ProcTap format (48kHz stereo float32 chunks)
3. Mix pipeline (identical code as meeting_transcriber_mac.py)
4. Whisper transcription (model: base, for fast testing)
5. Keyword verification against original text
6. **Real app audio capture:** Automatically starts a Swift player app,
   plays the speech WAV, ProcTap captures via ScreenCaptureKit

**Prerequisite for step 6:** Screen Recording permission must be granted.

**Test player app:** `/tmp/TestAudioPlayer.app`
- Automatically built on first run (Swift compilation + codesign)
- Bundle ID: `com.test.audioplayer`
- Plays audio 5x looped for 30s, so there's enough time for capture

## Test Results (2026-02-25)

```
Step 1: say → WAV (314 KB, Anna voice)                      ✅
Step 2: WAV → ProcTap format (704 chunks, 7.0s)             ✅
Step 3: Mix pipeline → 16kHz mono WAV (225 KB)              ✅
Step 4: Whisper base → 100% correct transcription            ✅
Step 5: All 3 keywords recognized (meeting, projekt, quartal) ✅
Step 6: ProcTap live capture: 157 chunks, peak 67.4%         ✅
```

Whisper on Apple M3 Max: Metal GPU active, ~1s for 7s audio (base model).

## Reuse from Windows Original

Kept identical:
- `PROTOCOL_PROMPT` (meeting protocol prompt)
- `generate_protocol_cli()` – but without `shell=True`
- `save_transcript()` – 1:1
- Output path logic (`./protocols/{date}_{slug}.txt/.md`)

Replaced:
- `pyaudiowpatch` → `sounddevice` (microphone) + `proc-tap` (app audio)
- `faster_whisper` → `pywhispercpp` (whisper.cpp, Metal GPU)
- WASAPI Loopback → ScreenCaptureKit

## Ruff

Both files pass `ruff check` and `ruff format` without errors.
No `pyproject.toml` needed – ruff defaults are sufficient.

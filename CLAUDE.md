# Meeting Transcriber

## Project Structure

```
Meeting_transcriber.py        # Windows version (WASAPI Loopback, faster_whisper)
meeting_transcriber_mac.py    # macOS version (ProcTap/ScreenCaptureKit, pywhispercpp)
diarize.py                    # Speaker diarization + voice recognition (pyannote-audio)
test_e2e_app_audio.py         # E2E test (automated, incl. real ScreenCaptureKit capture)
docs/mac_implementation_notes.md  # Implementation notes & pain points
protocols/                    # Output directory (gitignored)
speakers.json                 # Saved voice profiles (gitignored, created at runtime)
.env                          # HF_TOKEN for diarization (gitignored)
```

## Pipeline

```
App audio (ProcTap) + Microphone → mix → 16kHz mono WAV → Whisper → [pyannote diarization] → Claude CLI → Markdown protocol
```

## Setup

```bash
/opt/homebrew/bin/python3.14 -m venv .venv
source .venv/bin/activate
pip install proc-tap pywhispercpp sounddevice numpy rich python-dotenv

# For speaker diarization:
pip install pyannote.audio
# Set HF_TOKEN in .env (see .env.example)

# Build ProcTap Swift binary (required!):
cd .venv/lib/python3.14/site-packages/proctap/swift/screencapture-audio
swift build -c release
```

## Key Commands

```bash
# Lint/format
ruff check . && ruff format .

# Run macOS transcriber
python meeting_transcriber_mac.py --app "Microsoft Teams" --title "Meeting"
python meeting_transcriber_mac.py --file recording.wav --diarize --title "Meeting"

# Run E2E test
python test_e2e_app_audio.py
python test_e2e_app_audio.py --lang en
```

## Conventions

- Use `ruff` for linting/formatting (defaults, no pyproject.toml)
- All code and UI text in English
- Protocol output generated in German (via Claude prompt)
- Python 3.14 via homebrew
- Lazy imports for optional dependencies (pyannote, proctap)

## Critical Notes

- ProcTap Swift binary must be built manually after pip install
- Screen Recording permission required for app audio capture (System Settings → Privacy & Security)
- ScreenCaptureKit only sees apps with windows + bundle ID
- pyannote diarization requires HuggingFace token + license acceptance for 3 models:
  - pyannote/speaker-diarization-3.1
  - pyannote/segmentation-3.0
  - pyannote/speaker-diarization-community-1

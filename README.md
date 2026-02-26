# Meeting Transcriber

[![CI](https://github.com/meanstone/Transcriber/actions/workflows/ci.yml/badge.svg)](https://github.com/meanstone/Transcriber/actions/workflows/ci.yml)

Record meetings, transcribe with Whisper, and generate structured protocols with Claude — fully local, no cloud transcription costs.

```
App/System Audio + Microphone → Whisper → [Speaker Diarization] → Claude → Markdown Protocol
```

---

## Features

- **Dual audio recording** — Microphone + app audio simultaneously (Teams, Zoom, etc.)
  - macOS: ProcTap / ScreenCaptureKit
  - Windows: WASAPI Loopback
- **Local transcription** — [pywhispercpp](https://github.com/aarnphm/pywhispercpp) (macOS) / [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (Windows)
- **Speaker diarization** — Identify and label speakers via [pyannote-audio](https://github.com/pyannote/pyannote-audio), with saved voice profiles
- **AI protocol generation** — Structured Markdown via [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- **Flexible input** — Live recording, audio file (wav, mp3, m4a), or existing transcript (.txt)

---

## Output

All files are saved to `./protocols/`:

| File | Content |
|------|---------|
| `20260225_1400_meeting.txt` | Raw transcript |
| `20260225_1400_meeting.md` | Structured protocol |

**Protocol structure:** Summary, Participants, Topics Discussed, Decisions, Tasks (table with responsible person, deadline, priority), Open Questions, Full Transcript.

---

## Prerequisites

- Python 3.12+
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) — installed and logged in (`claude --version`)

For diarization (optional):
- HuggingFace token in `.env` (`HF_TOKEN=...`)
- Accepted licenses for pyannote models

---

## Installation

### macOS

```bash
git clone https://github.com/meanstone/Transcriber
cd Transcriber
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[mac,dev]"

# Optional: speaker diarization
pip install -e ".[mac,diarize,dev]"
```

ProcTap Swift binary must be built manually for app audio capture:

```bash
cd .venv/lib/python3.*/site-packages/proctap/swift/screencapture-audio
swift build -c release
```

### Windows

```bash
git clone https://github.com/meanstone/Transcriber
cd Transcriber
python -m venv .venv
.venv\Scripts\activate
pip install -e ".[windows,dev]"
```

For GPU acceleration (optional):
```bash
pip install torch --index-url https://download.pytorch.org/whl/cu121
```

---

## Usage

### Live recording

```bash
# macOS — record app audio + microphone
transcribe --app "Microsoft Teams" --title "Sprint Review"

# macOS — microphone only
transcribe --mic-only --title "Interview"

# Windows — system audio + microphone
transcribe --title "Project Meeting"
```

Press **Enter** to stop recording.

### Transcribe audio file

```bash
transcribe --file recording.mp3 --title "Sprint Review"
```

### With speaker diarization

```bash
transcribe --file recording.wav --diarize --title "Team Meeting"
transcribe --file recording.wav --diarize --speakers 3 --title "Team Meeting"
```

### Protocol from existing transcript

```bash
transcribe --file protocols/transcript.txt --title "Standup"
```

### List available apps (macOS)

```bash
transcribe --list-apps
```

---

## CLI Reference

| Flag | Description |
|------|-------------|
| `--file, -f` | Audio file or transcript (.txt) |
| `--title, -t` | Meeting title (default: "Meeting") |
| `--output-dir, -o` | Output directory (default: `./protocols`) |
| `--model, -m` | Whisper model (macOS default: `large-v3-turbo-q5_0`, Windows: `large`) |
| `--app, -a` | App name for audio capture (macOS) |
| `--pid` | Process ID for app audio (macOS) |
| `--list-apps` | List running apps and exit (macOS) |
| `--mic-only` | Microphone only, no app audio (macOS) |
| `--list-mics` | List available microphone devices and exit (macOS) |
| `--mic` | Microphone device index or name substring (macOS) |
| `--diarize` | Enable speaker diarization |
| `--speakers` | Expected number of speakers |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `claude not found` | Install Claude Code CLI, run `claude --version` |
| No app audio (macOS) | Grant Screen Recording permission (System Settings → Privacy & Security) |
| ProcTap delivers 0 chunks | Build the Swift binary (see Installation) |
| No system audio (Windows) | Check default output device in Windows sound settings |
| GPU not detected (Windows) | Install torch with CUDA, check `nvidia-smi` |

---

## License

[MIT](LICENSE)

# Meeting Transcriber

Automatic recording, transcription, and protocol generation for meetings – locally on Windows, no cloud costs.

```
Microphone + System Audio → faster-whisper → Claude CLI → Markdown Protocol
```

---

## Features

- **Dual audio recording** – Microphone and system audio (Teams, Zoom, etc.) simultaneously via WASAPI Loopback, no virtual cable needed
- **Local transcription** – [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (Whisper large), automatic GPU detection (CUDA) or CPU fallback
- **AI protocol** – Structured Markdown via [Claude Code CLI](https://claude.ai/code), no separate API key needed
- **Flexible input** – Audio file (wav, mp3, m4a, ...) or existing `.txt` transcript

---

## Output

All files are saved to `./protocols/`:

| File | Content |
|------|---------|
| `20260225_1400_meeting.txt` | Raw transcript |
| `20260225_1400_meeting.md` | Structured protocol |

**Protocol structure:**
- Summary
- Participants
- Topics Discussed
- Decisions
- Tasks (table with responsible person, deadline, priority)
- Open Questions
- Full Transcript

---

## Prerequisites

### Software
- Python 3.10+
- [Claude Code CLI](https://claude.ai/code) – installed and logged in (`claude --version`)
- Node.js 20+ (for Claude Code)

### Python Packages

```bash
pip install faster-whisper pyaudiowpatch numpy rich
```

For GPU acceleration (optional, recommended):
```bash
pip install torch --index-url https://download.pytorch.org/whl/cu121
```

---

## Installation

```bash
git clone https://github.com/meanstone/Meeting_transcriber
cd Meeting_transcriber
pip install faster-whisper pyaudiowpatch numpy rich
```

---

## Usage

### Live recording (microphone + system audio)
```bash
python Meeting_transcriber.py --title "Project Meeting"
```
→ Press **Enter** to stop recording.

### Transcribe audio file
```bash
python Meeting_transcriber.py --file recording.mp3 --title "Sprint Review"
```

### Protocol from existing transcript only
```bash
python Meeting_transcriber.py --file protocols/transcript.txt --title "Team Meeting"
```
Whisper is skipped, Claude generates the protocol directly.

---

## Configuration

At the top of `Meeting_transcriber.py`:

```python
WHISPER_MODEL = "large"   # tiny | base | small | medium | large
WHISPER_LANG  = None      # None = auto-detect, "de" = force German
OUTPUT_DIR    = Path("./protocols")
```

| Model | Quality | GPU VRAM | Speed |
|-------|---------|----------|-------|
| `tiny` | low | ~1 GB | very fast |
| `base` | good | ~1 GB | fast |
| `small` | very good | ~2 GB | medium |
| `medium` | excellent | ~5 GB | slow |
| `large` | best | ~10 GB | very slow |

---

## Recording Teams / Zoom Audio

The script uses **WASAPI Loopback** – this captures system audio directly from the Windows audio mixer:

1. Start Teams/Zoom call
2. Start the script (`python Meeting_transcriber.py`)
3. Recording runs automatically with microphone + remote participants
4. Press Enter to stop

> **Note:** Jabra and some USB headsets change the default speaker – check Windows Settings → Sound → Output to see which device is active.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `claude not found` | Test `claude --version` in terminal, reinstall if needed |
| No system audio recorded | Check default output device in Windows sound settings |
| GPU not detected | `pip install torch` with CUDA version, check `nvidia-smi` |
| Transcript in English | Set `WHISPER_LANG = "de"` |
| Protocol empty | Test `echo Hello | claude --print` in terminal |

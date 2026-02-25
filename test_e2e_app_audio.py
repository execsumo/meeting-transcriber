#!/usr/bin/env python3
"""
E2E Test: App Audio Pipeline → Whisper Transcription

Tests the complete pipeline as meeting_transcriber_mac.py runs it:
1. macOS `say` generates speech as WAV (simulates app output)
2. Audio is converted to ProcTap format (48kHz stereo float32 chunks)
3. Chunks go through the identical mix pipeline (stereo→mono, resample→16kHz, WAV)
4. WAV is transcribed with pywhispercpp
5. Transcription is verified against the original text
6. ProcTap connection to a real app is verified separately

Usage:
    python test_e2e_app_audio.py
    python test_e2e_app_audio.py --lang en
"""

import os
import subprocess
import wave
from pathlib import Path
from tempfile import NamedTemporaryFile

import numpy as np

TARGET_RATE = 16000
APP_RATE = 48000
APP_CHANNELS = 2

TEXTS = {
    "de": (
        "Willkommen zum Meeting. Heute besprechen wir die neuen Projektziele "
        "und die Aufgabenverteilung für das nächste Quartal."
    ),
    "en": (
        "Welcome to the meeting. Today we will discuss the new project goals "
        "and the task distribution for the next quarter."
    ),
}

KEYWORDS = {
    "de": ["meeting", "projekt", "quartal"],
    "en": ["meeting", "project", "quarter"],
}


def step_generate_speech(text: str, lang: str) -> Path:
    """Step 1: Text → WAV via macOS `say`."""
    print(f"\n[1/6] Generating speech via `say` ({lang}) ...")
    print(f"  Text: {text!r}")

    voice = "Anna" if lang == "de" else "Samantha"
    tmp = NamedTemporaryFile(suffix=".wav", delete=False)
    wav_path = Path(tmp.name)
    tmp.close()

    # --file-format=WAVE --data-format=LEI16 → standard 16-bit PCM WAV
    result = subprocess.run(
        [
            "say",
            "-v",
            voice,
            "-o",
            str(wav_path),
            "--file-format=WAVE",
            "--data-format=LEI16",
            text,
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"say failed: {result.stderr}"
    size = wav_path.stat().st_size
    print(f"  WAV: {wav_path} ({size:,} bytes)")
    print(f"  OK - Voice: {voice}")
    return wav_path


def step_convert_to_proctap_format(speech_path: Path) -> list[bytes]:
    """Step 2: WAV → ProcTap-identical chunks (48kHz stereo float32)."""
    print("\n[2/6] Speech → ProcTap format (48kHz stereo float32) ...")

    with wave.open(str(speech_path), "rb") as wf:
        orig_rate = wf.getframerate()
        orig_channels = wf.getnchannels()
        orig_sampwidth = wf.getsampwidth()
        nframes = wf.getnframes()
        raw = wf.readframes(nframes)

    print(f"  Input: {orig_rate}Hz, {orig_channels}ch, {orig_sampwidth * 8}-bit")

    if orig_sampwidth == 2:
        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif orig_sampwidth == 4:
        samples = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"Unknown sample width: {orig_sampwidth}")

    # Convert to mono if multichannel
    if orig_channels > 1:
        samples = samples.reshape(-1, orig_channels).mean(axis=1)

    # Resample to 48kHz (ProcTap native rate)
    if orig_rate != APP_RATE:
        new_len = int(len(samples) * APP_RATE / orig_rate)
        samples = np.interp(
            np.linspace(0, len(samples) - 1, new_len),
            np.arange(len(samples)),
            samples,
        )

    # Mono → Stereo interleaved (exactly as ProcTap delivers)
    stereo = np.empty(len(samples) * APP_CHANNELS, dtype=np.float32)
    stereo[0::2] = samples
    stereo[1::2] = samples

    # Split into 10ms chunks (ProcTap delivers 10ms = 480 frames = 960 float32s)
    chunk_samples = APP_RATE * APP_CHANNELS * 10 // 1000
    chunks = []
    for i in range(0, len(stereo), chunk_samples):
        chunk = stereo[i : i + chunk_samples]
        if len(chunk) == chunk_samples:
            chunks.append(chunk.tobytes())
        else:
            padded = np.zeros(chunk_samples, dtype=np.float32)
            padded[: len(chunk)] = chunk
            chunks.append(padded.tobytes())

    duration = len(samples) / APP_RATE
    print(f"  Output: {APP_RATE}Hz, stereo, float32, {len(chunks)} chunks")
    print(f"  Duration: {duration:.1f}s")
    print("  OK")

    # speech_path is reused by step 6 → don't delete
    return chunks


def step_mix_pipeline(frames_app: list[bytes]) -> Path:
    """Step 3: Identical mix pipeline as meeting_transcriber_mac.py:record_audio()."""
    print("\n[3/6] Mix pipeline (identical to meeting_transcriber_mac.py) ...")

    # --- from here 1:1 copied from meeting_transcriber_mac.py ---
    raw = np.frombuffer(b"".join(frames_app), dtype=np.float32)

    # Stereo → Mono
    if APP_CHANNELS == 2 and len(raw) >= 2:
        raw = raw.reshape(-1, 2).mean(axis=1)

    # Resample to 16 kHz
    if APP_RATE != TARGET_RATE and len(raw) > 1:
        ratio = TARGET_RATE / APP_RATE
        new_len = int(len(raw) * ratio)
        audio_app = np.interp(
            np.linspace(0, len(raw) - 1, new_len),
            np.arange(len(raw)),
            raw,
        )
    else:
        audio_app = raw

    # No microphone audio in test → app audio only
    mixed = audio_app

    audio_int16 = (np.clip(mixed, -1.0, 1.0) * 32767).astype(np.int16)

    tmp = NamedTemporaryFile(suffix=".wav", delete=False)
    wav_path = Path(tmp.name)
    tmp.close()

    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_RATE)
        wf.writeframes(audio_int16.tobytes())
    # --- end identical code ---

    duration = len(mixed) / TARGET_RATE
    size = wav_path.stat().st_size
    print(f"  WAV: 16kHz mono, {duration:.1f}s, {size:,} bytes")
    print("  OK")
    return wav_path


def step_transcribe(wav_path: Path, lang: str) -> str:
    """Step 4: WAV → Whisper transcription (identical to meeting_transcriber_mac.py)."""
    print("\n[4/6] Whisper transcription ...")
    from pywhispercpp.model import Model

    n_threads = min(os.cpu_count() or 4, 8)
    model_name = "base"
    print(f"  Model: {model_name}, Threads: {n_threads}")

    model = Model(
        model_name,
        n_threads=n_threads,
        print_realtime=False,
        print_progress=False,
    )
    segments = model.transcribe(str(wav_path), language=lang)
    text = " ".join(seg.text for seg in segments).strip()

    print(f"  Transcription ({len(text)} characters):")
    print(f"  >>> {text}")

    wav_path.unlink()
    print("  OK")
    return text


def step_verify(transcript: str, keywords: list[str], original: str) -> None:
    """Step 5: Verify transcription against keywords."""
    print("\n[5/6] Verifying transcription ...")
    print(f"  Original:      {original!r}")
    print(f"  Transcription: {transcript!r}")

    transcript_lower = transcript.lower()
    found = []
    missing = []
    for kw in keywords:
        if kw.lower() in transcript_lower:
            found.append(kw)
        else:
            missing.append(kw)

    print(f"  Keywords found:   {found}")
    if missing:
        print(f"  Keywords missing: {missing}")

    assert len(found) >= len(keywords) // 2, (
        f"Too few keywords recognized: {found} of {keywords}"
    )

    if len(found) == len(keywords):
        print("  OK - All keywords recognized!")
    else:
        print(f"  OK - {len(found)}/{len(keywords)} keywords (acceptable)")


PLAYER_APP = "/tmp/TestAudioPlayer.app"
PLAYER_BINARY = PLAYER_APP + "/Contents/MacOS/player"


def ensure_player_app() -> None:
    """Build the Swift audio player as a real macOS app (with bundle ID for ScreenCaptureKit)."""
    if Path(PLAYER_BINARY).exists():
        return

    print("  Building player app ...")
    app_dir = Path(PLAYER_APP)
    (app_dir / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)

    (app_dir / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
        ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        "  <key>CFBundleIdentifier</key><string>com.test.audioplayer</string>\n"
        "  <key>CFBundleName</key><string>TestAudioPlayer</string>\n"
        "  <key>CFBundleExecutable</key><string>player</string>\n"
        "</dict></plist>\n"
    )

    swift_src = Path("/tmp/player.swift")
    swift_src.write_text(
        "import AppKit\n"
        "import AVFoundation\n"
        "\n"
        "guard CommandLine.arguments.count > 1 else { exit(1) }\n"
        "let app = NSApplication.shared\n"
        "app.setActivationPolicy(.regular)\n"
        "let window = NSWindow(\n"
        "    contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),\n"
        "    styleMask: [], backing: .buffered, defer: false\n"
        ")\n"
        "window.orderFrontRegardless()\n"
        "\n"
        "let url = URL(fileURLWithPath: CommandLine.arguments[1])\n"
        "guard let player = try? AVAudioPlayer(contentsOf: url) else { exit(1) }\n"
        "player.numberOfLoops = 5\n"
        "player.play()\n"
        'fputs("PLAYING \\(player.duration)s\\n", stderr)\n'
        "DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {\n"
        "    player.stop()\n"
        "    NSApp.terminate(nil)\n"
        "}\n"
        "app.run()\n"
    )

    result = subprocess.run(
        [
            "swiftc",
            "-o",
            PLAYER_BINARY,
            str(swift_src),
            "-framework",
            "AppKit",
            "-framework",
            "AVFoundation",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"Swift build failed: {result.stderr}"
    subprocess.run(
        ["codesign", "--force", "--sign", "-", PLAYER_APP], capture_output=True
    )
    print("  Player app built + signed")


def step_proctap_live_capture(
    pid: int | None = None, speech_path: Path | None = None, duration: int = 5
) -> None:
    """Step 6: Real app audio capture via ProcTap (ScreenCaptureKit)."""
    print(f"\n[6/6] Real app audio capture via ProcTap ({duration}s) ...")
    import threading
    import time

    from proctap import ProcessAudioCapture

    player_proc = None

    if not pid:
        # Start our own player with the generated speech file
        ensure_player_app()
        audio_file = speech_path or "/tmp/test_long.wav"
        subprocess.run(["pkill", "-f", "TestAudioPlayer"], capture_output=True)
        time.sleep(0.3)
        subprocess.Popen(["open", "-a", PLAYER_APP, "--args", str(audio_file)])
        time.sleep(2)
        r = subprocess.run(
            ["pgrep", "-n", "-f", "TestAudioPlayer"],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0 or not r.stdout.strip():
            print("  ERROR: Could not start player app")
            return
        pid = int(r.stdout.strip().split()[-1])
        player_proc = True
        print(f"  Player started: PID {pid}")

    # Connect + capture
    frames: list[bytes] = []
    stop = threading.Event()

    def on_data(pcm: bytes, frame_count: int) -> None:
        if not stop.is_set():
            frames.append(pcm)

    tap = ProcessAudioCapture(pid=pid, on_data=on_data)
    tap.start()
    fmt = tap.get_format()
    rate = fmt.get("sample_rate", 48000)
    channels = fmt.get("channels", 2)
    print(f"  Format: {rate}Hz, {channels}ch, {fmt.get('sample_format', '?')}")
    print(f"  Capturing ({duration}s) ...")

    time.sleep(duration)
    stop.set()
    tap.close()

    if player_proc:
        subprocess.run(["pkill", "-f", "TestAudioPlayer"], capture_output=True)

    # Analyze result
    total_bytes = sum(len(f) for f in frames)
    print(f"  Chunks: {len(frames)}, Bytes: {total_bytes:,}")

    assert len(frames) > 0, (
        "No audio data received! "
        "Check: System Settings → Privacy & Security → Screen Recording"
    )

    raw = np.frombuffer(b"".join(frames), dtype=np.float32)
    peak = float(np.max(np.abs(raw)))
    rms = float(np.sqrt(np.mean(raw**2)))
    print(f"  Peak: {peak:.4f} ({peak * 100:.1f}%)")
    print(f"  RMS:  {rms:.4f} ({rms * 100:.2f}%)")

    assert peak > 0.001, "Audio is silence only"
    print("  OK - Real app audio received!")


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="E2E test: app audio pipeline → Whisper transcription"
    )
    parser.add_argument(
        "--lang",
        default="de",
        choices=["de", "en"],
        help="Language (default: de)",
    )
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="PID of the app for live capture (step 6)",
    )
    args = parser.parse_args()

    lang = args.lang
    text = TEXTS[lang]
    keywords = KEYWORDS[lang]

    print(f"=== E2E App Audio → Transcription Test ({lang}) ===")

    passed = 0
    total = 6

    try:
        speech_path = step_generate_speech(text, lang)
        passed += 1

        chunks = step_convert_to_proctap_format(speech_path)
        passed += 1

        wav_path = step_mix_pipeline(chunks)
        passed += 1

        transcript = step_transcribe(wav_path, lang)
        passed += 1

        step_verify(transcript, keywords, text)
        passed += 1

        step_proctap_live_capture(pid=args.pid, speech_path=speech_path)
        passed += 1

        # Cleanup speech file
        speech_path.unlink(missing_ok=True)

    except Exception as e:
        if "speech_path" in dir():
            speech_path.unlink(missing_ok=True)
        print(f"\n  ERROR: {type(e).__name__}: {e}")
        import traceback

        traceback.print_exc()

    print(f"\n{'=' * 50}")
    status = "PASSED" if passed == total else "FAILED"
    print(f"Result: {passed}/{total} tests {status}")


if __name__ == "__main__":
    main()

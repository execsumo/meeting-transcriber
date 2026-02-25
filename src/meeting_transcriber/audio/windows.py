"""Windows audio recording via WASAPI Loopback (pyaudiowpatch)."""

import sys
import threading
import wave
from pathlib import Path

import numpy as np
from rich.console import Console

console = Console()


def record_audio(output_path: Path, sample_rate: int = 16000) -> Path:
    """Record microphone + system audio (WASAPI Loopback) and mix."""
    try:
        import pyaudiowpatch as pyaudio
    except ImportError:
        console.print(
            "[red]pyaudiowpatch not installed: pip install pyaudiowpatch[/red]"
        )
        sys.exit(1)

    CHUNK = 1024
    frames_mic = []
    frames_loop = []
    stop_event = threading.Event()

    pa = pyaudio.PyAudio()

    # Default microphone
    mic_stream = pa.open(
        format=pyaudio.paInt16,
        channels=1,
        rate=sample_rate,
        input=True,
        frames_per_buffer=CHUNK,
    )

    # WASAPI Loopback (system audio)
    loopback_stream = None
    loopback_rate = sample_rate
    try:
        wasapi_info = pa.get_host_api_info_by_type(pyaudio.paWASAPI)
        default_speaker = pa.get_device_info_by_index(
            wasapi_info["defaultOutputDevice"]
        )
        for loopback_dev in pa.get_loopback_device_info_generator():
            if default_speaker["name"] in loopback_dev["name"]:
                loopback_rate = int(loopback_dev["defaultSampleRate"])
                loopback_stream = pa.open(
                    format=pyaudio.paInt16,
                    channels=loopback_dev["maxInputChannels"],
                    rate=loopback_rate,
                    input=True,
                    input_device_index=loopback_dev["index"],
                    frames_per_buffer=CHUNK,
                )
                console.print(
                    f"[dim]System audio loopback active:"
                    f" {loopback_dev['name']} ({loopback_rate} Hz)[/dim]"
                )
                break
    except Exception as e:
        console.print(
            f"[yellow]No loopback available ({type(e).__name__}),"
            " microphone only.[/yellow]"
        )

    def record_mic():
        while not stop_event.is_set():
            frames_mic.append(mic_stream.read(CHUNK, exception_on_overflow=False))

    def record_loopback():
        if loopback_stream is None:
            return
        while not stop_event.is_set():
            frames_loop.append(loopback_stream.read(CHUNK, exception_on_overflow=False))

    console.print(
        "\n[bold green]Recording ...[/bold green]  [dim]Press Enter to stop[/dim]\n"
    )
    t_mic = threading.Thread(target=record_mic, daemon=True)
    t_loop = threading.Thread(target=record_loopback, daemon=True)
    t_mic.start()
    t_loop.start()

    input()
    stop_event.set()
    t_mic.join()
    t_loop.join()

    mic_stream.stop_stream()
    mic_stream.close()
    if loopback_stream:
        loopback_stream.stop_stream()
        loopback_stream.close()
    pa.terminate()

    # Bytes → numpy, mix
    def to_np(frames):
        return (
            np.frombuffer(b"".join(frames), dtype=np.int16).astype(np.float32) / 32768.0
        )

    audio_mic = to_np(frames_mic) if frames_mic else np.zeros(0)
    audio_loop = to_np(frames_loop) if frames_loop else np.zeros(0)

    # Resample loopback if needed
    if len(audio_loop) > 0 and loopback_rate != sample_rate:
        ratio = sample_rate / loopback_rate
        new_len = int(len(audio_loop) * ratio)
        audio_loop = np.interp(
            np.linspace(0, len(audio_loop) - 1, new_len),
            np.arange(len(audio_loop)),
            audio_loop,
        )

    min_len = min(len(audio_mic), len(audio_loop))
    if min_len > 0:
        mixed = (audio_mic[:min_len] + audio_loop[:min_len]) / 2
    else:
        mixed = audio_mic if len(audio_mic) > 0 else audio_loop

    audio_int16 = (np.clip(mixed, -1.0, 1.0) * 32767).astype(np.int16)

    with wave.open(str(output_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(audio_int16.tobytes())

    duration = len(mixed) / sample_rate
    console.print(f"[green]Recording saved ({duration:.1f}s): {output_path}[/green]")
    return output_path

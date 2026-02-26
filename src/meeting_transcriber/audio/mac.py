"""macOS audio recording via ProcTap (ScreenCaptureKit) and sounddevice."""

import sys
import threading
import wave
from pathlib import Path

import numpy as np
import sounddevice as sd
from rich.console import Console

from meeting_transcriber.config import TARGET_RATE

console = Console()


def list_mic_devices() -> list[dict]:
    """List available microphone input devices."""
    devices = sd.query_devices()
    mics = []
    for i, dev in enumerate(devices):
        if dev["max_input_channels"] > 0:
            mics.append(
                {
                    "index": i,
                    "name": dev["name"],
                    "channels": dev["max_input_channels"],
                    "sample_rate": int(dev["default_samplerate"]),
                }
            )
    return mics


def choose_mic(mic_spec: str | None) -> int | None:
    """Select a mic by index/name or show interactive selection.

    Returns device index or None for system default.
    """
    mics = list_mic_devices()
    if not mics:
        console.print("[yellow]No input devices found.[/yellow]")
        return None

    if mic_spec is not None:
        # Try as integer index
        try:
            idx = int(mic_spec)
            dev = sd.query_devices(idx)
            if dev["max_input_channels"] == 0:
                console.print(f"[red]Device {idx} is not an input device.[/red]")
                sys.exit(1)
            console.print(f"[green]Mic selected:[/green] {dev['name']}")
            return idx
        except ValueError:
            pass

        # Name substring match
        matches = [m for m in mics if mic_spec.lower() in m["name"].lower()]
        if len(matches) == 1:
            console.print(f"[green]Mic selected:[/green] {matches[0]['name']}")
            return matches[0]["index"]
        if len(matches) > 1:
            console.print(f"[yellow]Multiple mics match '{mic_spec}':[/yellow]")
            for i, m in enumerate(matches, 1):
                console.print(
                    f"  {i}. {m['name']}  [dim]({m['channels']}ch,"
                    f" {m['sample_rate']} Hz)[/dim]"
                )
            choice = input("Choose number: ").strip()
            try:
                return matches[int(choice) - 1]["index"]
            except (ValueError, IndexError):
                console.print("[red]Invalid selection.[/red]")
                sys.exit(1)
        console.print(f"[red]No microphone matching '{mic_spec}' found.[/red]")
        sys.exit(1)

    # Interactive selection
    default_idx = sd.default.device[0]
    console.print("\n[bold]Microphone devices:[/bold]")
    for i, m in enumerate(mics, 1):
        marker = " [green](default)[/green]" if m["index"] == default_idx else ""
        console.print(
            f"  {i:>3}. {m['name']}"
            f"  [dim]({m['channels']}ch, {m['sample_rate']} Hz)[/dim]"
            f"{marker}"
        )
    choice = input("\nChoose number (or Enter for default): ").strip()
    if not choice:
        return None
    try:
        return mics[int(choice) - 1]["index"]
    except (ValueError, IndexError):
        console.print("[red]Invalid selection.[/red]")
        sys.exit(1)


def list_audio_apps() -> list[dict]:
    """List running GUI apps (macOS) via NSWorkspace."""
    try:
        from AppKit import NSApplicationActivationPolicyRegular, NSWorkspace
    except ImportError:
        console.print(
            "[red]pyobjc not installed: pip install pyobjc-framework-Cocoa[/red]"
        )
        return []

    apps = []
    for app in NSWorkspace.sharedWorkspace().runningApplications():
        if app.activationPolicy() == NSApplicationActivationPolicyRegular:
            name = app.localizedName()
            pid = app.processIdentifier()
            if name and pid > 0:
                apps.append({"name": name, "pid": pid})
    return sorted(apps, key=lambda a: a["name"].lower())


def choose_app(app_name: str | None) -> dict | None:
    """Select an app by name or show interactive selection."""
    apps = list_audio_apps()
    if not apps:
        console.print("[yellow]No running apps found.[/yellow]")
        return None

    if app_name:
        matches = [a for a in apps if app_name.lower() in a["name"].lower()]
        if len(matches) == 1:
            console.print(
                f"[green]App found:[/green] {matches[0]['name']}"
                f" (PID {matches[0]['pid']})"
            )
            return matches[0]
        if len(matches) > 1:
            console.print(f"[yellow]Multiple matches for '{app_name}':[/yellow]")
            for i, a in enumerate(matches, 1):
                console.print(f"  {i}. {a['name']} (PID {a['pid']})")
            choice = input("Choose number: ").strip()
            try:
                return matches[int(choice) - 1]
            except (ValueError, IndexError):
                console.print("[red]Invalid selection.[/red]")
                sys.exit(1)
        console.print(f"[red]No app with name '{app_name}' found.[/red]")
        sys.exit(1)

    # Interactive selection
    console.print("\n[bold]Running apps:[/bold]")
    for i, a in enumerate(apps, 1):
        console.print(f"  {i}. {a['name']} (PID {a['pid']})")
    choice = input("\nChoose number (or Enter for microphone only): ").strip()
    if not choice:
        return None
    try:
        return apps[int(choice) - 1]
    except (ValueError, IndexError):
        console.print("[red]Invalid selection.[/red]")
        sys.exit(1)


def record_audio(
    output_path: Path,
    app_pid: int | None = None,
    mic_only: bool = False,
    mic_device: int | None = None,
) -> Path:
    """Record app audio (ProcTap) and/or microphone (sounddevice)."""
    frames_app: list[bytes] = []
    frames_mic: list[np.ndarray] = []
    stop_event = threading.Event()
    app_rate = 48000
    app_channels = 2

    # ── App audio via ProcTap ────────────────────────────────────────────
    tap = None
    if app_pid and not mic_only:
        try:
            from proctap import ProcessAudioCapture
        except ImportError:
            console.print("[red]proc-tap not installed: pip install proc-tap[/red]")
            sys.exit(1)

        def on_app_audio(pcm: bytes, frames: int) -> None:
            if not stop_event.is_set():
                frames_app.append(pcm)

        try:
            tap = ProcessAudioCapture(pid=app_pid, on_data=on_app_audio)
            tap.start()
            fmt = tap.get_format()
            app_rate = fmt.get("sample_rate", 48000)
            app_channels = fmt.get("channels", 2)
            console.print(
                f"[dim]App audio active: PID {app_pid}"
                f" ({app_rate} Hz, {app_channels}ch)[/dim]"
            )
        except Exception as e:
            console.print(
                f"[yellow]App audio failed ({type(e).__name__}: {e}),"
                " microphone only.[/yellow]"
            )
            tap = None

    # ── Microphone via sounddevice ───────────────────────────────────────
    mic_rate = TARGET_RATE

    def mic_callback(indata, frame_count, time_info, status):
        if not stop_event.is_set():
            frames_mic.append(indata[:, 0].copy())

    mic_stream = sd.InputStream(
        samplerate=mic_rate,
        channels=1,
        dtype="float32",
        callback=mic_callback,
        blocksize=1024,
        device=mic_device,
    )
    mic_stream.start()
    dev_idx = mic_device if mic_device is not None else sd.default.device[0]
    mic_name = sd.query_devices(dev_idx)["name"]
    console.print(f"[dim]Microphone active: {mic_name} ({mic_rate} Hz, mono)[/dim]")

    # ── Recording loop ───────────────────────────────────────────────────
    console.print(
        "\n[bold green]Recording ...[/bold green]  [dim]Press Enter to stop[/dim]\n"
    )
    input()
    stop_event.set()

    mic_stream.stop()
    mic_stream.close()
    if tap:
        tap.close()

    # ── Mix → WAV ────────────────────────────────────────────────────────
    audio_mic = np.concatenate(frames_mic) if frames_mic else np.zeros(0)

    audio_app = np.zeros(0)
    if frames_app:
        raw = np.frombuffer(b"".join(frames_app), dtype=np.float32)
        # Stereo → Mono
        if app_channels == 2 and len(raw) >= 2:
            raw = raw.reshape(-1, 2).mean(axis=1)
        # Resample to 16 kHz
        if app_rate != TARGET_RATE and len(raw) > 1:
            ratio = TARGET_RATE / app_rate
            new_len = int(len(raw) * ratio)
            audio_app = np.interp(
                np.linspace(0, len(raw) - 1, new_len),
                np.arange(len(raw)),
                raw,
            )
        else:
            audio_app = raw

    # Mix
    min_len = min(len(audio_mic), len(audio_app))
    if min_len > 0:
        mixed = (audio_mic[:min_len] + audio_app[:min_len]) / 2
        # Append remainder
        if len(audio_mic) > min_len:
            mixed = np.concatenate([mixed, audio_mic[min_len:] / 2])
        elif len(audio_app) > min_len:
            mixed = np.concatenate([mixed, audio_app[min_len:] / 2])
    else:
        mixed = audio_mic if len(audio_mic) > 0 else audio_app

    if len(mixed) == 0:
        console.print("[red]No audio data recorded.[/red]")
        sys.exit(1)

    audio_int16 = (np.clip(mixed, -1.0, 1.0) * 32767).astype(np.int16)

    with wave.open(str(output_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_RATE)
        wf.writeframes(audio_int16.tobytes())

    duration = len(mixed) / TARGET_RATE
    console.print(f"[green]Recording saved ({duration:.1f}s): {output_path}[/green]")
    return output_path

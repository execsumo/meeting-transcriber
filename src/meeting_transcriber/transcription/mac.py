"""macOS transcription via pywhispercpp (whisper.cpp)."""

import os
from pathlib import Path

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

from meeting_transcriber.config import DEFAULT_WHISPER_MODEL_MAC

console = Console()


def transcribe(
    audio_path: Path,
    model: str = DEFAULT_WHISPER_MODEL_MAC,
    language: str | None = None,
    diarize_enabled: bool = False,
    num_speakers: int | None = None,
) -> str:
    """Transcribe an audio file with pywhispercpp (whisper.cpp)."""
    from pywhispercpp.model import Model

    n_threads = min(os.cpu_count() or 4, 8)

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        transient=True,
    ) as progress:
        progress.add_task(f"Loading Whisper model [bold]{model}[/bold] ...", total=None)
        whisper = Model(
            model,
            n_threads=n_threads,
            print_realtime=False,
            print_progress=False,
        )

    console.print(f"[dim]Model loaded ({n_threads} threads). Transcribing ...[/dim]")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Transcribing audio ...", total=None)
        segments = whisper.transcribe(str(audio_path), language=language)

    if not diarize_enabled:
        text = " ".join(seg.text for seg in segments).strip()
        console.print(f"[green]Transcription complete ({len(text)} characters)[/green]")
        return text

    from meeting_transcriber.diarize import (
        TimestampedSegment,
        assign_speakers,
        diarize,
        format_diarized_transcript,
    )

    ts_segments = [
        TimestampedSegment(start=seg.t0 * 0.01, end=seg.t1 * 0.01, text=seg.text)
        for seg in segments
    ]

    turns = diarize(audio_path, num_speakers=num_speakers)
    ts_segments = assign_speakers(ts_segments, turns)
    text = format_diarized_transcript(ts_segments)

    console.print(
        f"[green]Transcription + diarization complete ({len(text)} characters)[/green]"
    )
    return text

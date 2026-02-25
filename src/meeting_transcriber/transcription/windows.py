"""Windows transcription via faster-whisper."""

from pathlib import Path

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn

from meeting_transcriber.config import DEFAULT_WHISPER_MODEL_WIN

console = Console()


def get_device() -> tuple[str, str]:
    """Automatically detect the fastest available hardware."""
    try:
        import torch

        if torch.cuda.is_available():
            gpu = torch.cuda.get_device_name(0)
            console.print(f"[green]GPU detected:[/green] {gpu} → CUDA (float16)")
            return "cuda", "float16"
    except ImportError:
        pass
    console.print("[dim]No GPU found → CPU (int8)[/dim]")
    return "cpu", "int8"


def transcribe(
    audio_path: Path,
    model: str = DEFAULT_WHISPER_MODEL_WIN,
    language: str | None = None,
) -> str:
    """Transcribe an audio file with faster-whisper."""
    from faster_whisper import WhisperModel

    device, compute_type = get_device()
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        transient=True,
    ) as progress:
        progress.add_task(f"Loading Whisper model [bold]{model}[/bold] ...", total=None)
        whisper = WhisperModel(model, device=device, compute_type=compute_type)

    console.print("[dim]Model loaded. Starting transcription ...[/dim]")

    with Progress(
        SpinnerColumn(), TextColumn("{task.description}"), transient=True
    ) as progress:
        progress.add_task("Transcribing audio ...", total=None)
        segments, _ = whisper.transcribe(str(audio_path), language=language)

    text = " ".join(segment.text for segment in segments).strip()
    console.print(f"[green]Transcription complete ({len(text)} characters)[/green]")
    return text

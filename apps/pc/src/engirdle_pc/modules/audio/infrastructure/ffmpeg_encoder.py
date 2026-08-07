from __future__ import annotations

import subprocess
from pathlib import Path

import imageio_ffmpeg  # type: ignore[import-untyped]


class AudioEncodingError(RuntimeError):
    """FFmpeg failed or did not produce a valid output file."""


class FfmpegAudioEncoder:
    def __init__(self, executable: Path | None = None) -> None:
        self._executable = str(executable) if executable else imageio_ffmpeg.get_ffmpeg_exe()
        self._version: str | None = None

    @property
    def version(self) -> str:
        if self._version is None:
            completed = subprocess.run(
                [self._executable, "-version"],
                check=True,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self._version = completed.stdout.splitlines()[0][:200]
        return self._version

    def encode_aac(self, wav_path: Path, output_path: Path) -> None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        completed = subprocess.run(
            [
                self._executable,
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(wav_path),
                "-c:a",
                "aac",
                "-profile:a",
                "aac_low",
                "-b:a",
                "64k",
                "-ar",
                "24000",
                "-ac",
                "1",
                "-movflags",
                "+faststart",
                str(output_path),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if (
            completed.returncode != 0
            or not output_path.is_file()
            or output_path.stat().st_size == 0
        ):
            diagnostic = completed.stderr.strip()[-1000:]
            raise AudioEncodingError(
                f"FFmpeg failed with exit code {completed.returncode}: {diagnostic}"
            )

from __future__ import annotations

from pathlib import Path
from typing import Protocol


class AudioEncoder(Protocol):
    @property
    def version(self) -> str: ...

    def encode_aac(self, wav_path: Path, output_path: Path) -> None: ...

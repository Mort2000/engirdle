from __future__ import annotations

from pathlib import Path
from typing import Protocol

from engirdle_pc.modules.audio.application.models import AudioOutput
from engirdle_pc.modules.content.public import ArticleRevision
from engirdle_pc.modules.speech.public import SentenceSpeech


class AudioStore(Protocol):
    def save(self, job_id: str, output: AudioOutput) -> None: ...

    def get(self, job_id: str) -> AudioOutput: ...


class AudioRenderer(Protocol):
    def render(
        self,
        revision: ArticleRevision,
        speech_items: tuple[SentenceSpeech, ...],
        target_dir: Path,
    ) -> AudioOutput: ...


class AudioEncoder(Protocol):
    @property
    def version(self) -> str: ...

    def encode_aac(self, wav_path: Path, output_path: Path) -> None: ...

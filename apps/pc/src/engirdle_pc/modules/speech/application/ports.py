from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class VoiceProfileRef:
    voice_profile_id: str
    revision: int
    anchor_sha256: str


@dataclass(frozen=True)
class SentenceSpeech:
    sentence_id: str
    pcm_path: Path
    sample_rate_hz: int
    sample_count: int


class SpeechStore(Protocol):
    def save(
        self, job_id: str, speech: SentenceSpeech, adapter_name: str
    ) -> None: ...

    def list_reusable_for_job(
        self, job_id: str, adapter_name: str
    ) -> tuple[SentenceSpeech, ...]: ...


class SpeechAdapter(Protocol):
    name: str
    custom_voice_model: str
    base_model: str
    generation_config_id: str

    @property
    def voice_profile(self) -> VoiceProfileRef: ...

    def synthesize(self, sentence_id: str, text: str, target_dir: Path) -> SentenceSpeech:
        """Create validated mono signed-16-bit PCM for one English sentence."""

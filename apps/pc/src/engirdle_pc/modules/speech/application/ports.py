from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

SPEECH_BATCHING = "length-sorted-pending@v1"


@dataclass(frozen=True)
class SpeechRequest:
    sentence_id: str
    text: str


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
    @property
    def batch_size(self) -> int: ...

    @property
    def name(self) -> str: ...

    @property
    def custom_voice_model(self) -> str: ...

    @property
    def base_model(self) -> str: ...

    @property
    def generation_config_id(self) -> str: ...

    @property
    def voice_profile(self) -> VoiceProfileRef: ...

    def synthesize(self, sentence_id: str, text: str, target_dir: Path) -> SentenceSpeech:
        """Create validated mono signed-16-bit PCM for one English sentence."""

    def synthesize_batch(
        self, requests: tuple[SpeechRequest, ...], target_dir: Path
    ) -> tuple[SentenceSpeech, ...]:
        """Generate one batch, returning a separate PCM in each request's order."""

    def verify_setup(self) -> None:
        """Fail fast when the speech runtime (deps, models) cannot serve at all."""

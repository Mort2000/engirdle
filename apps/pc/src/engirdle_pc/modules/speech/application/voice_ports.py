from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from engirdle_pc.modules.speech.domain.models import AnchorBatch, VoiceProfile


@dataclass(frozen=True)
class SpeakerInfo:
    name: str
    description: str


@dataclass(frozen=True)
class GeneratedAnchor:
    """One audition WAV produced by the CustomVoice anchor engine."""

    candidate_index: int
    seed: int
    wav_path: Path
    sha256: str
    duration_ms: int
    sample_rate_hz: int


class AnchorEngine(Protocol):
    """CustomVoice checkpoint boundary used only for anchor candidate generation."""

    @property
    def custom_voice_model(self) -> str: ...

    @property
    def model_fingerprint(self) -> str: ...

    @property
    def max_new_tokens(self) -> int: ...

    def english_speakers(self) -> tuple[SpeakerInfo, ...]: ...

    def generate_candidates(
        self,
        *,
        speaker: str,
        anchor_text: str,
        instruct: str,
        seed: int,
        count: int,
        target_dir: Path,
    ) -> tuple[GeneratedAnchor, ...]: ...


class VoiceProfileStore(Protocol):
    def save_batch(self, batch: AnchorBatch) -> None: ...

    def get_batch(self, batch_id: str) -> AnchorBatch:
        """Return the batch with its candidates, or raise ``KeyError``."""
        ...

    def list_batches(self) -> tuple[AnchorBatch, ...]: ...

    def save_confirmed_profile(self, profile: VoiceProfile) -> None:
        """Insert an immutable profile revision and make it the single active one."""
        ...

    def get_profile(self, voice_profile_id: str, revision: int) -> VoiceProfile:
        """Return the profile revision, or raise ``KeyError``."""
        ...

    def latest_revision(self, voice_profile_id: str) -> int:
        """Highest confirmed revision of the profile, 0 when none exists."""
        ...

    def list_profiles(self) -> tuple[VoiceProfile, ...]: ...

    def active_profile(self) -> VoiceProfile | None: ...

    def activate(self, voice_profile_id: str, revision: int) -> None: ...

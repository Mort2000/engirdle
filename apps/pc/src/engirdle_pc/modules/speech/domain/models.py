from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


class VoiceProfileError(ValueError):
    """Base class for voice-configuration failures."""


class VoiceProfileNotConfigured(VoiceProfileError):
    """No confirmed active voice profile exists yet."""


class VoiceCandidateNotFound(VoiceProfileError):
    """The requested anchor batch or candidate does not exist."""


class InvalidAnchorRequest(VoiceProfileError):
    """Speaker, anchor text or generation parameters failed validation."""


class VoiceIntegrityError(RuntimeError):
    """Server-side voice data integrity failure (not a client request problem)."""


@dataclass(frozen=True)
class AnchorCandidate:
    batch_id: str
    candidate_index: int
    seed: int
    wav_path: Path
    sha256: str
    duration_ms: int
    sample_rate_hz: int


@dataclass(frozen=True)
class AnchorBatch:
    batch_id: str
    speaker: str
    instruct: str
    anchor_text: str
    seed: int
    custom_voice_model: str
    model_fingerprint: str
    created_at: str
    candidates: tuple[AnchorCandidate, ...]


@dataclass(frozen=True)
class VoiceProfile:
    """One immutable confirmed voice profile revision (design §4.5.1)."""

    voice_profile_id: str
    revision: int
    speaker: str
    instruct: str
    anchor_text: str
    anchor_wav_path: Path
    anchor_sha256: str
    sample_rate_hz: int
    duration_ms: int
    seed: int
    generation_params_json: str
    custom_voice_model: str
    model_fingerprint: str
    source_batch_id: str
    is_active: bool
    created_at: str
    confirmed_at: str

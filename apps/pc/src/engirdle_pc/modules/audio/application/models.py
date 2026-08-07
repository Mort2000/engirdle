from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from engirdle_pc.modules.audio.domain.models import SentenceTiming


@dataclass(frozen=True)
class AudioOutput:
    path: Path
    sample_rate_hz: int
    channels: int
    duration_ms: int
    encoder_version: str
    timings: tuple[SentenceTiming, ...]


@dataclass(frozen=True)
class AudioReviewChecks:
    missing_sentence_ids: tuple[str, ...]
    zero_duration_sentence_ids: tuple[str, ...]
    abnormal_duration_sentence_ids: tuple[str, ...]


@dataclass(frozen=True)
class AudioReview:
    output: AudioOutput
    checks: AudioReviewChecks

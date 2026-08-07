from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SentenceTiming:
    sentence_id: str
    start_sample: int
    end_sample: int
    start_ms: int
    end_ms: int


@dataclass(frozen=True)
class AudioOutput:
    path: Path
    sample_rate_hz: int
    channels: int
    duration_ms: int
    encoder_version: str
    timings: tuple[SentenceTiming, ...]

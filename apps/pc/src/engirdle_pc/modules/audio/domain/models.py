from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SentenceTiming:
    sentence_id: str
    start_sample: int
    end_sample: int
    start_ms: int
    end_ms: int

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from enum import Enum


class JobStatus(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    REVIEW_REQUIRED = "review_required"
    FAILED = "failed"
    SUCCEEDED = "succeeded"


class ProductionStage(str, Enum):
    QUEUED = "queued"
    TRANSLATION = "translation"
    SPEECH = "speech"
    AUDIO = "audio"
    REVIEW = "review"
    PACKAGING = "packaging"
    PUBLISHING = "publishing"
    COMPLETE = "complete"


@dataclass(frozen=True)
class PipelineConfig:
    pipeline_version: str
    segmenter: str
    translation_adapter: str
    translation_provider: str
    translation_endpoint: str
    translation_model: str
    translation_prompt: str
    translation_thinking: str
    translation_reasoning_effort: str
    speech_adapter: str
    custom_voice_model: str
    base_model: str
    speech_generation: str
    voice_profile: str
    anchor_sha256: str

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))

    @classmethod
    def from_json(cls, value: str) -> PipelineConfig:
        payload = json.loads(value)
        payload.setdefault("translation_endpoint", "unknown")
        payload.setdefault("speech_generation", "unknown")
        return cls(**payload)


@dataclass(frozen=True)
class BuildJob:
    job_id: str
    article_id: str
    revision: int
    status: JobStatus
    stage: ProductionStage
    attempts: int
    config: PipelineConfig
    checkpoint_json: str | None
    created_at: str
    started_at: str | None
    heartbeat_at: str | None
    finished_at: str | None
    error_code: str | None
    error_message: str | None

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, replace
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
    audio_codec: str
    audio_bitrate_kbps: int
    audio_loudness_target_lufs: float
    audio_true_peak_dbfs: float
    audio_loudness_range_lu: float

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))

    @classmethod
    def from_json(cls, value: str) -> PipelineConfig:
        payload = json.loads(value)
        payload.setdefault("translation_endpoint", "unknown")
        payload.setdefault("speech_generation", "unknown")
        payload.setdefault("audio_codec", "aac-lc")
        payload.setdefault("audio_bitrate_kbps", 64)
        payload.setdefault("audio_loudness_target_lufs", -18.0)
        payload.setdefault("audio_true_peak_dbfs", -3.0)
        payload.setdefault("audio_loudness_range_lu", 11.0)
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


@dataclass(frozen=True)
class ProductionCheckpoint:
    translation_checkpoint_id: str
    accepted_block_ids: tuple[str, ...] = ()
    synthesized_sentence_ids: tuple[str, ...] = ()

    def accept_block(self, block_id: str) -> ProductionCheckpoint:
        if block_id in self.accepted_block_ids:
            return self
        return replace(
            self,
            accepted_block_ids=(*self.accepted_block_ids, block_id),
        )

    def accept_speech(self, sentence_id: str) -> ProductionCheckpoint:
        if sentence_id in self.synthesized_sentence_ids:
            return self
        return replace(
            self,
            synthesized_sentence_ids=(*self.synthesized_sentence_ids, sentence_id),
        )

    def to_json(self) -> str:
        return json.dumps(
            {
                "checkpoint_id": self.translation_checkpoint_id,
                "accepted_blocks": self.accepted_block_ids,
                "synthesized_sentences": self.synthesized_sentence_ids,
            },
            sort_keys=True,
        )

    @classmethod
    def from_json(cls, value: str | None) -> ProductionCheckpoint | None:
        if value is None:
            return None
        payload = json.loads(value)
        return cls(
            translation_checkpoint_id=str(payload["checkpoint_id"]),
            accepted_block_ids=tuple(str(item) for item in payload["accepted_blocks"]),
            synthesized_sentence_ids=tuple(
                str(item) for item in payload.get("synthesized_sentences", [])
            ),
        )

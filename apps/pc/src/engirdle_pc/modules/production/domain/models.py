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
    # Markdown parser identity (design §8.1): recorded so every stored
    # structure hash stays traceable to the projection that produced it.
    markdown_parser: str = "engirdle-gfm@1"

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
    """Unit-identity checkpoint for a production job (design §8.5).

    Tracks accepted translation units and synthesized narration units. Code,
    tables that need no work and dividers never appear here — only units the
    plans actually contain. Old persisted checkpoints (pre-markdown field
    names) are read compatibly and rewritten in the new vocabulary.
    """

    translation_checkpoint_id: str
    accepted_translation_unit_ids: tuple[str, ...] = ()
    synthesized_narration_unit_ids: tuple[str, ...] = ()

    def accept_translation_unit(self, unit_id: str) -> ProductionCheckpoint:
        if unit_id in self.accepted_translation_unit_ids:
            return self
        return replace(
            self,
            accepted_translation_unit_ids=(*self.accepted_translation_unit_ids, unit_id),
        )

    def accept_narration_unit(self, sentence_id: str) -> ProductionCheckpoint:
        if sentence_id in self.synthesized_narration_unit_ids:
            return self
        return replace(
            self,
            synthesized_narration_unit_ids=(
                *self.synthesized_narration_unit_ids,
                sentence_id,
            ),
        )

    def to_json(self) -> str:
        return json.dumps(
            {
                "checkpoint_id": self.translation_checkpoint_id,
                "accepted_translation_units": self.accepted_translation_unit_ids,
                "synthesized_narration_units": self.synthesized_narration_unit_ids,
            },
            sort_keys=True,
        )

    @classmethod
    def from_json(cls, value: str | None) -> ProductionCheckpoint | None:
        if value is None:
            return None
        payload = json.loads(value)
        # Legacy field names (accepted_blocks / synthesized_sentences) mapped
        # onto the unit vocabulary; unit identity is block/sentence identity.
        accepted = payload.get("accepted_translation_units")
        if accepted is None:
            accepted = payload.get("accepted_blocks", [])
        synthesized = payload.get("synthesized_narration_units")
        if synthesized is None:
            synthesized = payload.get("synthesized_sentences", [])
        return cls(
            translation_checkpoint_id=str(payload["checkpoint_id"]),
            accepted_translation_unit_ids=tuple(str(item) for item in accepted),
            synthesized_narration_unit_ids=tuple(str(item) for item in synthesized),
        )

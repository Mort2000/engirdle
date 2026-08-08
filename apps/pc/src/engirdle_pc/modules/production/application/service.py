from __future__ import annotations

from engirdle_pc.modules.content.public import (
    SEGMENTER_VERSION,
    ArticleRevision,
    RevisionStatus,
)
from engirdle_pc.modules.production.application.ports import JobStore
from engirdle_pc.modules.production.domain.errors import InvalidJobState
from engirdle_pc.modules.production.domain.models import (
    BuildJob,
    JobStatus,
    PipelineConfig,
    ProductionStage,
)
from engirdle_pc.modules.speech.public import SpeechService
from engirdle_pc.modules.translation.public import (
    REASONING_EFFORT,
    THINKING_MODE,
    TranslationService,
)


class ProductionService:
    def __init__(
        self,
        repository: JobStore,
        translation: TranslationService,
        speech: SpeechService,
    ) -> None:
        self._repository = repository
        self._translation = translation
        self._speech = speech

    def queue(self, revision: ArticleRevision) -> BuildJob:
        if revision.status not in {RevisionStatus.APPROVED, RevisionStatus.PUBLISHED}:
            raise ValueError("only an approved or published revision can be queued")
        voice = self._speech.voice_profile
        config = PipelineConfig(
            pipeline_version="0.1.0",
            segmenter=SEGMENTER_VERSION,
            translation_adapter=self._translation.name,
            translation_provider=self._translation.provider,
            translation_endpoint=self._translation.endpoint,
            translation_model=self._translation.model,
            translation_prompt="full-article-sequential-blocks@v1",
            translation_thinking=THINKING_MODE,
            translation_reasoning_effort=REASONING_EFFORT,
            speech_adapter=self._speech.name,
            custom_voice_model=self._speech.custom_voice_model,
            base_model=self._speech.base_model,
            speech_generation=self._speech.generation_config_id,
            voice_profile=f"{voice.voice_profile_id}@{voice.revision}",
            anchor_sha256=voice.anchor_sha256,
            audio_codec="aac-lc",
            audio_bitrate_kbps=64,
            audio_loudness_target_lufs=-18.0,
            audio_true_peak_dbfs=-3.0,
            audio_loudness_range_lu=11.0,
        )
        return self._repository.create(revision.article_id, revision.revision, config)

    def get(self, job_id: str) -> BuildJob:
        return self._repository.get(job_id)

    def list_recent(self) -> tuple[BuildJob, ...]:
        return self._repository.list_recent()

    def retry(self, job_id: str) -> BuildJob:
        return self._repository.retry(job_id)

    def require_review(self, job_id: str) -> BuildJob:
        job = self.get(job_id)
        if job.status is not JobStatus.REVIEW_REQUIRED:
            raise InvalidJobState("the job is not open for review")
        return job

    def require_audio_ready(self, job_id: str) -> BuildJob:
        job = self.get(job_id)
        if job.status not in {JobStatus.REVIEW_REQUIRED, JobStatus.SUCCEEDED}:
            raise InvalidJobState("audio is not ready")
        return job

    def audio_is_ready(self, job_id: str) -> bool:
        return self.get(job_id).status in {
            JobStatus.REVIEW_REQUIRED,
            JobStatus.SUCCEEDED,
        }

    def list_ids_for_article(self, article_id: str) -> tuple[str, ...]:
        return self._repository.list_ids_for_article(article_id)

    def delete_for_article(self, article_id: str) -> None:
        self._repository.delete_for_article(article_id)

    def mark_succeeded(self, job_id: str) -> None:
        self._repository.mark_succeeded(job_id)

    def set_release_stage(self, job_id: str, stage: ProductionStage) -> None:
        self._repository.set_review_stage(job_id, stage)

    def fail(self, job_id: str, code: str, message: str) -> None:
        self._repository.fail(job_id, code, message)

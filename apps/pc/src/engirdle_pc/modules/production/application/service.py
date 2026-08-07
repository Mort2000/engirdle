from __future__ import annotations

from engirdle_pc.modules.content.public import ArticleRevision, RevisionStatus
from engirdle_pc.modules.production.domain.models import BuildJob, PipelineConfig
from engirdle_pc.modules.production.infrastructure.sqlite_repository import JobRepository
from engirdle_pc.modules.speech.public import SpeechAdapter
from engirdle_pc.modules.translation.public import TranslationAdapter


class ProductionService:
    def __init__(
        self,
        repository: JobRepository,
        translation_adapter: TranslationAdapter,
        speech_adapter: SpeechAdapter,
    ) -> None:
        self._repository = repository
        self._translation_adapter = translation_adapter
        self._speech_adapter = speech_adapter

    def queue(self, revision: ArticleRevision) -> BuildJob:
        if revision.status not in {RevisionStatus.APPROVED, RevisionStatus.PUBLISHED}:
            raise ValueError("only an approved or published revision can be queued")
        voice = self._speech_adapter.voice_profile
        config = PipelineConfig(
            pipeline_version="0.1.0",
            segmenter="engirdle-segmenter@1",
            translation_adapter=self._translation_adapter.name,
            translation_provider=self._translation_adapter.provider,
            translation_endpoint=self._translation_adapter.endpoint,
            translation_model=self._translation_adapter.model,
            translation_prompt="full-article-sequential-blocks@v1",
            translation_thinking="enabled",
            translation_reasoning_effort="max",
            speech_adapter=self._speech_adapter.name,
            custom_voice_model=self._speech_adapter.custom_voice_model,
            base_model=self._speech_adapter.base_model,
            speech_generation=self._speech_adapter.generation_config_id,
            voice_profile=f"{voice.voice_profile_id}@{voice.revision}",
            anchor_sha256=voice.anchor_sha256,
        )
        return self._repository.create(revision.article_id, revision.revision, config)

    def get(self, job_id: str) -> BuildJob:
        return self._repository.get(job_id)

    def list_recent(self) -> tuple[BuildJob, ...]:
        return self._repository.list_recent()

    def retry(self, job_id: str) -> BuildJob:
        return self._repository.retry(job_id)

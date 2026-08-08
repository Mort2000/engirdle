from __future__ import annotations

from engirdle_pc.modules.content.public import ArticleRevision, Block
from engirdle_pc.modules.translation.application.ports import (
    ReviewedTranslation,
    TranslationAdapter,
    TranslationBatch,
    TranslationStore,
)


class InvalidTranslationBatch(ValueError):
    """An adapter changed the frozen block or sentence identity set."""


class TranslationService:
    def __init__(self, adapter: TranslationAdapter, store: TranslationStore) -> None:
        self._adapter = adapter
        self._store = store

    @property
    def name(self) -> str:
        return self._adapter.name

    @property
    def provider(self) -> str:
        return self._adapter.provider

    @property
    def endpoint(self) -> str:
        return self._adapter.endpoint

    @property
    def model(self) -> str:
        return self._adapter.model

    def begin(self, revision: ArticleRevision) -> str:
        return self._adapter.begin(revision)

    def verify_access(self) -> None:
        self._adapter.verify_access()

    def translate_block(
        self,
        job_id: str,
        revision: ArticleRevision,
        block: Block,
        checkpoint_id: str,
    ) -> TranslationBatch:
        batch = self._adapter.translate_block(revision, block, checkpoint_id)
        expected = {sentence.sentence_id for sentence in block.sentences}
        actual = {translation.sentence_id for translation in batch.translations}
        if (
            batch.block_id != block.block_id
            or actual != expected
            or len(actual) != len(batch.translations)
        ):
            raise InvalidTranslationBatch(
                f"translation adapter returned a mismatched ID set for {block.block_id}"
            )
        self._store.save(job_id, batch.translations, self.name)
        return batch

    def list_for_job(self, job_id: str) -> tuple[ReviewedTranslation, ...]:
        return self._store.list_for_job(job_id)

    def edit(self, job_id: str, sentence_id: str, text: str) -> None:
        self._store.edit(job_id, sentence_id, text)

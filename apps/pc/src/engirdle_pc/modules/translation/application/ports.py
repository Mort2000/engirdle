from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from engirdle_pc.modules.content.public import ArticleRevision, Block


@dataclass(frozen=True)
class SentenceTranslation:
    sentence_id: str
    text_zh: str


@dataclass(frozen=True)
class TranslationBatch:
    block_id: str
    translations: tuple[SentenceTranslation, ...]
    request_id: str


@dataclass(frozen=True)
class ReviewedTranslation:
    sentence_id: str
    generated_text: str
    edited_text: str | None

    @property
    def published_text(self) -> str:
        return self.edited_text or self.generated_text


class TranslationStore(Protocol):
    def save(
        self,
        job_id: str,
        translations: tuple[SentenceTranslation, ...],
        adapter_name: str,
    ) -> None: ...

    def edit(self, job_id: str, sentence_id: str, text: str) -> None: ...

    def list_for_job(self, job_id: str) -> tuple[ReviewedTranslation, ...]: ...


class TranslationAdapter(Protocol):
    name: str
    provider: str
    endpoint: str
    model: str

    def begin(self, revision: ArticleRevision) -> str:
        """Establish the full-article logical context and return its checkpoint ID."""

    def translate_block(
        self, revision: ArticleRevision, block: Block, checkpoint_id: str
    ) -> TranslationBatch:
        """Translate one block without changing its sentence ID set."""

    def verify_access(self) -> None:
        """Confirm the provider is reachable and the credentials are valid."""

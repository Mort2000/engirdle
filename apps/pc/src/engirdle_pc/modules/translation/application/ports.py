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

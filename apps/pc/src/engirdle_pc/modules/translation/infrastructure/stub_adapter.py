from __future__ import annotations

from engirdle_pc.modules.content.public import ArticleRevision, Block
from engirdle_pc.modules.translation.application.ports import (
    SentenceTranslation,
    TranslationBatch,
)
from engirdle_pc.shared.application.runtime import IdentifierGenerator


class StubTranslationAdapter:
    """Deterministic integration stub; it never calls a remote translation service."""

    name = "stub"
    provider = "stub-deepseek"
    endpoint = "stub://deepseek"
    model = "deepseek-v4-flash"

    def __init__(self, identifiers: IdentifierGenerator) -> None:
        self._identifiers = identifiers

    def begin(self, revision: ArticleRevision) -> str:
        return f"stub-context-{revision.article_id}-{revision.revision}"

    def translate_block(
        self, revision: ArticleRevision, block: Block, checkpoint_id: str
    ) -> TranslationBatch:
        del revision, checkpoint_id
        return TranslationBatch(
            block_id=block.block_id,
            translations=tuple(
                SentenceTranslation(
                    sentence_id=sentence.sentence_id,
                    text_zh=f"【翻译桩】{sentence.text}",
                )
                for sentence in block.sentences
            ),
            request_id=f"stub-{self._identifiers.new()}",
        )

"""Test-only deterministic translation adapter.

This is the relocated production stub: the real translation path now always
uses the DeepSeek adapter, so the deterministic translator lives here purely to
drive worker/acceptance tests without touching the network. It mirrors the old
stub's identity (``name="stub"``) so existing config-snapshot assertions stay
valid, and implements ``verify_access`` as a no-op like the production fake.
"""

from __future__ import annotations

from engirdle_pc.modules.content.public import ArticleRevision, Block
from engirdle_pc.modules.translation.public import (
    SentenceTranslation,
    TranslationBatch,
)
from engirdle_pc.shared.application.runtime import IdentifierGenerator


class FakeTranslationAdapter:
    """Deterministic translation adapter for tests; never calls a remote service."""

    name = "stub"
    provider = "stub-deepseek"
    endpoint = "stub://deepseek"
    model = "deepseek-v4-flash-stub"

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

    def verify_access(self) -> None:
        return None


def build_fake_translation_adapter() -> FakeTranslationAdapter:
    from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator

    return FakeTranslationAdapter(UuidIdentifierGenerator())

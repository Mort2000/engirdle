"""Test-only deterministic translation adapter (unit protocol v2).

This is the relocated production stub: the real translation path always uses
the DeepSeek adapter, so the deterministic translator lives here purely to
drive worker/acceptance tests without touching the network. It mirrors the old
stub identity (name='stub') so config-snapshot assertions stay valid.

Every unit request is recorded verbatim (wire JSON plus the rebuilt history)
so route-isolation tests can assert that code sentinels never appear in any
LLM request, journal or retry — not merely that code has no output.
"""

from __future__ import annotations

import json

from engirdle_pc.modules.content.domain.plan import (
    ProcessingPlan,
    SentenceBatchUnit,
    TableUnit,
)
from engirdle_pc.modules.translation.application.dto import (
    build_source_context,
    build_unit_request,
    unit_protected_map,
)
from engirdle_pc.modules.translation.application.units import (
    AcceptedTranslation,
    ProtectedTokenMap,
    SentenceTranslation,
    SentenceUnitTranslation,
    TableTranslatedCell,
    TableUnitTranslation,
)
from engirdle_pc.shared.application.runtime import IdentifierGenerator


class RecordedRequest:
    """One fake-adapter LLM request, captured for isolation assertions."""

    def __init__(self, messages: list[dict[str, str]], unit_id: str) -> None:
        self.messages = messages
        self.unit_id = unit_id

    @property
    def text(self) -> str:
        return "\n".join(message["content"] for message in self.messages)

    def __contains__(self, needle: str) -> bool:
        return needle in self.text


class FakeTranslationAdapter:
    """Deterministic translation adapter for tests; never calls a remote service."""

    name = "stub"
    provider = "stub-deepseek"
    endpoint = "stub://deepseek"
    model = "deepseek-v4-flash-stub"

    def __init__(self, identifiers: IdentifierGenerator) -> None:
        self._identifiers = identifiers
        self.requests: list[RecordedRequest] = []
        self.contexts: list[str] = []
        self.fail_next = 0

    # -- test helpers -----------------------------------------------------

    def fail_next_units(self, count: int) -> None:
        """Make the next 'count' units raise once (retry/checkpoint tests)."""
        self.fail_next = count

    def all_request_text(self) -> str:
        return "\n".join(request.text for request in self.requests)

    # -- adapter protocol --------------------------------------------------

    def begin(self, revision: object, plan: ProcessingPlan) -> str:
        self.contexts.append(build_source_context(revision, plan))  # type: ignore[arg-type]
        return f"stub-context-{revision.article_id}-{revision.revision}"  # type: ignore[attr-defined]

    def translate_unit(
        self,
        revision: object,
        plan: ProcessingPlan,
        unit: object,
        checkpoint_id: str,
    ) -> AcceptedTranslation:
        del revision, checkpoint_id
        if self.fail_next > 0:
            self.fail_next -= 1
            raise RuntimeError("stub translation failure")
        protected_map = unit_protected_map(unit)  # type: ignore[arg-type]
        request = build_unit_request(unit)  # type: ignore[arg-type]
        messages = [{"role": "user", "content": request}]
        self.requests.append(RecordedRequest(messages, unit.unit_id))  # type: ignore[attr-defined]
        if isinstance(unit, SentenceBatchUnit):
            restored = [protected_map.restore(text) for text in json.loads(request)]
            return AcceptedTranslation(
                translation=SentenceUnitTranslation(
                    block_id=unit.block_id,
                    translations=tuple(
                        SentenceTranslation(
                            sentence_id=sentence.sentence_id,
                            text_zh=f"【翻译桩】{restored[index]}",
                        )
                        for index, sentence in enumerate(unit.sentences)
                    ),
                ),
                request_id=f"stub-{self._identifiers.new()}",
            )
        if isinstance(unit, TableUnit):
            payload = json.loads(request)
            cells = tuple(
                TableTranslatedCell(
                    cell_id=cell["cell_id"],
                    text_zh=f"【译】{protected_map.restore(cell['text'])}"
                    if cell["text"].strip()
                    else "【译】",
                )
                for row in [payload["header"], *payload["rows"]]
                for cell in row
            )
            return AcceptedTranslation(
                translation=TableUnitTranslation(block_id=unit.block_id, cells=cells),
                request_id=f"stub-{self._identifiers.new()}",
            )
        raise AssertionError(f"unknown unit type: {type(unit).__name__}")

    def verify_access(self) -> None:
        return None


class RecordingJournal:
    """Captures journal writes for isolation assertions."""

    def __init__(self) -> None:
        self.accepted: dict[str, str] = {}
        self.writes = 0

    def accept_unit(self, unit_id: str, reply: str) -> None:
        self.accepted[unit_id] = reply
        self.writes += 1


def build_fake_translation_adapter() -> FakeTranslationAdapter:
    from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator

    return FakeTranslationAdapter(UuidIdentifierGenerator())


def placeholder_map_none() -> ProtectedTokenMap:
    return ProtectedTokenMap()

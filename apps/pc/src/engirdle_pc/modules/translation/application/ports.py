from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from engirdle_pc.modules.content.domain.entities import ArticleRevision
from engirdle_pc.modules.content.domain.plan import (
    ProcessingPlan,
    SentenceBatchUnit,
    TableUnit,
)
from engirdle_pc.modules.translation.application.units import (
    AcceptedTranslation,
    SentenceUnitTranslation,
    TableUnitTranslation,
    UnitKind,
)

TranslationUnit = SentenceBatchUnit | TableUnit
UnitTranslation = SentenceUnitTranslation | TableUnitTranslation


@dataclass(frozen=True)
class ReviewedUnit:
    """One reviewed translation result, typed by unit kind (design §8.4)."""

    unit_id: str
    unit_kind: UnitKind
    generated: UnitTranslation
    edited: UnitTranslation | None
    adapter_name: str

    @property
    def published(self) -> UnitTranslation:
        return self.edited or self.generated


class TranslationStore(Protocol):
    def save(
        self,
        job_id: str,
        accepted: tuple[AcceptedTranslation, ...],
        adapter_name: str,
    ) -> None: ...

    def edit_sentence(self, job_id: str, sentence_id: str, edit_text: str) -> None: ...

    def edit_table(
        self, job_id: str, block_id: str, translation: TableUnitTranslation
    ) -> None: ...

    def list_for_job(self, job_id: str) -> tuple[ReviewedUnit, ...]: ...


class TranslationAdapter(Protocol):
    name: str
    provider: str
    endpoint: str
    model: str

    def begin(self, revision: ArticleRevision, plan: ProcessingPlan) -> str:
        """Establish the code-free article context; return its checkpoint ID."""

    def translate_unit(
        self,
        revision: ArticleRevision,
        plan: ProcessingPlan,
        unit: TranslationUnit,
        checkpoint_id: str,
    ) -> AcceptedTranslation:
        """Translate one plan unit without changing its identity set."""

    def verify_access(self) -> None:
        """Confirm the provider is reachable and the credentials are valid."""


__all__ = [
    "AcceptedTranslation",
    "ReviewedUnit",
    "TranslationAdapter",
    "TranslationStore",
    "TranslationUnit",
    "UnitKind",
    "UnitTranslation",
]

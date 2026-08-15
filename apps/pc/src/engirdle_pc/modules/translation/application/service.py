from __future__ import annotations

import logging

from engirdle_pc.modules.content.domain.entities import ArticleRevision
from engirdle_pc.modules.content.domain.plan import (
    ProcessingPlan,
    SentenceBatchUnit,
    TableUnit,
)
from engirdle_pc.modules.translation.application.ports import (
    ReviewedUnit,
    TranslationAdapter,
    TranslationStore,
    TranslationUnit,
)
from engirdle_pc.modules.translation.application.units import (
    AcceptedTranslation,
    SentenceUnitTranslation,
    TableTranslatedCell,
    TableUnitTranslation,
    UnitKind,
    verify_edited_table_shape,
    verify_sentence_batch,
    verify_table_translation,
)

LOGGER = logging.getLogger(__name__)


class InvalidTranslationUnit(ValueError):
    """An adapter returned a result whose kind or identity set does not match."""


class InvalidTranslationEdit(ValueError):
    """A manual translation edit is empty or otherwise unusable."""


# Wire-side translation length cap shared by the sentence/cell contract
# (article.schema.json translation_zh maxLength 40000). Enforced here so
# every entry path — API model or admin HTML form — stores the same bound;
# an over-long edit would otherwise only fail later at publish time.
_MAX_TRANSLATION_LENGTH = 40_000


def _require_publishable_text(text: str, what: str) -> None:
    if not text.strip():
        raise InvalidTranslationEdit(f"{what} must not be empty")
    if len(text) > _MAX_TRANSLATION_LENGTH:
        raise InvalidTranslationEdit(
            f"{what} exceeds the {_MAX_TRANSLATION_LENGTH}-character limit"
        )


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

    def begin(self, revision: ArticleRevision, plan: ProcessingPlan) -> str:
        return self._adapter.begin(revision, plan)

    def verify_access(self) -> None:
        self._adapter.verify_access()

    def translate_unit(
        self,
        job_id: str,
        revision: ArticleRevision,
        plan: ProcessingPlan,
        unit: TranslationUnit,
        checkpoint_id: str,
    ) -> AcceptedTranslation:
        accepted = self._adapter.translate_unit(revision, plan, unit, checkpoint_id)
        if isinstance(unit, SentenceBatchUnit):
            if not isinstance(accepted.translation, SentenceUnitTranslation):
                raise InvalidTranslationUnit(
                    f"adapter returned a table result for sentence unit {unit.block_id}"
                )
            verify_sentence_batch(unit, accepted.translation)
        elif isinstance(unit, TableUnit):
            if not isinstance(accepted.translation, TableUnitTranslation):
                raise InvalidTranslationUnit(
                    f"adapter returned a sentence result for table unit {unit.block_id}"
                )
            verify_table_translation(unit, accepted.translation)
        else:
            raise InvalidTranslationUnit(
                f"unknown translation unit type: {type(unit).__name__}"
            )
        self._store.save(job_id, (accepted,), self.name)
        return accepted

    def list_for_job(self, job_id: str) -> tuple[ReviewedUnit, ...]:
        return self._store.list_for_job(job_id)

    def sentence_translations(self, job_id: str) -> dict[str, str]:
        """Published sentence translations keyed by sentence ID."""
        published: dict[str, str] = {}
        for unit in self._store.list_for_job(job_id):
            value = unit.published
            if unit.unit_kind is UnitKind.SENTENCE and isinstance(
                value, SentenceUnitTranslation
            ):
                published.update(
                    {item.sentence_id: item.text_zh for item in value.translations}
                )
        return published

    def table_translations(self, job_id: str) -> dict[str, TableUnitTranslation]:
        """Published table translations keyed by block ID."""
        published: dict[str, TableUnitTranslation] = {}
        for unit in self._store.list_for_job(job_id):
            value = unit.published
            if unit.unit_kind is UnitKind.TABLE and isinstance(
                value, TableUnitTranslation
            ):
                published[unit.unit_id] = value
        return published

    def edit_sentence(self, job_id: str, sentence_id: str, edit_text: str) -> None:
        # Publishability (non-empty, within the wire length cap) is enforced
        # here at the application boundary for EVERY entry path, instead of
        # being stripped into an unmodifiable stored value that only fails
        # much later at publish time.
        _require_publishable_text(edit_text, "a sentence translation")
        self._store.edit_sentence(job_id, sentence_id, edit_text)

    def edit_table(
        self, job_id: str, block_id: str, translation: TableUnitTranslation
    ) -> None:
        self._store.edit_table(job_id, block_id, translation)

    def edit_table_cells(
        self, job_id: str, block_id: str, cells: tuple[TableTranslatedCell, ...]
    ) -> TableUnitTranslation:
        """Validate and persist a whole manual table correction (design §8.4).

        Owns the read-validate-persist flow so HTTP layers only translate
        requests: the unit must exist, the edit must keep the exact cell
        identity sequence, and every cell text must be non-empty.
        """
        edited = TableUnitTranslation(block_id=block_id, cells=cells)
        for cell in cells:
            _require_publishable_text(
                cell.text_zh, f"a translation for table cell {cell.cell_id}"
            )
        unit = next(
            (
                item
                for item in self._store.list_for_job(job_id)
                if item.unit_id == block_id and item.unit_kind is UnitKind.TABLE
            ),
            None,
        )
        if unit is None or not isinstance(
            unit.generated, TableUnitTranslation
        ):
            raise KeyError(f"table translation {job_id}/{block_id} not found")
        verify_edited_table_shape(unit.generated, edited)
        self._store.edit_table(job_id, block_id, edited)
        return edited

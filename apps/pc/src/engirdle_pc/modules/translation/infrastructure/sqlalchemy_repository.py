"""SQLAlchemy 2.0 implementation of the TranslationStore protocol.

Unit payloads are boundary JSON (design §8.4): the database stores JSON only
at this persistence seam, and every read is decoded into typed
SentenceUnitTranslation / TableUnitTranslation results before leaving the
repository.
"""

from __future__ import annotations

import json
from typing import Any, cast

from sqlalchemy import select, text, update
from sqlalchemy.dialects.sqlite import insert
from sqlalchemy.engine import CursorResult

from engirdle_pc.modules.translation.application.ports import ReviewedUnit
from engirdle_pc.modules.translation.application.units import (
    AcceptedTranslation,
    SentenceTranslation,
    SentenceUnitTranslation,
    TableTranslatedCell,
    TableUnitTranslation,
    UnitKind,
)
from engirdle_pc.modules.translation.infrastructure.orm import TranslationUnitRecord
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemyTranslationRepository:
    """SQLAlchemy 2.0 implementation of the TranslationStore protocol."""

    def __init__(self, database: Database) -> None:
        self._database = database

    def save(
        self,
        job_id: str,
        accepted: tuple[AcceptedTranslation, ...],
        adapter_name: str,
    ) -> None:
        if not accepted:
            return
        rows = []
        for item in accepted:
            translation = item.translation
            if isinstance(translation, SentenceUnitTranslation):
                unit_kind = UnitKind.SENTENCE
                payload = {
                    "translations": [
                        {"sentence_id": entry.sentence_id, "text_zh": entry.text_zh}
                        for entry in translation.translations
                    ]
                }
                unit_id = translation.block_id
            else:
                unit_kind = UnitKind.TABLE
                payload = {
                    "cells": [
                        {"cell_id": cell.cell_id, "text_zh": cell.text_zh}
                        for cell in translation.cells
                    ]
                }
                unit_id = translation.block_id
            rows.append(
                {
                    "job_id": job_id,
                    "unit_id": unit_id,
                    "unit_kind": unit_kind.value,
                    "generated_payload": json.dumps(payload, ensure_ascii=False),
                    "adapter_name": adapter_name,
                }
            )
        stmt = insert(TranslationUnitRecord)
        stmt = stmt.on_conflict_do_update(
            index_elements=["job_id", "unit_id"],
            set_={
                "generated_payload": stmt.excluded.generated_payload,
                "adapter_name": stmt.excluded.adapter_name,
            },
        )
        with self._database.sessions() as session, session.begin():
            session.execute(stmt, rows)

    def edit_sentence(self, job_id: str, sentence_id: str, edit_text: str) -> None:
        # A sentence edit rewrites its owning unit's edited payload so review
        # keeps working on whole units (design §8.4); other sentences in the
        # same unit keep any previously edited value.
        with self._database.sessions() as session, session.begin():
            target = self._find_sentence_unit(session, job_id, sentence_id)
            if target is None:
                raise KeyError(f"translation {job_id}/{sentence_id} not found")
            generated = _sentence_payload(target.generated_payload)
            edited = (
                _sentence_payload(target.edited_payload)
                if target.edited_payload
                else generated
            )
            merged = {
                "translations": [
                    {
                        "sentence_id": entry["sentence_id"],
                        "text_zh": (
                            edit_text.strip()
                            if entry["sentence_id"] == sentence_id
                            else edited.texts.get(
                                entry["sentence_id"], entry["text_zh"]
                            )
                        ),
                    }
                    for entry in generated.entries
                ]
            }
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(TranslationUnitRecord)
                    .where(
                        TranslationUnitRecord.job_id == job_id,
                        TranslationUnitRecord.unit_id == target.unit_id,
                    )
                    .values(edited_payload=json.dumps(merged, ensure_ascii=False))
                ),
            ).rowcount
            if updated != 1:
                raise KeyError(f"translation {job_id}/{sentence_id} not found")

    def edit_table(
        self, job_id: str, block_id: str, translation: TableUnitTranslation
    ) -> None:
        payload = {
            "cells": [
                {"cell_id": cell.cell_id, "text_zh": cell.text_zh}
                for cell in translation.cells
            ]
        }
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(TranslationUnitRecord)
                    .where(
                        TranslationUnitRecord.job_id == job_id,
                        TranslationUnitRecord.unit_id == block_id,
                        TranslationUnitRecord.unit_kind == UnitKind.TABLE.value,
                    )
                    .values(edited_payload=json.dumps(payload, ensure_ascii=False))
                ),
            ).rowcount
            if updated != 1:
                raise KeyError(f"table translation {job_id}/{block_id} not found")

    def list_for_job(self, job_id: str) -> tuple[ReviewedUnit, ...]:
        with self._database.sessions() as session, session.begin():
            records = session.scalars(
                select(TranslationUnitRecord)
                .where(TranslationUnitRecord.job_id == job_id)
                .order_by(text("rowid"))
            )
            return tuple(_reviewed_from_record(record) for record in records)

    def _find_sentence_unit(
        self, session: Any, job_id: str, sentence_id: str
    ) -> TranslationUnitRecord | None:
        records = session.scalars(
            select(TranslationUnitRecord)
            .where(
                TranslationUnitRecord.job_id == job_id,
                TranslationUnitRecord.unit_kind == UnitKind.SENTENCE.value,
            )
            .order_by(text("rowid"))
        )
        for record in records:
            if sentence_id in _sentence_payload(record.generated_payload).ids:
                return cast(TranslationUnitRecord, record)
        return None


class _DecodedSentencePayload:
    def __init__(self, payload_json: str) -> None:
        payload = json.loads(payload_json) if payload_json else {}
        self.entries: list[dict[str, str]] = [
            {
                "sentence_id": str(entry["sentence_id"]),
                "text_zh": str(entry["text_zh"]),
            }
            for entry in payload.get("translations", [])
        ]
        self.ids = tuple(entry["sentence_id"] for entry in self.entries)
        self.texts = {
            entry["sentence_id"]: entry["text_zh"] for entry in self.entries
        }


def _sentence_payload(payload_json: str | None) -> _DecodedSentencePayload:
    return _DecodedSentencePayload(payload_json or "{}")


def _reviewed_from_record(record: TranslationUnitRecord) -> ReviewedUnit:
    kind = UnitKind(record.unit_kind)
    generated = json.loads(record.generated_payload)
    edited = json.loads(record.edited_payload) if record.edited_payload else None
    if kind is UnitKind.SENTENCE:
        return ReviewedUnit(
            unit_id=record.unit_id,
            unit_kind=kind,
            generated=SentenceUnitTranslation(
                block_id=record.unit_id,
                translations=tuple(
                    SentenceTranslation(
                        sentence_id=str(entry["sentence_id"]),
                        text_zh=str(entry["text_zh"]),
                    )
                    for entry in generated.get("translations", [])
                ),
            ),
            edited=(
                SentenceUnitTranslation(
                    block_id=record.unit_id,
                    translations=tuple(
                        SentenceTranslation(
                            sentence_id=str(entry["sentence_id"]),
                            text_zh=str(entry["text_zh"]),
                        )
                        for entry in edited.get("translations", [])
                    ),
                )
                if edited
                else None
            ),
            adapter_name=record.adapter_name,
        )
    return ReviewedUnit(
        unit_id=record.unit_id,
        unit_kind=kind,
        generated=TableUnitTranslation(
            block_id=record.unit_id,
            cells=tuple(
                TableTranslatedCell(
                    cell_id=str(entry["cell_id"]), text_zh=str(entry["text_zh"])
                )
                for entry in generated.get("cells", [])
            ),
        ),
        edited=(
            TableUnitTranslation(
                block_id=record.unit_id,
                cells=tuple(
                    TableTranslatedCell(
                        cell_id=str(entry["cell_id"]), text_zh=str(entry["text_zh"])
                    )
                    for entry in edited.get("cells", [])
                ),
            )
            if edited
            else None
        ),
        adapter_name=record.adapter_name,
    )

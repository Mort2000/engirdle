"""Markdown typed-block storage and generic translation units (design §12.1).

Revision ID: 0004_markdown_blocks
Revises: 0003_catalog_version_floor
Create Date: 2026-08-14

- content_blocks gains a typed payload document (heading level, list info,
  table structure, code body);
- content_sentences gains the inline render document (runs);
- the sentence-only `translations` table is replaced by a generic
  `translation_units` table keyed by unit identity and kind, using the
  new-table → convert → verify → replace flow so a failure leaves the old
  table intact.

Legacy paragraph rows stay valid: the new columns default to an empty payload
that decodes to the equivalent plain TextBlock. Legacy list_item rows are
backfilled with the v1.0 defaults (`list_kind` bullet, depth 0) and quote rows
with depth 1, because the typed model requires them. Every legacy sentence
translation is regrouped under its owning text block (looked up via the job's
revision) into the boundary JSON the new repository expects:
`{"translations": [{"sentence_id", "text_zh"}, ...]}` keyed by block_id.
"""

from __future__ import annotations

import json
from typing import Any

from alembic import op
from sqlalchemy import text

revision = "0004_markdown_blocks"
down_revision = "0003_catalog_version_floor"
branch_labels = None
depends_on = None


def upgrade() -> None:
    connection = op.get_bind()
    # Preflight every abortable data check BEFORE the first DDL: pysqlite's
    # legacy transaction mode lets ALTER TABLE autocommit, so a failure after
    # DDL would leave a half-upgraded schema that cannot simply be retried.
    # Aborting here leaves the database byte-identical to 0003.
    _preflight_legacy_translations(connection)

    # Idempotent column adds: even if a previous attempt somehow died between
    # DDL statements, a retry converges instead of failing on duplicates.
    block_columns = {
        row[1] for row in connection.execute(text("PRAGMA table_info(content_blocks)"))
    }
    if "payload_json" not in block_columns:
        op.execute(
            "ALTER TABLE content_blocks ADD COLUMN payload_json TEXT NOT NULL DEFAULT '{}'"
        )
    sentence_columns = {
        row[1]
        for row in connection.execute(text("PRAGMA table_info(content_sentences)"))
    }
    if "render_json" not in sentence_columns:
        op.execute(
            "ALTER TABLE content_sentences ADD COLUMN render_json TEXT NOT NULL DEFAULT '[]'"
        )
    # Legacy text blocks carry no style payload beyond their kind; backfill the
    # style so decodes are explicit rather than inferred. list_item needs the
    # v1.0 defaults (bullet, depth 0) because the typed TextBlock requires a
    # list kind; quote defaults to a single level. Guarded on the default so a
    # retry never overwrites an already-backfilled payload.
    op.execute(
        """
        UPDATE content_blocks
        SET payload_json = CASE kind
            WHEN 'list_item' THEN json_object(
                'style', 'list_item', 'list_kind', 'bullet', 'list_depth', 0
            )
            WHEN 'quote' THEN json_object('style', 'quote', 'quote_depth', 1)
            ELSE json_object('style', 'paragraph')
        END
        WHERE kind IN ('paragraph', 'list_item', 'quote')
          AND payload_json = '{}'
        """
    )
    # translation_units is derived state until the final swap: recreate it so
    # a retry after a mid-flight failure never stacks duplicate conversions.
    op.execute("DROP TABLE IF EXISTS translation_units")
    op.execute(
        """
        CREATE TABLE translation_units (
            job_id TEXT NOT NULL,
            unit_id TEXT NOT NULL,
            unit_kind TEXT NOT NULL,
            generated_payload TEXT NOT NULL,
            edited_payload TEXT,
            adapter_name TEXT NOT NULL,
            PRIMARY KEY (job_id, unit_id),
            FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
        )
        """
    )
    _convert_sentence_translations(connection)
    # The legacy sentence-only table is intentionally dropped: sentence
    # translations now live keyed by their owning block unit. Downgrade is not
    # supported (design §12.1.6).
    op.execute("DROP TABLE translations")


def _preflight_legacy_translations(connection: Any) -> None:
    """Fail before any DDL when the legacy data cannot convert losslessly."""
    if not connection.execute(
        text(
            "SELECT name FROM sqlite_master WHERE type='table'"
            " AND name='translations'"
        )
    ).fetchone():
        return  # fresh database: nothing to convert
    dangling = connection.execute(
        text(
            """
            SELECT COUNT(*) FROM translations t
            WHERE NOT EXISTS (SELECT 1 FROM build_jobs j WHERE j.job_id = t.job_id)
            """
        )
    ).scalar_one()
    if dangling:
        raise RuntimeError(
            f"{dangling} legacy translation rows reference missing build jobs; "
            "refusing to migrate (no schema change has been applied yet)"
        )
    mixed = connection.execute(
        text(
            """
            SELECT COUNT(*) FROM (
                SELECT t.job_id, COALESCE(s.block_id, t.sentence_id) AS unit_id
                FROM translations t
                JOIN build_jobs j ON j.job_id = t.job_id
                LEFT JOIN content_sentences s
                       ON s.article_id = j.article_id
                      AND s.revision = j.revision
                      AND s.sentence_id = t.sentence_id
                GROUP BY t.job_id, COALESCE(s.block_id, t.sentence_id)
                HAVING COUNT(DISTINCT t.adapter_name) > 1
            )
            """
        )
    ).scalar_one()
    if mixed:
        raise RuntimeError(
            f"{mixed} legacy translation units mix adapter names; refusing to "
            "migrate (no schema change has been applied yet)"
        )


def _convert_sentence_translations(connection: Any) -> None:
    """Regroup legacy sentence rows into per-block 'sentence' units.

    Each legacy (job_id, sentence_id) row is joined to its block through the
    job's revision. Sentences sharing a block become ONE unit whose payload is
    the boundary JSON the new repository decodes — ordered by sentence_order —
    so review, resume and publishing keep working over migrated data. A row
    whose sentence no longer exists (the structure was re-edited after the
    translation was written) becomes its own unit keyed by the sentence id
    instead of being silently dropped. Abortable data conditions (dangling
    jobs, mixed adapters) were already rejected by the preflight, which runs
    before any DDL.
    """
    legacy_total = connection.execute(
        text("SELECT COUNT(*) FROM translations")
    ).scalar_one()
    rows = connection.execute(
        text(
            """
            SELECT t.job_id AS job_id,
                   COALESCE(s.block_id, t.sentence_id) AS unit_id,
                   t.sentence_id AS sentence_id,
                   t.generated_text AS generated_text,
                   t.edited_text AS edited_text,
                   t.adapter_name AS adapter_name,
                   s.sentence_order AS sentence_order
            FROM translations t
            JOIN build_jobs j ON j.job_id = t.job_id
            LEFT JOIN content_sentences s
                   ON s.article_id = j.article_id
                  AND s.revision = j.revision
                  AND s.sentence_id = t.sentence_id
            """
        )
    ).fetchall()
    if len(rows) != legacy_total:  # pragma: no cover - guarded by preflight
        raise RuntimeError(
            f"translation conversion lost rows: {legacy_total} legacy rows "
            f"produced {len(rows)} joined rows"
        )
    grouped: dict[tuple[str, str], list[dict[str, object]]] = {}
    for row in rows:
        grouped.setdefault((row.job_id, row.unit_id), []).append(
            {
                "sentence_id": row.sentence_id,
                "generated_text": row.generated_text,
                "edited_text": row.edited_text,
                "sentence_order": row.sentence_order,
                "adapter_name": row.adapter_name,
            }
        )
    for (job_id, unit_id), entries in grouped.items():
        # Deterministic order: stored sentence order first (orphan rows have
        # none and sort by sentence id).
        entries.sort(
            key=lambda entry: (
                entry["sentence_order"]
                if entry["sentence_order"] is not None
                else -1,
                str(entry["sentence_id"]),
            )
        )
        generated = {
            "translations": [
                {
                    "sentence_id": entry["sentence_id"],
                    "text_zh": entry["generated_text"],
                }
                for entry in entries
            ]
        }
        edited: dict[str, object] | None = None
        if any(entry["edited_text"] is not None for entry in entries):
            # The edited payload is the complete merged list (the shape
            # edit_sentence persists): non-edited sentences keep the
            # generated value so review always sees a whole unit.
            edited = {
                "translations": [
                    {
                        "sentence_id": entry["sentence_id"],
                        "text_zh": entry["edited_text"]
                        or entry["generated_text"],
                    }
                    for entry in entries
                ]
            }
        connection.execute(
            text(
                """
                INSERT INTO translation_units (
                    job_id, unit_id, unit_kind, generated_payload,
                    edited_payload, adapter_name
                ) VALUES (:job_id, :unit_id, 'sentence', :generated_payload,
                          :edited_payload, :adapter_name)
                """
            ),
            {
                "job_id": job_id,
                "unit_id": unit_id,
                "generated_payload": json.dumps(generated, ensure_ascii=False),
                "edited_payload": (
                    json.dumps(edited, ensure_ascii=False) if edited else None
                ),
                "adapter_name": entries[0]["adapter_name"],
            },
        )
    # Verify the conversion by decoding what was actually written: every
    # legacy sentence must survive exactly once under its unit.
    written = connection.execute(
        text(
            """
            SELECT job_id, unit_id, generated_payload FROM translation_units
            WHERE unit_kind = 'sentence'
            """
        )
    ).fetchall()
    seen: set[tuple[str, str]] = set()
    total_entries = 0
    for record in written:
        payload = json.loads(record.generated_payload)
        entries = payload.get("translations", [])
        total_entries += len(entries)
        for entry in entries:
            key = (record.job_id, str(entry["sentence_id"]))
            if key in seen:
                raise RuntimeError(
                    f"duplicate migrated sentence translation: {key}"
                )
            seen.add(key)
    if total_entries != legacy_total:
        raise RuntimeError(
            f"translation conversion lost rows: {legacy_total} legacy rows "
            f"produced {total_entries} migrated sentence entries"
        )


def downgrade() -> None:
    # The sentence-only table cannot represent block-keyed units, so going
    # back is explicitly unsupported (design §12.1.6). Best-effort sentence
    # rows are still materialized for operators inspecting an old checkout.
    op.execute(
        """
        CREATE TABLE translations (
            job_id TEXT NOT NULL,
            sentence_id TEXT NOT NULL,
            generated_text TEXT NOT NULL,
            edited_text TEXT,
            adapter_name TEXT NOT NULL,
            PRIMARY KEY (job_id, sentence_id),
            FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
        )
        """
    )
    _expand_sentence_units(op.get_bind())
    op.execute("DROP TABLE translation_units")
    op.execute("ALTER TABLE content_sentences DROP COLUMN render_json")
    op.execute("ALTER TABLE content_blocks DROP COLUMN payload_json")


def _expand_sentence_units(connection: Any) -> None:
    """Best-effort downgrade: flatten sentence-unit payloads to rows.

    An edited value is only written when it differs from the generated value —
    the merged edited payload cannot distinguish "edited to the same text"
    from "never edited", which is one more reason downgrade is unsupported.
    """
    rows = connection.execute(
        text(
            """
            SELECT job_id, unit_id, generated_payload, edited_payload, adapter_name
            FROM translation_units WHERE unit_kind = 'sentence'
            """
        )
    ).fetchall()
    for row in rows:
        generated = json.loads(row.generated_payload)
        edited = json.loads(row.edited_payload) if row.edited_payload else {}
        edited_texts = {
            str(entry["sentence_id"]): str(entry["text_zh"])
            for entry in edited.get("translations", [])
        }
        for entry in generated.get("translations", []):
            sentence_id = str(entry["sentence_id"])
            generated_text = str(entry["text_zh"])
            edited_text = edited_texts.get(sentence_id)
            if edited_text == generated_text:
                edited_text = None
            connection.execute(
                text(
                    """
                    INSERT INTO translations (
                        job_id, sentence_id, generated_text, edited_text, adapter_name
                    ) VALUES (:job_id, :sentence_id, :generated_text,
                              :edited_text, :adapter_name)
                    """
                ),
                {
                    "job_id": row.job_id,
                    "sentence_id": sentence_id,
                    "generated_text": generated_text,
                    "edited_text": edited_text,
                    "adapter_name": row.adapter_name,
                },
            )

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

from engirdle_pc.shared.infrastructure.database.connection import Database
from engirdle_pc.shared.infrastructure.database.migrations_runner import (
    _SCRIPT_LOCATION,
)

EXPECTED_TABLES = {
    "alembic_version",
    "articles",
    "article_revisions",
    "content_blocks",
    "content_sentences",
    "build_jobs",
    "translation_units",
    "sentence_audio",
    "audio_timeline",
    "audio_outputs",
    "package_artifacts",
    "published_articles",
    "system_metadata",
    "voice_anchor_batches",
    "voice_anchor_candidates",
    "voice_profiles",
}

HEAD_REVISION = "0004_markdown_blocks"
PRE_MARKDOWN_REVISION = "0003_catalog_version_floor"


def _tables(connection: sqlite3.Connection) -> set[str]:
    return {
        row["name"]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }


def _columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {row["name"] for row in connection.execute(f"PRAGMA table_info({table})").fetchall()}


def _alembic_config(engine: object) -> Config:
    config = Config()
    config.set_main_option("script_location", str(_SCRIPT_LOCATION))
    config.attributes["connection"] = engine
    return config


def test_database_applies_migrations_idempotently(tmp_path: Path) -> None:
    database = Database(tmp_path / "app.db")

    database.initialize()
    database.initialize()  # second run must be a no-op (alembic upgrade head)

    with database.connect() as connection:
        assert _tables(connection) == EXPECTED_TABLES

        versions = [
            row["version_num"]
            for row in connection.execute("SELECT version_num FROM alembic_version").fetchall()
        ]
        assert versions == [HEAD_REVISION]
        assert (
            connection.execute(
                "SELECT value FROM system_metadata WHERE key = 'catalog_version'"
            ).fetchone()["value"]
            == "1"
        )

        # Preserve the original schema contract: the published_articles and
        # package_artifacts column sets must be unchanged after the Alembic
        # takeover. This is the safety net for the hand-transcribed baseline.
        assert _columns(connection, "published_articles") == {
            "article_id",
            "package_id",
            "revision",
            "artifact_revision",
            "title",
            "opaque_name",
            "size",
            "sha256",
            "published_at",
        }
        assert _columns(connection, "package_artifacts") == {
            "package_id",
            "article_id",
            "revision",
            "artifact_revision",
            "job_id",
            "opaque_name",
            "path",
            "size",
            "sha256",
            "state",
            "created_at",
        }
        # 0004 adds the typed payload/render columns and replaces the legacy
        # sentence-only translations table with the unit-keyed store.
        assert {"payload_json"} <= _columns(connection, "content_blocks")
        assert {"render_json"} <= _columns(connection, "content_sentences")
        assert _columns(connection, "translation_units") == {
            "job_id",
            "unit_id",
            "unit_kind",
            "generated_payload",
            "edited_payload",
            "adapter_name",
        }


def _seed_legacy_database(tmp_path: Path) -> Database:
    """Build a pre-0004 database and populate it with legacy rows via raw SQL."""
    database = Database(tmp_path / "legacy.db")
    command.upgrade(_alembic_config(database.engine), PRE_MARKDOWN_REVISION)
    with database.connect() as connection:
        connection.execute(
            "INSERT INTO articles(article_id, created_at) VALUES ('art-1', '2026-01-01T00:00:00Z')"
        )
        connection.execute(
            """
            INSERT INTO article_revisions(
                article_id, revision, title, raw_text, normalized_text,
                license_name, source_sha256, normalized_sha256, structure_sha256,
                status, created_at
            ) VALUES ('art-1', 1, 'Legacy', 'raw', 'normalized', 'CC-BY-4.0',
                      'src-sha', 'norm-sha', 'struct-sha', 'approved',
                      '2026-01-01T00:00:00Z')
            """
        )
        # Legacy blocks use only paragraph/list_item/quote kinds with no
        # payload_json column content yet (the column is added by 0004).
        for order, (block_id, kind) in enumerate(
            [
                ("block-1", "paragraph"),
                ("block-2", "list_item"),
                ("block-3", "quote"),
            ]
        ):
            connection.execute(
                "INSERT INTO content_blocks(article_id, revision, block_id, kind, block_order)"
                " VALUES ('art-1', 1, ?, ?, ?)",
                (block_id, kind, order),
            )
            connection.execute(
                "INSERT INTO content_sentences(article_id, revision, sentence_id, block_id,"
                " sentence_order, text) VALUES ('art-1', 1, ?, ?, 0, 'legacy text.')",
                (f"{block_id}-s0", block_id),
            )
        # A second sentence in block-1 exercises the multi-sentence-per-block
        # aggregation path (one unit with two ordered entries).
        connection.execute(
            "INSERT INTO content_sentences(article_id, revision, sentence_id, block_id,"
            " sentence_order, text) VALUES ('art-1', 1, 'block-1-s1', 'block-1',"
            " 1, 'second legacy text.')"
        )
        connection.execute(
            """
            INSERT INTO build_jobs(
                job_id, article_id, revision, status, stage, config_json, created_at
            ) VALUES ('job-1', 'art-1', 1, 'running', 'translation', '{}',
                      '2026-01-01T00:00:00Z')
            """
        )
        connection.execute(
            "INSERT INTO translations("
            "job_id, sentence_id, generated_text, edited_text, adapter_name)"
            " VALUES ('job-1', 'block-1-s0', '生成的第一句。', NULL, 'stub')"
        )
        connection.execute(
            "INSERT INTO translations("
            "job_id, sentence_id, generated_text, edited_text, adapter_name)"
            " VALUES ('job-1', 'block-1-s1', '生成的第二句。', NULL, 'stub')"
        )
        connection.execute(
            "INSERT INTO translations("
            "job_id, sentence_id, generated_text, edited_text, adapter_name)"
            " VALUES ('job-1', 'block-2-s0', '生成的第三句。', '人工修正。', 'stub')"
        )
        # An orphan translation: its sentence no longer exists in the frozen
        # structure (re-edited after translation), so it becomes its own unit.
        connection.execute(
            "INSERT INTO translations("
            "job_id, sentence_id, generated_text, edited_text, adapter_name)"
            " VALUES ('job-1', 'block-removed-s0', '孤儿译文。', NULL, 'stub')"
        )
    return database


def test_pre_markdown_database_upgrades_into_translation_units(tmp_path: Path) -> None:
    database = _seed_legacy_database(tmp_path)

    command.upgrade(_alembic_config(database.engine), "head")

    with database.connect() as connection:
        versions = [
            row["version_num"]
            for row in connection.execute("SELECT version_num FROM alembic_version").fetchall()
        ]
        assert versions == [HEAD_REVISION]
        assert "translations" not in _tables(connection)

        rows = connection.execute(
            "SELECT unit_id, unit_kind, generated_payload, edited_payload, adapter_name"
            " FROM translation_units ORDER BY unit_id"
        ).fetchall()
        # Legacy sentence translations are regrouped under their owning block
        # (block-1 aggregates TWO sentences in stored order; block-2 keeps its
        # edited value; the orphan becomes its own unit keyed by sentence id).
        assert [row["unit_kind"] for row in rows] == ["sentence"] * 3
        assert [row["unit_id"] for row in rows] == [
            "block-1",
            "block-2",
            "block-removed-s0",
        ]
        assert json.loads(rows[0]["generated_payload"]) == {
            "translations": [
                {"sentence_id": "block-1-s0", "text_zh": "生成的第一句。"},
                {"sentence_id": "block-1-s1", "text_zh": "生成的第二句。"},
            ]
        }
        assert rows[0]["edited_payload"] is None
        assert json.loads(rows[1]["generated_payload"]) == {
            "translations": [
                {"sentence_id": "block-2-s0", "text_zh": "生成的第三句。"}
            ]
        }
        assert json.loads(rows[1]["edited_payload"]) == {
            "translations": [
                {"sentence_id": "block-2-s0", "text_zh": "人工修正。"}
            ]
        }
        assert json.loads(rows[2]["generated_payload"]) == {
            "translations": [
                {"sentence_id": "block-removed-s0", "text_zh": "孤儿译文。"}
            ]
        }
        assert {row["adapter_name"] for row in rows} == {"stub"}


def test_migrated_sentence_units_round_trip_through_the_repository(
    tmp_path: Path,
) -> None:
    """The converted rows must decode through the NEW store (review/resume)."""
    database = _seed_legacy_database(tmp_path)
    command.upgrade(_alembic_config(database.engine), "head")

    from engirdle_pc.modules.translation.infrastructure.orm import (
        TranslationUnitRecord,
    )
    from engirdle_pc.modules.translation.infrastructure.sqlalchemy_repository import (
        SqlAlchemyTranslationRepository,
    )
    from engirdle_pc.modules.translation.public import UnitKind

    with database.sessions() as session, session.begin():
        assert session.query(TranslationUnitRecord).count() == 3
    store = SqlAlchemyTranslationRepository(database)
    units = store.list_for_job("job-1")
    assert [unit.unit_kind for unit in units] == [UnitKind.SENTENCE] * 3
    by_block = {unit.unit_id: unit for unit in units}
    published_block2 = by_block["block-2"].published
    assert published_block2.translations[0].sentence_id == "block-2-s0"
    assert published_block2.translations[0].text_zh == "人工修正。"
    # A further human edit still lands on the migrated unit.
    store.edit_sentence("job-1", "block-2-s0", " 迁移后再次修正。 ")
    refreshed = {
        unit.unit_id: unit for unit in store.list_for_job("job-1")
    }
    assert (
        refreshed["block-2"].published.translations[0].text_zh
        == "迁移后再次修正。"
    )


def test_dangling_translation_job_aborts_the_migration(tmp_path: Path) -> None:
    """A translation row whose build job vanished must abort, not vanish.

    The declared FK normally prevents this, but a database written with
    enforcement off can carry such rows, so the conversion guard matters:
    the new-table → convert → verify → replace flow must leave the legacy
    table untouched instead of silently dropping rows through the join.
    """
    database = _seed_legacy_database(tmp_path)
    # Bypass the ORM (which enforces FKs) the way a corrupted legacy file
    # would look: a raw connection with enforcement disabled.
    raw = sqlite3.connect(tmp_path / "legacy.db")
    try:
        raw.execute("PRAGMA foreign_keys=OFF")
        raw.execute(
            "INSERT INTO translations("
            "job_id, sentence_id, generated_text, edited_text, adapter_name)"
            " VALUES ('ghost-job', 'block-1-s0', '幽灵译文。', NULL, 'stub')"
        )
        raw.commit()
    finally:
        raw.close()

    with pytest.raises(RuntimeError, match="missing build jobs"):
        command.upgrade(_alembic_config(database.engine), "head")

    # The abort happened in the preflight, BEFORE any DDL: the schema is
    # byte-identical to 0003 (no residual columns, no new table), so an
    # operator can repair the data and simply retry.
    with database.connect() as connection:
        assert "translations" in _tables(connection)
        assert "translation_units" not in _tables(connection)
        assert "payload_json" not in _columns(connection, "content_blocks")
        assert "render_json" not in _columns(connection, "content_sentences")
        versions = [
            row["version_num"]
            for row in connection.execute("SELECT version_num FROM alembic_version")
        ]
        assert versions == [PRE_MARKDOWN_REVISION]

    # Repair the corrupt row, then the retry must reach head and convert.
    raw = sqlite3.connect(tmp_path / "legacy.db")
    try:
        raw.execute("PRAGMA foreign_keys=OFF")
        raw.execute("DELETE FROM translations WHERE job_id = 'ghost-job'")
        raw.commit()
    finally:
        raw.close()
    command.upgrade(_alembic_config(database.engine), "head")
    with database.connect() as connection:
        assert [
            row["version_num"]
            for row in connection.execute("SELECT version_num FROM alembic_version")
        ] == [HEAD_REVISION]
        assert "translations" not in _tables(connection)
        assert "payload_json" in _columns(connection, "content_blocks")
        assert connection.execute(
            "SELECT COUNT(*) FROM translation_units WHERE unit_kind = 'sentence'"
        ).fetchone()[0] == 3


def test_legacy_block_rows_are_backfilled_with_style_payloads(tmp_path: Path) -> None:
    database = _seed_legacy_database(tmp_path)

    command.upgrade(_alembic_config(database.engine), "head")

    with database.connect() as connection:
        payloads = {
            row["block_id"]: row["payload_json"]
            for row in connection.execute(
                "SELECT block_id, payload_json FROM content_blocks ORDER BY block_order"
            ).fetchall()
        }
        assert payloads == {
            "block-1": '{"style":"paragraph"}',
            "block-2": '{"style":"list_item","list_kind":"bullet","list_depth":0}',
            "block-3": '{"style":"quote","quote_depth":1}',
        }
        # The sentence render document backfills to an empty run list so the
        # block codec decodes a legacy row into a plain-run sentence.
        renders = {
            row["render_json"]
            for row in connection.execute("SELECT render_json FROM content_sentences").fetchall()
        }
        assert renders == {"[]"}


def test_migrated_legacy_blocks_decode_through_the_repository(
    tmp_path: Path,
) -> None:
    """A migrated legacy revision loads through the content repository."""
    database = _seed_legacy_database(tmp_path)
    command.upgrade(_alembic_config(database.engine), "head")

    from engirdle_pc.modules.content.infrastructure.sqlalchemy_repository import (
        SqlAlchemyContentRepository,
    )

    revision = SqlAlchemyContentRepository(database).get("art-1", 1)
    list_block = next(
        block for block in revision.blocks if block.kind.value == "list_item"
    )
    assert list_block.list_kind is not None  # required by the typed model
    assert list_block.list_depth == 0
    quote_block = next(
        block for block in revision.blocks if block.kind.value == "quote"
    )
    assert quote_block.quote_depth == 1
    assert [block.kind.value for block in revision.blocks] == [
        "paragraph",
        "list_item",
        "quote",
    ]

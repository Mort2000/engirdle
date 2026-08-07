from pathlib import Path

from engirdle_pc.shared.infrastructure.database.connection import Database


def test_database_applies_ordered_migrations_idempotently(tmp_path: Path) -> None:
    database = Database(tmp_path / "app.db")

    database.initialize()
    database.initialize()

    with database.connect() as connection:
        migrations = tuple(
            row["migration_name"]
            for row in connection.execute(
                "SELECT migration_name FROM schema_migrations ORDER BY migration_name"
            ).fetchall()
        )
        publishing_columns = {
            row["name"]
            for row in connection.execute(
                "PRAGMA table_info(published_articles)"
            ).fetchall()
        }
    assert migrations == (
        "0001_content_initial.sql",
        "0002_production_initial.sql",
        "0003_translation_initial.sql",
        "0004_speech_initial.sql",
        "0005_audio_initial.sql",
        "0006_packaging_initial.sql",
        "0007_publishing_initial.sql",
    )
    assert publishing_columns == {
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

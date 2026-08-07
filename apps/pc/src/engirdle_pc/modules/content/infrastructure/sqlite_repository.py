from __future__ import annotations

import sqlite3

from engirdle_pc.modules.content.domain.entities import (
    ArticleRevision,
    Block,
    BlockKind,
    RevisionStatus,
    Sentence,
    SourceAttribution,
)
from engirdle_pc.modules.content.domain.errors import ContentNotFound, ImmutableRevision
from engirdle_pc.shared.infrastructure.database.connection import Database


class ContentRepository:
    def __init__(self, database: Database) -> None:
        self._database = database

    def insert(self, revision: ArticleRevision, created_at: str) -> None:
        with self._database.connect() as connection:
            connection.execute(
                "INSERT INTO articles(article_id, created_at) VALUES (?, ?)",
                (revision.article_id, created_at),
            )
            self._insert_revision(connection, revision, created_at)

    def insert_revision(self, revision: ArticleRevision, created_at: str) -> None:
        with self._database.connect() as connection:
            exists = connection.execute(
                "SELECT 1 FROM articles WHERE article_id = ?", (revision.article_id,)
            ).fetchone()
            if exists is None:
                raise ContentNotFound(f"article {revision.article_id} not found")
            self._insert_revision(connection, revision, created_at)

    def latest_revision(self, article_id: str) -> ArticleRevision:
        with self._database.connect() as connection:
            row = connection.execute(
                """
                SELECT * FROM article_revisions
                WHERE article_id = ? ORDER BY revision DESC LIMIT 1
                """,
                (article_id,),
            ).fetchone()
            if row is None:
                raise ContentNotFound(f"article {article_id} not found")
            return self._map_revision(connection, row)

    def replace_structure(self, revision: ArticleRevision) -> None:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE article_revisions
                SET structure_sha256 = ?, status = ?
                WHERE article_id = ? AND revision = ? AND status IN ('draft', 'structured')
                """,
                (
                    revision.structure_sha256,
                    RevisionStatus.STRUCTURED.value,
                    revision.article_id,
                    revision.revision,
                ),
            ).rowcount
            if updated != 1:
                raise ContentNotFound("editable article revision not found")
            connection.execute(
                "DELETE FROM content_blocks WHERE article_id = ? AND revision = ?",
                (revision.article_id, revision.revision),
            )
            self._insert_blocks(connection, revision)

    def approve(self, article_id: str, revision: int, approved_at: str) -> None:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE article_revisions
                SET status = ?, approved_at = ?
                WHERE article_id = ? AND revision = ? AND status = ?
                """,
                (
                    RevisionStatus.APPROVED.value,
                    approved_at,
                    article_id,
                    revision,
                    RevisionStatus.STRUCTURED.value,
                ),
            ).rowcount
            if updated != 1:
                raise ContentNotFound("structured article revision not found")

    def mark_published(self, article_id: str, revision: int, published_at: str) -> None:
        with self._database.connect() as connection:
            updated = connection.execute(
                """
                UPDATE article_revisions
                SET status = ?, published_at = COALESCE(published_at, ?)
                WHERE article_id = ? AND revision = ?
                    AND status IN (?, ?)
                """,
                (
                    RevisionStatus.PUBLISHED.value,
                    published_at,
                    article_id,
                    revision,
                    RevisionStatus.APPROVED.value,
                    RevisionStatus.PUBLISHED.value,
                ),
            ).rowcount
            if updated != 1:
                raise ImmutableRevision(
                    "only an approved or already-published revision can be published"
                )

    def get(self, article_id: str, revision: int) -> ArticleRevision:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT * FROM article_revisions WHERE article_id = ? AND revision = ?",
                (article_id, revision),
            ).fetchone()
            if row is None:
                raise ContentNotFound(f"article revision {article_id}@{revision} not found")
            return self._map_revision(connection, row)

    def list_latest(self) -> tuple[ArticleRevision, ...]:
        with self._database.connect() as connection:
            rows = connection.execute(
                """
                SELECT revisions.*
                FROM article_revisions AS revisions
                JOIN (
                    SELECT article_id, MAX(revision) AS revision
                    FROM article_revisions GROUP BY article_id
                ) AS latest USING(article_id, revision)
                ORDER BY revisions.created_at DESC
                """
            ).fetchall()
            return tuple(self._map_revision(connection, row) for row in rows)

    def delete_article(self, article_id: str) -> None:
        with self._database.connect() as connection:
            exists = connection.execute(
                "SELECT 1 FROM articles WHERE article_id = ?", (article_id,)
            ).fetchone()
            if exists is None:
                raise ContentNotFound(f"article {article_id} not found")
            connection.execute(
                "DELETE FROM article_revisions WHERE article_id = ?", (article_id,)
            )
            deleted = connection.execute(
                "DELETE FROM articles WHERE article_id = ?", (article_id,)
            ).rowcount
            if deleted != 1:
                raise ContentNotFound(f"article {article_id} not found")

    def _insert_revision(
        self, connection: sqlite3.Connection, revision: ArticleRevision, created_at: str
    ) -> None:
        connection.execute(
            """
            INSERT INTO article_revisions(
                article_id, revision, title, raw_text, normalized_text, author,
                source_name, source_url, license_name, source_sha256,
                normalized_sha256, structure_sha256, status, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                revision.article_id,
                revision.revision,
                revision.title,
                revision.raw_text,
                revision.normalized_text,
                revision.source.author,
                revision.source.display_name,
                revision.source.url,
                revision.source.license_name,
                revision.source_sha256,
                revision.normalized_sha256,
                revision.structure_sha256,
                revision.status.value,
                created_at,
            ),
        )
        self._insert_blocks(connection, revision)

    @staticmethod
    def _insert_blocks(connection: sqlite3.Connection, revision: ArticleRevision) -> None:
        for block in revision.blocks:
            connection.execute(
                """
                INSERT INTO content_blocks(article_id, revision, block_id, kind, block_order)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    revision.article_id,
                    revision.revision,
                    block.block_id,
                    block.kind.value,
                    block.order,
                ),
            )
            connection.executemany(
                """
                INSERT INTO content_sentences(
                    article_id, revision, block_id, sentence_id, sentence_order, text
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        revision.article_id,
                        revision.revision,
                        block.block_id,
                        sentence.sentence_id,
                        sentence.order,
                        sentence.text,
                    )
                    for sentence in block.sentences
                ],
            )

    @staticmethod
    def _map_revision(
        connection: sqlite3.Connection, row: sqlite3.Row
    ) -> ArticleRevision:
        block_rows = connection.execute(
            """
            SELECT * FROM content_blocks
            WHERE article_id = ? AND revision = ? ORDER BY block_order
            """,
            (row["article_id"], row["revision"]),
        ).fetchall()
        blocks: list[Block] = []
        for block_row in block_rows:
            sentence_rows = connection.execute(
                """
                SELECT * FROM content_sentences
                WHERE article_id = ? AND revision = ? AND block_id = ?
                ORDER BY sentence_order
                """,
                (row["article_id"], row["revision"], block_row["block_id"]),
            ).fetchall()
            blocks.append(
                Block(
                    block_id=block_row["block_id"],
                    kind=BlockKind(block_row["kind"]),
                    order=block_row["block_order"],
                    sentences=tuple(
                        Sentence(
                            sentence_id=sentence_row["sentence_id"],
                            order=sentence_row["sentence_order"],
                            text=sentence_row["text"],
                        )
                        for sentence_row in sentence_rows
                    ),
                )
            )
        return ArticleRevision(
            article_id=row["article_id"],
            revision=row["revision"],
            title=row["title"],
            raw_text=row["raw_text"],
            normalized_text=row["normalized_text"],
            source=SourceAttribution(
                author=row["author"],
                display_name=row["source_name"],
                url=row["source_url"],
                license_name=row["license_name"],
            ),
            source_sha256=row["source_sha256"],
            normalized_sha256=row["normalized_sha256"],
            structure_sha256=row["structure_sha256"],
            status=RevisionStatus(row["status"]),
            blocks=tuple(blocks),
        )

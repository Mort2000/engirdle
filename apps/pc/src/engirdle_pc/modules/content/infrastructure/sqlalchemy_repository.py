from __future__ import annotations

from typing import Any, cast

from sqlalchemy import and_, delete, func, select, update
from sqlalchemy.engine import CursorResult
from sqlalchemy.orm import Session

from engirdle_pc.modules.content.domain.entities import (
    ArticleRevision,
    Block,
    RevisionStatus,
    Sentence,
    SourceAttribution,
    TextBlock,
)
from engirdle_pc.modules.content.domain.errors import ContentNotFound, ImmutableRevision
from engirdle_pc.modules.content.infrastructure.block_codec import (
    block_from_row,
    block_payload,
    runs_from_render,
    sentence_render,
)
from engirdle_pc.modules.content.infrastructure.orm import (
    ArticleRecord,
    ArticleRevisionRecord,
    ContentBlockRecord,
    ContentSentenceRecord,
)
from engirdle_pc.shared.infrastructure.database.connection import Database


class SqlAlchemyContentRepository:
    """SQLAlchemy 2.0 implementation of the ``ContentStore`` protocol."""

    def __init__(self, database: Database) -> None:
        self._database = database

    def insert(self, revision: ArticleRevision, created_at: str) -> None:
        with self._database.sessions() as session, session.begin():
            session.add(ArticleRecord(article_id=revision.article_id, created_at=created_at))
            _insert_revision(session, revision, created_at)

    def insert_revision(self, revision: ArticleRevision, created_at: str) -> None:
        with self._database.sessions() as session, session.begin():
            exists = session.scalar(
                select(ArticleRecord.article_id).where(
                    ArticleRecord.article_id == revision.article_id
                )
            )
            if exists is None:
                raise ContentNotFound(f"article {revision.article_id} not found")
            _insert_revision(session, revision, created_at)

    def latest_revision(self, article_id: str) -> ArticleRevision:
        with self._database.sessions() as session, session.begin():
            record = session.scalars(
                select(ArticleRevisionRecord)
                .where(ArticleRevisionRecord.article_id == article_id)
                .order_by(ArticleRevisionRecord.revision.desc())
                .limit(1)
            ).first()
            if record is None:
                raise ContentNotFound(f"article {article_id} not found")
            return _map_revision(session, record)

    def replace_structure(self, revision: ArticleRevision) -> None:
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(ArticleRevisionRecord)
                    .where(
                        ArticleRevisionRecord.article_id == revision.article_id,
                        ArticleRevisionRecord.revision == revision.revision,
                        ArticleRevisionRecord.status.in_(
                            [RevisionStatus.DRAFT.value, RevisionStatus.STRUCTURED.value]
                        ),
                    )
                    .values(
                        structure_sha256=revision.structure_sha256,
                        status=RevisionStatus.STRUCTURED.value,
                    )
                ),
            ).rowcount
            if updated != 1:
                raise ContentNotFound("editable article revision not found")
            session.execute(
                delete(ContentBlockRecord).where(
                    ContentBlockRecord.article_id == revision.article_id,
                    ContentBlockRecord.revision == revision.revision,
                )
            )
            _insert_blocks(session, revision)

    def approve(self, article_id: str, revision: int, approved_at: str) -> None:
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(ArticleRevisionRecord)
                    .where(
                        ArticleRevisionRecord.article_id == article_id,
                        ArticleRevisionRecord.revision == revision,
                        ArticleRevisionRecord.status == RevisionStatus.STRUCTURED.value,
                    )
                    .values(
                        status=RevisionStatus.APPROVED.value,
                        approved_at=approved_at,
                    )
                ),
            ).rowcount
            if updated != 1:
                raise ContentNotFound("structured article revision not found")

    def mark_published(self, article_id: str, revision: int, published_at: str) -> None:
        with self._database.sessions() as session, session.begin():
            updated = cast(
                "CursorResult[Any]",
                session.execute(
                    update(ArticleRevisionRecord)
                    .where(
                        ArticleRevisionRecord.article_id == article_id,
                        ArticleRevisionRecord.revision == revision,
                        ArticleRevisionRecord.status.in_(
                            [
                                RevisionStatus.APPROVED.value,
                                RevisionStatus.PUBLISHED.value,
                            ]
                        ),
                    )
                    .values(
                        status=RevisionStatus.PUBLISHED.value,
                        published_at=func.coalesce(
                            ArticleRevisionRecord.published_at, published_at
                        ),
                    )
                ),
            ).rowcount
            if updated != 1:
                raise ImmutableRevision(
                    "only an approved or already-published revision can be published"
                )

    def get(self, article_id: str, revision: int) -> ArticleRevision:
        with self._database.sessions() as session, session.begin():
            record = session.get(ArticleRevisionRecord, (article_id, revision))
            if record is None:
                raise ContentNotFound(
                    f"article revision {article_id}@{revision} not found"
                )
            return _map_revision(session, record)

    def list_latest(self) -> tuple[ArticleRevision, ...]:
        with self._database.sessions() as session, session.begin():
            latest = (
                select(
                    ArticleRevisionRecord.article_id,
                    func.max(ArticleRevisionRecord.revision).label("revision"),
                )
                .group_by(ArticleRevisionRecord.article_id)
                .subquery()
            )
            records = session.scalars(
                select(ArticleRevisionRecord)
                .join(
                    latest,
                    and_(
                        ArticleRevisionRecord.article_id == latest.c.article_id,
                        ArticleRevisionRecord.revision == latest.c.revision,
                    ),
                )
                .order_by(ArticleRevisionRecord.created_at.desc())
            )
            return tuple(_map_revision(session, record) for record in records)

    def delete_article(self, article_id: str) -> None:
        with self._database.sessions() as session, session.begin():
            exists = session.scalar(
                select(ArticleRecord.article_id).where(
                    ArticleRecord.article_id == article_id
                )
            )
            if exists is None:
                raise ContentNotFound(f"article {article_id} not found")
            session.execute(
                delete(ArticleRevisionRecord).where(
                    ArticleRevisionRecord.article_id == article_id
                )
            )
            deleted = cast(
                "CursorResult[Any]",
                session.execute(
                    delete(ArticleRecord).where(ArticleRecord.article_id == article_id)
                ),
            ).rowcount
            if deleted != 1:
                raise ContentNotFound(f"article {article_id} not found")


def _insert_revision(
    session: Session, revision: ArticleRevision, created_at: str
) -> None:
    session.add(
        ArticleRevisionRecord(
            article_id=revision.article_id,
            revision=revision.revision,
            title=revision.title,
            raw_text=revision.raw_text,
            normalized_text=revision.normalized_text,
            author=revision.source.author,
            source_name=revision.source.display_name,
            source_url=revision.source.url,
            license_name=revision.source.license_name,
            source_sha256=revision.source_sha256,
            normalized_sha256=revision.normalized_sha256,
            structure_sha256=revision.structure_sha256,
            status=revision.status.value,
            created_at=created_at,
        )
    )
    _insert_blocks(session, revision)


def _insert_blocks(session: Session, revision: ArticleRevision) -> None:
    for block in revision.blocks:
        session.add(
            ContentBlockRecord(
                article_id=revision.article_id,
                revision=revision.revision,
                block_id=block.block_id,
                kind=block.kind.value,
                block_order=block.order,
                payload_json=block_payload(block),
            )
        )
        if isinstance(block, TextBlock):
            session.add_all(
                [
                    ContentSentenceRecord(
                        article_id=revision.article_id,
                        revision=revision.revision,
                        block_id=block.block_id,
                        sentence_id=sentence.sentence_id,
                        sentence_order=sentence.order,
                        text=sentence.text,
                        render_json=sentence_render(sentence),
                    )
                    for sentence in block.sentences
                ]
            )


def _map_revision(
    session: Session, record: ArticleRevisionRecord
) -> ArticleRevision:
    block_records = session.scalars(
        select(ContentBlockRecord)
        .where(
            ContentBlockRecord.article_id == record.article_id,
            ContentBlockRecord.revision == record.revision,
        )
        .order_by(ContentBlockRecord.block_order)
    )
    blocks: list[Block] = []
    for block_record in block_records:
        sentence_records = session.scalars(
            select(ContentSentenceRecord)
            .where(
                ContentSentenceRecord.article_id == record.article_id,
                ContentSentenceRecord.revision == record.revision,
                ContentSentenceRecord.block_id == block_record.block_id,
            )
            .order_by(ContentSentenceRecord.sentence_order)
        )
        sentences = [
            Sentence(
                sentence_id=sentence_record.sentence_id,
                order=sentence_record.sentence_order,
                text=sentence_record.text,
                runs=runs_from_render(sentence_record.render_json),
            )
            for sentence_record in sentence_records
        ]
        blocks.append(
            block_from_row(
                block_record.kind,
                block_record.block_id,
                block_record.block_order,
                block_record.payload_json,
                sentences,
            )
        )
    return ArticleRevision(
        article_id=record.article_id,
        revision=record.revision,
        title=record.title,
        raw_text=record.raw_text,
        normalized_text=record.normalized_text,
        source=SourceAttribution(
            author=record.author,
            display_name=record.source_name,
            url=record.source_url,
            license_name=record.license_name,
        ),
        source_sha256=record.source_sha256,
        normalized_sha256=record.normalized_sha256,
        structure_sha256=record.structure_sha256,
        status=RevisionStatus(record.status),
        blocks=tuple(blocks),
    )

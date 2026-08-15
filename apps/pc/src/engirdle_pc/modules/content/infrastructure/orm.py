from __future__ import annotations

from sqlalchemy import ForeignKey, ForeignKeyConstraint
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.shared.infrastructure.database.base import Base


class ArticleRecord(Base):
    """ORM mapping for the ``articles`` table (read/write mapping only;
    DDL owned by the Alembic baseline)."""

    __tablename__ = "articles"

    article_id: Mapped[str] = mapped_column(primary_key=True)
    created_at: Mapped[str]


class ArticleRevisionRecord(Base):
    """ORM mapping for the ``article_revisions`` table.

    Read/write mapping only; DDL (composite PK) is owned by the Alembic
    baseline. ``SourceAttribution`` fields are denormalized onto this row (see
    the column↔field rename in the repository mapper).
    """

    __tablename__ = "article_revisions"

    article_id: Mapped[str] = mapped_column(ForeignKey("articles.article_id"), primary_key=True)
    revision: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str]
    raw_text: Mapped[str]
    normalized_text: Mapped[str]
    author: Mapped[str | None]
    source_name: Mapped[str | None]
    source_url: Mapped[str | None]
    license_name: Mapped[str]
    source_sha256: Mapped[str]
    normalized_sha256: Mapped[str]
    structure_sha256: Mapped[str]
    status: Mapped[str]
    created_at: Mapped[str]
    approved_at: Mapped[str | None]
    published_at: Mapped[str | None]


class ContentBlockRecord(Base):
    """ORM mapping for the ``content_blocks`` table (read/write mapping only;
    composite PK + composite FK to ``article_revisions`` owned by Alembic).

    The composite FK is declared WITHOUT ``ondelete`` to match SQLAlchemy's
    SQLite reflection (which drops ``ON DELETE`` for composite FKs); the real
    ``ON DELETE CASCADE`` lives in the Alembic baseline, which is DDL authority.
    """

    __tablename__ = "content_blocks"
    __table_args__ = (
        ForeignKeyConstraint(
            ["article_id", "revision"],
            ["article_revisions.article_id", "article_revisions.revision"],
        ),
    )

    article_id: Mapped[str] = mapped_column(primary_key=True)
    revision: Mapped[int] = mapped_column(primary_key=True)
    block_id: Mapped[str] = mapped_column(primary_key=True)
    kind: Mapped[str]
    block_order: Mapped[int]
    payload_json: Mapped[str] = mapped_column(default="{}")


class ContentSentenceRecord(Base):
    """ORM mapping for the ``content_sentences`` table (composite FK to
    ``content_blocks`` declared without ``ondelete``; see note above)."""

    __tablename__ = "content_sentences"
    __table_args__ = (
        ForeignKeyConstraint(
            ["article_id", "revision", "block_id"],
            ["content_blocks.article_id", "content_blocks.revision", "content_blocks.block_id"],
        ),
    )

    article_id: Mapped[str] = mapped_column(primary_key=True)
    revision: Mapped[int] = mapped_column(primary_key=True)
    sentence_id: Mapped[str] = mapped_column(primary_key=True)
    block_id: Mapped[str]
    sentence_order: Mapped[int]
    text: Mapped[str]
    render_json: Mapped[str] = mapped_column(default="[]")

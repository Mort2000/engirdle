from __future__ import annotations

from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.modules.publishing.domain.models import PublishedPackage
from engirdle_pc.shared.infrastructure.database.base import Base


class PublishedArticleRecord(Base):
    """ORM mapping for the ``published_articles`` table (read/write mapping
    only; DDL/PK/UNIQUE owned by the Alembic baseline)."""

    __tablename__ = "published_articles"

    article_id: Mapped[str] = mapped_column(primary_key=True)
    package_id: Mapped[str]
    revision: Mapped[int]
    artifact_revision: Mapped[int]
    title: Mapped[str]
    opaque_name: Mapped[str] = mapped_column(unique=True)
    size: Mapped[int]
    sha256: Mapped[str]
    published_at: Mapped[str]

    def to_dataclass(self) -> PublishedPackage:
        return PublishedPackage(
            package_id=self.package_id,
            article_id=self.article_id,
            revision=self.revision,
            artifact_revision=self.artifact_revision,
            title=self.title,
            opaque_name=self.opaque_name,
            size=self.size,
            sha256=self.sha256,
            published_at=self.published_at,
        )


class SystemMetadataRecord(Base):
    """ORM mapping for the ``system_metadata`` table (key/value store; the
    ``catalog_version`` row is seeded by the Alembic baseline)."""

    __tablename__ = "system_metadata"

    key: Mapped[str] = mapped_column(primary_key=True)
    value: Mapped[str]

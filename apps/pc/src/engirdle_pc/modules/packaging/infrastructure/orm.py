from __future__ import annotations

from pathlib import Path

from sqlalchemy import ForeignKey, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from engirdle_pc.modules.packaging.application.models import PackageArtifact
from engirdle_pc.shared.infrastructure.database.base import Base


class PackageArtifactRecord(Base):
    """ORM mapping for the ``package_artifacts`` table.

    Persistence shape only — the application layer exchanges the frozen
    :class:`PackageArtifact` dataclass, converted via :meth:`to_dataclass` /
    :meth:`from_dataclass`. The ``path`` column is TEXT; the ``Path`` wrapping
    happens at the dataclass boundary, not in the column type. Remaining DDL
    details (PK, UNIQUE constraints, ``ON DELETE`` behaviour) are owned by the
    Alembic baseline.
    """

    __tablename__ = "package_artifacts"
    __table_args__ = (
        UniqueConstraint("article_id", "revision", "artifact_revision"),
    )

    package_id: Mapped[str] = mapped_column(primary_key=True)
    article_id: Mapped[str]
    revision: Mapped[int]
    artifact_revision: Mapped[int]
    job_id: Mapped[str] = mapped_column(ForeignKey("build_jobs.job_id"))
    opaque_name: Mapped[str] = mapped_column(unique=True)
    path: Mapped[str]
    size: Mapped[int]
    sha256: Mapped[str]
    state: Mapped[str]
    created_at: Mapped[str]

    def to_dataclass(self) -> PackageArtifact:
        return PackageArtifact(
            package_id=self.package_id,
            article_id=self.article_id,
            revision=self.revision,
            artifact_revision=self.artifact_revision,
            job_id=self.job_id,
            opaque_name=self.opaque_name,
            path=Path(self.path),
            size=self.size,
            sha256=self.sha256,
            state=self.state,
            created_at=self.created_at,
        )

    @staticmethod
    def from_dataclass(artifact: PackageArtifact) -> PackageArtifactRecord:
        return PackageArtifactRecord(
            package_id=artifact.package_id,
            article_id=artifact.article_id,
            revision=artifact.revision,
            artifact_revision=artifact.artifact_revision,
            job_id=artifact.job_id,
            opaque_name=artifact.opaque_name,
            path=str(artifact.path),
            size=artifact.size,
            sha256=artifact.sha256,
            state=artifact.state,
            created_at=artifact.created_at,
        )

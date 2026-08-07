from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

from engirdle_pc.modules.content.public import ContentService
from engirdle_pc.modules.packaging.public import (
    ArtifactRepository,
    PackageArtifact,
    PackagingService,
)
from engirdle_pc.modules.production.public import (
    JobRepository,
    JobStatus,
    ProductionStage,
)
from engirdle_pc.modules.publishing.application.validator import CatalogValidator
from engirdle_pc.modules.publishing.domain.models import Catalog, CatalogItem
from engirdle_pc.modules.publishing.infrastructure.sqlite_repository import PublishingRepository
from engirdle_pc.shared.domain.time import isoformat_utc
from engirdle_pc.shared.infrastructure.workspace import Workspace


class PublishingService:
    def __init__(
        self,
        repository: PublishingRepository,
        workspace: Workspace,
        content: ContentService,
        jobs: JobRepository,
        validator: CatalogValidator,
    ) -> None:
        self._repository = repository
        self._workspace = workspace
        self._content = content
        self._jobs = jobs
        self._validator = validator

    def publish(self, artifact: PackageArtifact) -> None:
        destination = self._workspace.public_packages_dir / artifact.opaque_name
        temporary = destination.with_suffix(".readpack.tmp")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(artifact.path, temporary)
        os.replace(temporary, destination)
        published_at = isoformat_utc()
        catalog_version = self._repository.publish(artifact, published_at)
        self._write_catalog(catalog_version)
        self._content.mark_published(artifact.article_id, artifact.revision)
        self._jobs.mark_succeeded(artifact.job_id)

    def regenerate_catalog(self) -> Catalog:
        version = max(1, self._repository.catalog_version())
        return self._write_catalog(version)

    def unpublish(self, article_id: str) -> Catalog:
        return self._write_catalog(self._repository.unpublish(article_id))

    def _write_catalog(self, catalog_version: int) -> Catalog:
        catalog = Catalog(
            catalog_version=catalog_version,
            generated_at=isoformat_utc(),
            packages=[
                CatalogItem(
                    article_id=item.article_id,
                    revision=item.revision,
                    artifact_revision=item.artifact_revision,
                    title=item.title,
                    size=item.size,
                    sha256=item.sha256,
                    url=f"/packages/{item.opaque_name}",
                )
                for item in self._repository.list_current()
            ],
        )
        target = self._workspace.public_dir / "catalog.json"
        temporary = self._workspace.public_dir / ".catalog.json.tmp"
        temporary.parent.mkdir(parents=True, exist_ok=True)
        temporary.write_text(
            json.dumps(catalog.model_dump(mode="json"), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        self._validator.validate_file(temporary)
        os.replace(temporary, target)
        return catalog


class ReleaseService:
    def __init__(
        self,
        jobs: JobRepository,
        packaging: PackagingService,
        publishing: PublishingService,
    ) -> None:
        self._jobs = jobs
        self._packaging = packaging
        self._publishing = publishing

    def release(self, job_id: str) -> PackageArtifact:
        job = self._jobs.get(job_id)
        if job.status is not JobStatus.REVIEW_REQUIRED:
            raise ValueError("job must be ready for review before publishing")
        try:
            self._jobs.set_review_stage(job_id, ProductionStage.PACKAGING)
            artifact = self._packaging.build(job)
            self._jobs.set_review_stage(job_id, ProductionStage.PUBLISHING)
            self._publishing.publish(artifact)
            return artifact
        except Exception as error:
            self._jobs.fail(job_id, type(error).__name__, str(error))
            raise


class PublisherQueries:
    """Narrow query facade used by the isolated LAN application."""

    def __init__(self, repository: PublishingRepository, workspace: Workspace) -> None:
        self._repository = repository
        self._workspace = workspace

    @property
    def catalog_path(self) -> Path:
        return self._workspace.public_dir / "catalog.json"

    def resolve_package(self, opaque_name: str) -> Path | None:
        published = self._repository.resolve_published_name(opaque_name)
        if published is None:
            return None
        path = self._workspace.public_packages_dir / published.opaque_name
        if not path.is_file():
            return None
        return path


@dataclass(frozen=True)
class DeletedArticle:
    article_id: str
    trash_path: Path


class LocalLibraryService:
    """Composition-level deletion workflow across module-owned records."""

    def __init__(
        self,
        publishing: PublishingService,
        artifacts: ArtifactRepository,
        jobs: JobRepository,
        content: ContentService,
        workspace: Workspace,
    ) -> None:
        self._publishing = publishing
        self._artifacts = artifacts
        self._jobs = jobs
        self._content = content
        self._workspace = workspace

    def delete_article(self, article_id: str, confirmation: str) -> DeletedArticle:
        if confirmation != article_id:
            raise ValueError("confirmation must exactly match the article ID")
        self._content.latest_revision(article_id)
        artifacts = self._artifacts.list_for_article(article_id)
        job_ids = self._jobs.list_ids_for_article(article_id)
        trash = self._workspace.root / "trash" / f"{article_id}-{uuid4()}"
        trash.mkdir(parents=True, exist_ok=False)

        self._publishing.unpublish(article_id)
        self._artifacts.delete_for_article(article_id)
        self._jobs.delete_for_article(article_id)
        self._content.delete_metadata(article_id)

        _move_if_present(self._workspace.source_dir / article_id, trash / "source")
        _move_if_present(self._workspace.artifacts_dir / article_id, trash / "artifacts")
        for job_id in job_ids:
            _move_if_present(
                self._workspace.job_dir(job_id), trash / "working" / job_id
            )
        for artifact in artifacts:
            _move_if_present(
                self._workspace.public_packages_dir / artifact.opaque_name,
                trash / "public" / "packages" / artifact.opaque_name,
            )
        return DeletedArticle(article_id=article_id, trash_path=trash)


def _move_if_present(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), destination)

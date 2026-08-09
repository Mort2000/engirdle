from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from engirdle_pc.modules.content.public import ContentService
from engirdle_pc.modules.packaging.public import (
    PackageArtifact,
    PackagingService,
)
from engirdle_pc.modules.production.public import (
    JobStatus,
    ProductionService,
    ProductionStage,
)
from engirdle_pc.modules.publishing.application.contracts import Catalog, CatalogItem
from engirdle_pc.modules.publishing.application.ports import (
    PublicationFileStore,
    PublishingStore,
)
from engirdle_pc.modules.publishing.domain.models import PublishedPackage
from engirdle_pc.shared.application.runtime import Clock
from engirdle_pc.shared.domain.time import isoformat_utc


class PublishingService:
    def __init__(
        self,
        repository: PublishingStore,
        files: PublicationFileStore,
        content: ContentService,
        production: ProductionService,
        packaging: PackagingService,
        clock: Clock,
    ) -> None:
        self._repository = repository
        self._files = files
        self._content = content
        self._production = production
        self._packaging = packaging
        self._clock = clock

    def publish(self, artifact: PackageArtifact) -> None:
        self._switch(artifact, finalize_job=True)

    def republish(self, artifact: PackageArtifact) -> None:
        self._switch(artifact, finalize_job=False)

    def list_current(self) -> tuple[PublishedPackage, ...]:
        return self._repository.list_current()

    def _switch(self, artifact: PackageArtifact, *, finalize_job: bool) -> None:
        published_at = isoformat_utc(self._clock.now())
        revision = self._content.get(artifact.article_id, artifact.revision)
        package = PublishedPackage(
            package_id=artifact.package_id,
            article_id=artifact.article_id,
            revision=artifact.revision,
            artifact_revision=artifact.artifact_revision,
            title=revision.title,
            opaque_name=artifact.opaque_name,
            size=artifact.size,
            sha256=artifact.sha256,
            published_at=published_at,
        )
        previous_version = self._repository.catalog_version()
        previous = self._repository.current_for_article(artifact.article_id)
        # A rebuild always mints a fresh opaque name, so the staged file is ours
        # alone; a republish of the same package reuses the name and must not be
        # deleted on failure (it is still the live published file).
        staged_only_by_us = previous is None or previous.opaque_name != artifact.opaque_name
        try:
            self._files.stage_package(artifact)
            if finalize_job:
                self._packaging.mark_published(artifact.package_id)
                self._content.mark_published(artifact.article_id, artifact.revision)
                self._production.mark_succeeded(artifact.job_id)
            # The outward catalog switch is the final step: it only flips once
            # the build has been accepted by every owning module, so a failure
            # here leaves the old release current and the new file unstaged.
            catalog_version = self._repository.publish(package)
            self._prepare_catalog(catalog_version)
            self._commit_catalog()
        except Exception:
            self._files.discard_prepared_catalog()
            self._repository.restore(
                artifact.article_id,
                previous,
                previous_version,
            )
            if staged_only_by_us:
                self._files.unstage_package(artifact.opaque_name)
            raise

    def regenerate_catalog(self, *, content_changed: bool = False) -> Catalog:
        version = (
            self._repository.bump_catalog_version()
            if content_changed
            else max(1, self._repository.catalog_version())
        )
        catalog = self._prepare_catalog(version)
        self._commit_catalog()
        return catalog

    def unpublish(self, article_id: str) -> Catalog:
        catalog = self._prepare_catalog(self._repository.unpublish(article_id))
        self._commit_catalog()
        return catalog

    def _commit_catalog(self) -> None:
        self._files.commit_catalog()
        self._files.cleanup_legacy_dictionary_resources()

    def _prepare_catalog(self, catalog_version: int) -> Catalog:
        catalog = Catalog(
            catalog_version=catalog_version,
            generated_at=isoformat_utc(self._clock.now()),
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
                if self._files.package_exists(item.opaque_name)
            ],
            dictionaries=list(self._files.dictionary_entries()),
        )
        self._files.prepare_catalog(catalog)
        return catalog


class ReleaseService:
    def __init__(
        self,
        production: ProductionService,
        packaging: PackagingService,
        publishing: PublishingService,
    ) -> None:
        self._production = production
        self._packaging = packaging
        self._publishing = publishing

    def release(self, job_id: str) -> PackageArtifact:
        job = self._production.get(job_id)
        if job.status is not JobStatus.REVIEW_REQUIRED:
            raise ValueError("job must be ready for review before publishing")
        try:
            self._production.set_release_stage(job_id, ProductionStage.PACKAGING)
            artifact = self._packaging.build(job)
            self._production.set_release_stage(job_id, ProductionStage.PUBLISHING)
            self._publishing.publish(artifact)
            return artifact
        except Exception as error:
            self._production.fail(job_id, type(error).__name__, str(error))
            raise


@dataclass(frozen=True)
class DeletedArticle:
    article_id: str
    trash_path: Path


class LocalLibraryService:
    """Composition-level deletion workflow across module-owned records."""

    def __init__(
        self,
        publishing: PublishingService,
        packaging: PackagingService,
        production: ProductionService,
        content: ContentService,
        files: PublicationFileStore,
    ) -> None:
        self._publishing = publishing
        self._packaging = packaging
        self._production = production
        self._content = content
        self._files = files

    def delete_article(self, article_id: str, confirmation: str) -> DeletedArticle:
        if confirmation != article_id:
            raise ValueError("confirmation must exactly match the article ID")
        self._content.latest_revision(article_id)
        artifacts = self._packaging.list_for_article(article_id)
        job_ids = self._production.list_ids_for_article(article_id)
        self._publishing.unpublish(article_id)
        self._packaging.delete_for_article(article_id)
        self._production.delete_for_article(article_id)
        self._content.delete_metadata(article_id)
        trash = self._files.trash_article(article_id, job_ids, artifacts)
        return DeletedArticle(article_id=article_id, trash_path=trash)

    def list_artifacts(self, article_ids: tuple[str, ...]) -> tuple[PackageArtifact, ...]:
        return tuple(
            artifact
            for article_id in article_ids
            for artifact in self._packaging.list_for_article(article_id)
        )

    def republish(self, package_id: str) -> PackageArtifact:
        artifact = self._packaging.get_verified(package_id)
        self._publishing.republish(artifact)
        return artifact

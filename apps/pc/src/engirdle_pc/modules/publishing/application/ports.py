from __future__ import annotations

from pathlib import Path
from typing import Protocol

from engirdle_pc.modules.packaging.public import PackageArtifact
from engirdle_pc.modules.publishing.application.contracts import Catalog
from engirdle_pc.modules.publishing.domain.models import PublishedPackage


class PublishingStore(Protocol):
    def publish(self, package: PublishedPackage) -> int: ...

    def restore(
        self,
        article_id: str,
        previous: PublishedPackage | None,
        catalog_version: int,
    ) -> None: ...

    def current_for_article(self, article_id: str) -> PublishedPackage | None: ...

    def catalog_version(self) -> int: ...

    def unpublish(self, article_id: str) -> int: ...

    def list_current(self) -> tuple[PublishedPackage, ...]: ...


class CatalogValidation(Protocol):
    def validate_file(self, path: Path, service_origin: str | None = None) -> None: ...


class PublicationFileStore(Protocol):
    def stage_package(self, artifact: PackageArtifact) -> None: ...

    def unstage_package(self, opaque_name: str) -> None: ...

    def prepare_catalog(self, catalog: Catalog) -> None: ...

    def commit_catalog(self) -> None: ...

    def discard_prepared_catalog(self) -> None: ...

    def package_exists(self, opaque_name: str) -> bool: ...

    def trash_article(
        self,
        article_id: str,
        job_ids: tuple[str, ...],
        artifacts: tuple[PackageArtifact, ...],
    ) -> Path: ...


class PublicationWorkspace(Protocol):
    @property
    def root(self) -> Path: ...

    @property
    def source_dir(self) -> Path: ...

    @property
    def artifacts_dir(self) -> Path: ...

    @property
    def public_dir(self) -> Path: ...

    @property
    def public_packages_dir(self) -> Path: ...

    def job_dir(self, job_id: str) -> Path: ...

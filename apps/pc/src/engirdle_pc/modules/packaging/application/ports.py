from __future__ import annotations

from pathlib import Path
from typing import Protocol

from engirdle_pc.modules.packaging.application.models import (
    InputFileMetadata,
    PackageArtifact,
    PackageContents,
    StoredPackage,
)


class ArtifactStore(Protocol):
    def next_artifact_revision(self, article_id: str, revision: int) -> int: ...

    def insert(self, artifact: PackageArtifact) -> None: ...

    def get(self, package_id: str) -> PackageArtifact: ...

    def list_for_article(self, article_id: str) -> tuple[PackageArtifact, ...]: ...

    def mark_published(self, package_id: str) -> None: ...

    def delete_for_article(self, article_id: str) -> None: ...


class ReadpackValidation(Protocol):
    def validate(self, package_path: Path) -> None: ...


class PackageWriter(Protocol):
    def describe_input(self, path: Path) -> InputFileMetadata: ...

    def verify(self, path: Path) -> InputFileMetadata: ...

    def write(
        self,
        article_id: str,
        revision: int,
        artifact_revision: int,
        opaque_name: str,
        contents: PackageContents,
    ) -> StoredPackage: ...

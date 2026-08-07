from __future__ import annotations

import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile

from engirdle_pc.modules.packaging.application.models import (
    InputFileMetadata,
    PackageContents,
    StoredPackage,
)
from engirdle_pc.modules.packaging.application.ports import ReadpackValidation
from engirdle_pc.shared.infrastructure.hashing import sha256_file
from engirdle_pc.shared.infrastructure.workspace import Workspace


class ZipPackageWriter:
    def __init__(
        self, workspace: Workspace, validator: ReadpackValidation
    ) -> None:
        self._workspace = workspace
        self._validator = validator

    def describe_input(self, path: Path) -> InputFileMetadata:
        return InputFileMetadata(size=path.stat().st_size, sha256=sha256_file(path))

    def verify(self, path: Path) -> InputFileMetadata:
        self._validator.validate(path)
        return self.describe_input(path)

    def write(
        self,
        article_id: str,
        revision: int,
        artifact_revision: int,
        opaque_name: str,
        contents: PackageContents,
    ) -> StoredPackage:
        artifact_dir = self._workspace.artifact_dir(
            article_id, revision, artifact_revision
        )
        artifact_dir.mkdir(parents=True, exist_ok=True)
        final_path = artifact_dir / opaque_name
        temporary_path = artifact_dir / f".{opaque_name}.tmp"
        with ZipFile(temporary_path, "w") as archive:
            archive.writestr(
                "manifest.json", contents.manifest, compress_type=ZIP_DEFLATED
            )
            archive.writestr(
                "article.json", contents.article, compress_type=ZIP_DEFLATED
            )
            archive.writestr(
                "attribution.json",
                contents.attribution,
                compress_type=ZIP_DEFLATED,
            )
            archive.write(
                contents.audio_path,
                "audio/article.m4a",
                compress_type=ZIP_STORED,
            )
        self._validator.validate(temporary_path)
        os.replace(temporary_path, final_path)
        self._validator.validate(final_path)
        return StoredPackage(
            path=final_path,
            size=final_path.stat().st_size,
            sha256=sha256_file(final_path),
        )

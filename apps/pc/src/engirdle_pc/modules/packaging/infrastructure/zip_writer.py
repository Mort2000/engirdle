from __future__ import annotations

import os
import stat
import time
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile, ZipInfo

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
                _regular_file_entry("manifest.json", ZIP_DEFLATED),
                contents.manifest,
            )
            archive.writestr(
                _regular_file_entry("article.json", ZIP_DEFLATED),
                contents.article,
            )
            archive.writestr(
                _regular_file_entry("attribution.json", ZIP_DEFLATED),
                contents.attribution,
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


# A ZIP member advertises its Unix file type in the high 16 bits of the
# central-directory external-attributes field. CPython's ``ZipFile.writestr``
# records only the permission bits (0o600) there, omitting the ``S_IFREG``
# regular-file type bit. The mobile ``SecureZipReader._checkEntryType``
# rejects any entry whose Unix mode is non-zero yet lacks ``S_IFREG``
# ("non-regular file entry rejected"), failing the import at ZIP preflight —
# so every member built from in-memory bytes must carry the type bit, matching
# what ``ZipFile.write`` already records for the audio file.
_REGULAR_FILE_EXTERNAL_ATTR = (stat.S_IFREG | 0o644) << 16


def _regular_file_entry(name: str, compress_type: int) -> ZipInfo:
    info = ZipInfo(name, date_time=time.localtime()[:6])
    info.compress_type = compress_type
    info.external_attr = _REGULAR_FILE_EXTERNAL_ATTR
    return info

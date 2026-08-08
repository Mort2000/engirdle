from __future__ import annotations

import stat
from pathlib import Path
from zipfile import ZipFile

from engirdle_pc.modules.packaging.application.models import PackageContents
from engirdle_pc.modules.packaging.infrastructure.zip_writer import ZipPackageWriter
from engirdle_pc.shared.infrastructure.workspace import Workspace


class _NoOpReadpackValidator:
    """The writer only depends on ``validate(path) -> None``.

    The external-attribute invariant under test is independent of readpack
    content validation (the writer+validator happy path is covered by the
    acceptance suite), so a no-op lets this test target the writer directly.
    """

    def validate(self, package_path: Path) -> None:
        return None


def test_every_zip_member_advertises_a_regular_file_type(tmp_path: Path) -> None:
    # Regression: CPython's ZipFile.writestr wrote the three JSON members with
    # external attributes of 0o600 — permission bits but no S_IFREG file-type
    # bit. The mobile SecureZipReader rejects any entry whose Unix mode is
    # non-zero yet lacks S_IFREG, so the whole package was refused at ZIP
    # preflight ("non-regular file entry rejected") before content validation.
    # Every member the writer emits must therefore carry S_IFREG.
    workspace = Workspace(tmp_path)
    workspace.initialize()
    writer = ZipPackageWriter(workspace, _NoOpReadpackValidator())

    audio_path = tmp_path / "article.m4a"
    audio_path.write_bytes(b"audio-bytes")

    stored = writer.write(
        article_id="art-1",
        revision=1,
        artifact_revision=1,
        opaque_name="pkg-1.readpack",
        contents=PackageContents(
            manifest=b"{}",
            article=b"{}",
            attribution=b"{}",
            audio_path=audio_path,
        ),
    )

    with ZipFile(stored.path) as archive:
        members = archive.infolist()

    assert {member.filename for member in members} == {
        "manifest.json",
        "article.json",
        "attribution.json",
        "audio/article.m4a",
    }
    for member in members:
        unix_mode = member.external_attr >> 16
        # Mirrors SecureZipReader._checkEntryType: the file-type bits (masked
        # by 0xF000) must be S_IFREG. 0o600 fails this (type bits are 0).
        assert stat.S_ISREG(unix_mode), (
            f"{member.filename} lacks the regular-file type bit: {oct(unix_mode)}"
        )

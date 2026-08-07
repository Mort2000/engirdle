from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class PackageArtifact:
    package_id: str
    article_id: str
    revision: int
    artifact_revision: int
    job_id: str
    opaque_name: str
    path: Path
    size: int
    sha256: str
    state: str
    created_at: str


@dataclass(frozen=True)
class InputFileMetadata:
    size: int
    sha256: str


@dataclass(frozen=True)
class PackageContents:
    manifest: bytes
    article: bytes
    attribution: bytes
    audio_path: Path


@dataclass(frozen=True)
class StoredPackage:
    path: Path
    size: int
    sha256: str

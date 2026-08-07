from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PublishedPackage:
    package_id: str
    article_id: str
    revision: int
    artifact_revision: int
    title: str
    opaque_name: str
    size: int
    sha256: str
    published_at: str

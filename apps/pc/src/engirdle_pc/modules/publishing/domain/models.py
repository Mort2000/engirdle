from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from pydantic import BaseModel, ConfigDict


class CatalogItem(BaseModel):
    model_config = ConfigDict(extra="allow")

    article_id: str
    revision: int
    artifact_revision: int
    title: str
    format_version: str = "1.0"
    size: int
    sha256: str
    url: str


class Catalog(BaseModel):
    model_config = ConfigDict(extra="allow")

    catalog_version: int
    generated_at: str
    packages: list[CatalogItem]


@dataclass(frozen=True)
class PublishedPackage:
    package_id: str
    article_id: str
    revision: int
    artifact_revision: int
    title: str
    opaque_name: str
    artifact_path: Path
    size: int
    sha256: str

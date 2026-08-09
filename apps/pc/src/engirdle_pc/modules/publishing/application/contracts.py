from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


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


class CatalogDictionary(BaseModel):
    model_config = ConfigDict(extra="allow")

    dictionary_id: str
    revision: int
    format_version: str = "1.0"
    schema_version: int
    display_name: str
    size: int
    sha256: str
    url: str


class Catalog(BaseModel):
    model_config = ConfigDict(extra="allow")

    catalog_version: int
    generated_at: str
    packages: list[CatalogItem]
    dictionaries: list[CatalogDictionary] = Field(default_factory=list)

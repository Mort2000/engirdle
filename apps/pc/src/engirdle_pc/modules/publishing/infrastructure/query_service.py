from __future__ import annotations

from pathlib import Path
from typing import Protocol

from engirdle_pc.modules.publishing.application.contracts import Catalog


class PublisherWorkspace(Protocol):
    @property
    def public_dir(self) -> Path: ...

    @property
    def public_packages_dir(self) -> Path: ...

    @property
    def public_dictionaries_dir(self) -> Path: ...


class PublisherQueries:
    """Narrow filesystem-only facade used by the isolated LAN application."""

    def __init__(self, workspace: PublisherWorkspace) -> None:
        self._workspace = workspace

    @property
    def catalog_path(self) -> Path:
        return self._workspace.public_dir / "catalog.json"

    def resolve_package(self, opaque_name: str) -> Path | None:
        catalog = self._catalog()
        if catalog is None:
            return None
        expected_url = f"/packages/{opaque_name}"
        if not any(item.url == expected_url for item in catalog.packages):
            return None
        path = self._workspace.public_packages_dir / opaque_name
        return path if path.is_file() else None

    def resolve_dictionary(self, opaque_name: str) -> Path | None:
        catalog = self._catalog()
        if catalog is None:
            return None
        expected_url = f"/dictionaries/{opaque_name}"
        if not any(item.url == expected_url for item in catalog.dictionaries):
            return None
        path = self._workspace.public_dictionaries_dir / opaque_name
        return path if path.is_file() else None

    def _catalog(self) -> Catalog | None:
        if not self.catalog_path.is_file():
            return None
        try:
            return Catalog.model_validate_json(self.catalog_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

from engirdle_pc.modules.packaging.public import PackageArtifact
from engirdle_pc.modules.publishing.application.contracts import Catalog, CatalogDictionary
from engirdle_pc.modules.publishing.application.ports import CatalogValidation
from engirdle_pc.shared.application.runtime import IdentifierGenerator
from engirdle_pc.shared.infrastructure.workspace import Workspace


class LocalPublicationFileStore:
    def __init__(
        self,
        workspace: Workspace,
        validator: CatalogValidation,
        identifiers: IdentifierGenerator,
    ) -> None:
        self._workspace = workspace
        self._validator = validator
        self._identifiers = identifiers

    def stage_package(self, artifact: PackageArtifact) -> None:
        destination = self._workspace.public_packages_dir / artifact.opaque_name
        temporary = destination.with_suffix(".readpack.tmp")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(artifact.path, temporary)
        os.replace(temporary, destination)

    def unstage_package(self, opaque_name: str) -> None:
        # Only ever called for a package this process just staged and that is not
        # the currently published file, so removing it cannot break the old release.
        (self._workspace.public_packages_dir / opaque_name).unlink(missing_ok=True)

    def prepare_catalog(self, catalog: Catalog) -> None:
        temporary = self._workspace.public_dir / ".catalog.json.tmp"
        temporary.parent.mkdir(parents=True, exist_ok=True)
        temporary.write_text(
            json.dumps(catalog.model_dump(mode="json"), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        self._validator.validate_file(temporary)

    def commit_catalog(self) -> None:
        os.replace(
            self._workspace.public_dir / ".catalog.json.tmp",
            self._workspace.public_dir / "catalog.json",
        )

    def discard_prepared_catalog(self) -> None:
        (self._workspace.public_dir / ".catalog.json.tmp").unlink(missing_ok=True)

    def package_exists(self, opaque_name: str) -> bool:
        return (self._workspace.public_packages_dir / opaque_name).is_file()

    def dictionary_entries(self) -> tuple[CatalogDictionary, ...]:
        sidecar = self._workspace.public_dir / "dictionary.json"
        if not sidecar.is_file():
            return ()
        try:
            entry = CatalogDictionary.model_validate_json(sidecar.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return ()
        expected_prefix = "/dictionaries/"
        if not entry.url.startswith(expected_prefix):
            return ()
        name = entry.url.removeprefix(expected_prefix)
        if "/" in name or not (self._workspace.public_dictionaries_dir / name).is_file():
            return ()
        return (entry,)

    def trash_article(
        self,
        article_id: str,
        job_ids: tuple[str, ...],
        artifacts: tuple[PackageArtifact, ...],
    ) -> Path:
        trash = self._workspace.root / "trash" / f"{article_id}-{self._identifiers.new()}"
        trash.mkdir(parents=True, exist_ok=False)
        _move_if_present(self._workspace.source_dir / article_id, trash / "source")
        _move_if_present(self._workspace.artifacts_dir / article_id, trash / "artifacts")
        for job_id in job_ids:
            _move_if_present(self._workspace.job_dir(job_id), trash / "working" / job_id)
        for artifact in artifacts:
            _move_if_present(
                self._workspace.public_packages_dir / artifact.opaque_name,
                trash / "public" / "packages" / artifact.opaque_name,
            )
        return trash


def _move_if_present(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), destination)

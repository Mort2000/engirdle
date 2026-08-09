from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Protocol, cast
from zipfile import ZipFile

from engirdle_pc.modules.dictionary_builder.domain import DictionaryArtifact
from engirdle_pc.modules.publishing.application.contracts import CatalogDictionary


class DictionaryPublicationWorkspace(Protocol):
    @property
    def public_dir(self) -> Path: ...

    @property
    def public_dictionaries_dir(self) -> Path: ...


class DictionaryPublisher:
    """Publishes one immutable formal dictionary and its catalog sidecar."""

    def __init__(self, workspace: DictionaryPublicationWorkspace) -> None:
        self._workspace = workspace

    def publish(self, artifact: DictionaryArtifact) -> CatalogDictionary:
        with ZipFile(artifact.path) as package:
            manifest = cast(
                dict[str, object], json.loads(package.read("manifest.json").decode("utf-8"))
            )
        if (
            manifest.get("dictionary_id") != artifact.dictionary_id
            or manifest.get("revision") != artifact.revision
        ):
            raise ValueError("dictpack manifest does not match the artifact")
        sidecar = self._workspace.public_dir / "dictionary.json"
        if sidecar.is_file():
            current = CatalogDictionary.model_validate_json(sidecar.read_text(encoding="utf-8"))
            if current.dictionary_id == artifact.dictionary_id:
                if artifact.revision < current.revision:
                    raise ValueError("dictionary revision must increase monotonically")
                if artifact.revision == current.revision and (
                    artifact.sha256 != current.sha256 or artifact.size != current.size
                ):
                    raise ValueError("immutable dictionary revision already has different content")
        opaque_name = (
            f"{artifact.dictionary_id}-r{artifact.revision}-{artifact.sha256[:16]}.dictpack"
        )
        destination = self._workspace.public_dictionaries_dir / opaque_name
        temporary = destination.with_suffix(".dictpack.tmp")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(artifact.path, temporary)
        os.replace(temporary, destination)
        entry = CatalogDictionary(
            dictionary_id=artifact.dictionary_id,
            revision=artifact.revision,
            format_version=str(manifest["format_version"]),
            schema_version=int(cast(int, manifest["schema_version"])),
            display_name=str(manifest["display_name"]),
            size=artifact.size,
            sha256=artifact.sha256,
            url=f"/dictionaries/{opaque_name}",
        )
        sidecar_temporary = self._workspace.public_dir / ".dictionary.json.tmp"
        sidecar_temporary.write_text(
            json.dumps(entry.model_dump(mode="json"), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(sidecar_temporary, sidecar)
        return entry

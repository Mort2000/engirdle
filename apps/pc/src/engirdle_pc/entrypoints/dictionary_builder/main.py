from __future__ import annotations

import argparse
import logging
from pathlib import Path

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.dictionary_builder.public import (
    DictionaryBuilder,
    DictionaryBuildRequest,
    DictionaryPublisher,
)
from engirdle_pc.shared.infrastructure.workspace import Workspace


def main() -> None:
    parser = argparse.ArgumentParser(prog="engirdle-dictionary-builder")
    parser.add_argument("--oewn", required=True, type=Path)
    parser.add_argument("--freedict", required=True, type=Path)
    parser.add_argument("--revision", required=True, type=int)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--publish", action="store_true")
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO)

    settings = Settings(workspace=arguments.workspace) if arguments.workspace else Settings()
    output = arguments.output or (
        settings.workspace
        / "artifacts"
        / "dictionaries"
        / "engirdle-en-zh"
        / str(arguments.revision)
        / f"engirdle-en-zh-r{arguments.revision}.dictpack"
    )
    artifact = DictionaryBuilder().build(
        DictionaryBuildRequest(
            oewn_archive=arguments.oewn,
            freedict_archive=arguments.freedict,
            output=output,
            revision=arguments.revision,
            generated_at=arguments.generated_at,
        )
    )
    logging.info(
        "dictionary build complete",
        extra={
            "dictionary_id": artifact.dictionary_id,
            "revision": artifact.revision,
            "size": artifact.size,
            "sha256": artifact.sha256,
        },
    )
    if arguments.publish:
        workspace = Workspace(settings.workspace)
        workspace.initialize()
        entry = DictionaryPublisher(workspace).publish(artifact)
        # Regeneration preserves the dictionary sidecar and atomically exposes
        # it alongside the current article entries.
        from engirdle_pc.bootstrap.container import Container

        Container.build(settings).publishing.regenerate_catalog(content_changed=True)
        logging.info("dictionary published", extra={"url": entry.url})
    print(f"{artifact.path} {artifact.sha256}")


if __name__ == "__main__":
    main()

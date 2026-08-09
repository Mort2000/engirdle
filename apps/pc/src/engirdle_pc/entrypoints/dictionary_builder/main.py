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
    parser.add_argument("--omw-cmn", required=True, type=Path)
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
            omw_cmn_archive=arguments.omw_cmn,
            output=output,
            revision=arguments.revision,
            generated_at=arguments.generated_at,
        )
    )
    for source in artifact.sources:
        logging.info(
            "dictionary source complete: source_id=%s input_sha256=%s "
            "original_headwords=%d filtered_headwords=%d final_headwords=%d",
            source.source_id,
            source.input_sha256,
            source.counts.original_headwords,
            source.counts.filtered_headwords,
            source.counts.final_headwords,
            extra={
                "source_id": source.source_id,
                "input_sha256": source.input_sha256,
                "original_headwords": source.counts.original_headwords,
                "filtered_headwords": source.counts.filtered_headwords,
                "final_headwords": source.counts.final_headwords,
            },
        )
    logging.info(
        "dictionary build complete: dictionary_id=%s revision=%d size=%d sha256=%s",
        artifact.dictionary_id,
        artifact.revision,
        artifact.size,
        artifact.sha256,
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

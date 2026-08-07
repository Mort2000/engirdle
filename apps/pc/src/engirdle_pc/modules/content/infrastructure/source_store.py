from __future__ import annotations

import json

from engirdle_pc.modules.content.domain.entities import ArticleRevision
from engirdle_pc.shared.infrastructure.workspace import Workspace


class FileSourceSnapshotStore:
    def __init__(self, workspace: Workspace) -> None:
        self._workspace = workspace

    def save(self, revision: ArticleRevision) -> None:
        target = self._workspace.source_revision_dir(
            revision.article_id, revision.revision
        )
        target.mkdir(parents=True, exist_ok=True)
        (target / "raw.txt").write_text(revision.raw_text, encoding="utf-8")
        (target / "normalized.txt").write_text(
            revision.normalized_text, encoding="utf-8"
        )
        structure = [
            {
                "block_id": block.block_id,
                "kind": block.kind.value,
                "order": block.order,
                "sentences": [
                    {
                        "sentence_id": sentence.sentence_id,
                        "order": sentence.order,
                        "text": sentence.text,
                    }
                    for sentence in block.sentences
                ],
            }
            for block in revision.blocks
        ]
        (target / "structure.json").write_text(
            json.dumps(structure, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

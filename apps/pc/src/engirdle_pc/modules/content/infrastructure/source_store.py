from __future__ import annotations

import json
import shutil

from engirdle_pc.modules.content.domain.entities import (
    ArticleRevision,
    Block,
    TextBlock,
)
from engirdle_pc.modules.content.infrastructure.block_codec import (
    block_payload,
    sentence_render,
)
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
        structure = [_block_snapshot(block) for block in revision.blocks]
        (target / "structure.json").write_text(
            json.dumps(structure, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def discard(self, article_id: str, revision: int) -> None:
        # Compensating cleanup for a files-first write whose database insert later
        # failed. Only the failed revision's directory is removed; other revisions
        # and the article directory are left untouched.
        target = self._workspace.source_revision_dir(article_id, revision)
        if target.is_dir():
            shutil.rmtree(target)


def _block_snapshot(block: Block) -> dict[str, object]:
    payload = json.loads(block_payload(block))
    snapshot: dict[str, object] = {
        "block_id": block.block_id,
        "kind": block.kind.value,
        "order": block.order,
    }
    snapshot.update(payload)
    if isinstance(block, TextBlock):
        snapshot["sentences"] = [
            {
                "sentence_id": sentence.sentence_id,
                "order": sentence.order,
                "text": sentence.text,
                "render": json.loads(sentence_render(sentence)),
            }
            for sentence in block.sentences
        ]
    else:
        # Table / code / divider blocks carry no sentences.
        snapshot["sentences"] = []
    return snapshot

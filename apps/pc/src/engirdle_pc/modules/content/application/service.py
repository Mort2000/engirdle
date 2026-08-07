from __future__ import annotations

import json
from dataclasses import replace
from uuid import uuid4

from engirdle_pc.modules.content.domain.entities import (
    ArticleRevision,
    EditedBlock,
    NewArticle,
    RevisionStatus,
    SourceAttribution,
)
from engirdle_pc.modules.content.domain.errors import ImmutableRevision, InvalidContent
from engirdle_pc.modules.content.domain.structure import (
    materialize_edited_blocks,
    normalize_text,
    segment_text,
    structure_sha256,
)
from engirdle_pc.modules.content.infrastructure.sqlite_repository import ContentRepository
from engirdle_pc.shared.domain.time import isoformat_utc
from engirdle_pc.shared.infrastructure.hashing import sha256_text
from engirdle_pc.shared.infrastructure.workspace import Workspace


class ContentService:
    def __init__(self, repository: ContentRepository, workspace: Workspace) -> None:
        self._repository = repository
        self._workspace = workspace

    def create(self, command: NewArticle) -> ArticleRevision:
        revision = self._build_revision(str(uuid4()), 1, command)
        created_at = isoformat_utc()
        self._repository.insert(revision, created_at)
        self._save_source_snapshot(revision)
        return revision

    def create_revision(self, article_id: str, command: NewArticle) -> ArticleRevision:
        previous = self._repository.latest_revision(article_id)
        if previous.status in {RevisionStatus.DRAFT, RevisionStatus.STRUCTURED}:
            raise ImmutableRevision("finish the current editable revision before creating another")
        revision = self._build_revision(article_id, previous.revision + 1, command)
        self._repository.insert_revision(revision, isoformat_utc())
        self._save_source_snapshot(revision)
        return revision

    @staticmethod
    def _build_revision(
        article_id: str, revision_number: int, command: NewArticle
    ) -> ArticleRevision:
        title = command.title.strip()
        if not title:
            raise InvalidContent("title must not be empty")
        normalized = normalize_text(command.body)
        blocks = segment_text(normalized)
        return ArticleRevision(
            article_id=article_id,
            revision=revision_number,
            title=title,
            raw_text=command.body,
            normalized_text=normalized,
            source=SourceAttribution(
                author=_optional(command.author),
                display_name=_optional(command.source_name),
                url=_optional(command.source_url),
                license_name=command.license_name.strip() or "unknown",
            ),
            source_sha256=sha256_text(command.body),
            normalized_sha256=sha256_text(normalized),
            structure_sha256=structure_sha256(blocks),
            status=RevisionStatus.STRUCTURED,
            blocks=blocks,
        )

    def edit_structure(
        self, article_id: str, revision_number: int, blocks: tuple[EditedBlock, ...]
    ) -> ArticleRevision:
        current = self._repository.get(article_id, revision_number)
        if current.status not in {RevisionStatus.DRAFT, RevisionStatus.STRUCTURED}:
            raise ImmutableRevision("approved or published revisions cannot be edited")
        materialized = materialize_edited_blocks(blocks)
        updated = replace(
            current,
            blocks=materialized,
            structure_sha256=structure_sha256(materialized),
            status=RevisionStatus.STRUCTURED,
        )
        self._repository.replace_structure(updated)
        self._save_source_snapshot(updated)
        return updated

    def approve(self, article_id: str, revision: int) -> ArticleRevision:
        current = self._repository.get(article_id, revision)
        if current.status is not RevisionStatus.STRUCTURED:
            raise ImmutableRevision("only a structured revision can be approved")
        self._repository.approve(article_id, revision, isoformat_utc())
        return replace(current, status=RevisionStatus.APPROVED)

    def get(self, article_id: str, revision: int) -> ArticleRevision:
        return self._repository.get(article_id, revision)

    def list_latest(self) -> tuple[ArticleRevision, ...]:
        return self._repository.list_latest()

    def latest_revision(self, article_id: str) -> ArticleRevision:
        return self._repository.latest_revision(article_id)

    def mark_published(self, article_id: str, revision: int) -> None:
        self._repository.mark_published(article_id, revision, isoformat_utc())

    def delete_metadata(self, article_id: str) -> None:
        self._repository.delete_article(article_id)

    def _save_source_snapshot(self, revision: ArticleRevision) -> None:
        target = self._workspace.source_revision_dir(revision.article_id, revision.revision)
        target.mkdir(parents=True, exist_ok=True)
        (target / "raw.txt").write_text(revision.raw_text, encoding="utf-8")
        (target / "normalized.txt").write_text(revision.normalized_text, encoding="utf-8")
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
            json.dumps(structure, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )


def _optional(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None

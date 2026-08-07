from __future__ import annotations

from dataclasses import replace

from engirdle_pc.modules.content.application.ports import (
    ContentStore,
    SourceSnapshotStore,
)
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
from engirdle_pc.shared.application.runtime import Clock, IdentifierGenerator
from engirdle_pc.shared.domain.hashing import sha256_text
from engirdle_pc.shared.domain.time import isoformat_utc


class ContentService:
    def __init__(
        self,
        repository: ContentStore,
        source_snapshots: SourceSnapshotStore,
        clock: Clock,
        identifiers: IdentifierGenerator,
    ) -> None:
        self._repository = repository
        self._source_snapshots = source_snapshots
        self._clock = clock
        self._identifiers = identifiers

    def create(self, command: NewArticle) -> ArticleRevision:
        revision = self._build_revision(self._identifiers.new(), 1, command)
        created_at = isoformat_utc(self._clock.now())
        # Write the source snapshot before committing the revision row so a
        # database failure never leaves a revision whose raw/normalized files
        # are missing (PC-ING-002). An orphan directory is benign and cleanable.
        self._source_snapshots.save(revision)
        try:
            self._repository.insert(revision, created_at)
        except BaseException:
            self._source_snapshots.discard(revision.article_id, revision.revision)
            raise
        return revision

    def create_revision(self, article_id: str, command: NewArticle) -> ArticleRevision:
        previous = self._repository.latest_revision(article_id)
        if previous.status in {RevisionStatus.DRAFT, RevisionStatus.STRUCTURED}:
            raise ImmutableRevision("finish the current editable revision before creating another")
        revision = self._build_revision(article_id, previous.revision + 1, command)
        self._source_snapshots.save(revision)
        try:
            self._repository.insert_revision(revision, isoformat_utc(self._clock.now()))
        except BaseException:
            self._source_snapshots.discard(revision.article_id, revision.revision)
            raise
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
        # Persist the new structure snapshot first; if the database write then
        # fails, restore the previous snapshot so disk and database stay aligned.
        self._source_snapshots.save(updated)
        try:
            self._repository.replace_structure(updated)
        except BaseException:
            self._source_snapshots.save(current)
            raise
        return updated

    def approve(self, article_id: str, revision: int) -> ArticleRevision:
        current = self._repository.get(article_id, revision)
        if current.status is not RevisionStatus.STRUCTURED:
            raise ImmutableRevision("only a structured revision can be approved")
        self._repository.approve(
            article_id, revision, isoformat_utc(self._clock.now())
        )
        return replace(current, status=RevisionStatus.APPROVED)

    def get(self, article_id: str, revision: int) -> ArticleRevision:
        return self._repository.get(article_id, revision)

    def list_latest(self) -> tuple[ArticleRevision, ...]:
        return self._repository.list_latest()

    def latest_revision(self, article_id: str) -> ArticleRevision:
        return self._repository.latest_revision(article_id)

    def mark_published(self, article_id: str, revision: int) -> None:
        self._repository.mark_published(
            article_id, revision, isoformat_utc(self._clock.now())
        )

    def delete_metadata(self, article_id: str) -> None:
        self._repository.delete_article(article_id)


def _optional(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None

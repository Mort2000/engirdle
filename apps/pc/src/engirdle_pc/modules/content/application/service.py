from __future__ import annotations

import logging
from dataclasses import dataclass, replace

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
from engirdle_pc.modules.content.domain.errors import (
    ImmutableRevision,
    InvalidContent,
    NoNarratableContent,
)
from engirdle_pc.modules.content.domain.markdown import (
    DEFAULT_LIMITS,
    ParsedMarkdown,
    ParseWarning,
    enforce_document_limits,
    parse_markdown,
)
from engirdle_pc.modules.content.domain.plan import ProcessingPlan
from engirdle_pc.modules.content.domain.structure import (
    SEGMENTER_VERSION,
    materialize_edited_blocks,
    structure_sha256,
)
from engirdle_pc.shared.application.runtime import Clock, IdentifierGenerator
from engirdle_pc.shared.domain.hashing import sha256_text
from engirdle_pc.shared.domain.time import isoformat_utc

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class StructureReport:
    """Structure-confirmation page bundle (design §11.1).

    Named fields instead of a positional tuple so callers (and tests) cannot
    silently swap the warnings and the plan.
    """

    revision: ArticleRevision
    warnings: tuple[ParseWarning, ...]
    plan: ProcessingPlan


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

    @property
    def segmenter_version(self) -> str:
        return SEGMENTER_VERSION

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
        parsed = parse_markdown(command.body, DEFAULT_LIMITS)
        return ArticleRevision(
            article_id=article_id,
            revision=revision_number,
            title=title,
            raw_text=command.body,
            normalized_text=parsed.canonical_markdown,
            source=SourceAttribution(
                author=_optional(command.author),
                display_name=_optional(command.source_name),
                url=_optional(command.source_url),
                license_name=command.license_name.strip() or "unknown",
            ),
            source_sha256=sha256_text(command.body),
            normalized_sha256=sha256_text(parsed.canonical_markdown),
            structure_sha256=structure_sha256(parsed.blocks),
            status=RevisionStatus.STRUCTURED,
            blocks=parsed.blocks,
        )

    def edit_structure(
        self, article_id: str, revision_number: int, blocks: tuple[EditedBlock, ...]
    ) -> ArticleRevision:
        current = self._repository.get(article_id, revision_number)
        if current.status not in {RevisionStatus.DRAFT, RevisionStatus.STRUCTURED}:
            raise ImmutableRevision("approved or published revisions cannot be edited")
        materialized = materialize_edited_blocks(blocks)
        # A manual structure edit can build tables/code the markdown parser
        # never saw, so the frozen resource limits are re-checked over the
        # typed document before the edit is accepted (design §4.4).
        enforce_document_limits(materialized, DEFAULT_LIMITS)
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
        plan = ProcessingPlan.derive(current)
        # Freeze-time limit gate: an editable revision whose stored structure
        # somehow exceeds the frozen limits must not be approved (design §4.4).
        enforce_document_limits(current.blocks, DEFAULT_LIMITS)
        # First release keeps the fixed audio layout: a package always needs at
        # least one narratable sentence (design §1 / §13 no_narratable_content).
        if not plan.narration.units:
            raise NoNarratableContent(
                "the fixed audio layout requires at least one narratable sentence"
            )
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

    def processing_plan(self, article_id: str, revision: int) -> ProcessingPlan:
        """Derive the translation/narration/render projections (design §6)."""
        return ProcessingPlan.derive(self._repository.get(article_id, revision))

    def structure_report(self, article_id: str, revision: int) -> StructureReport:
        """Revision plus re-derived parse warnings and processing plan.

        Parsing is deterministic and the raw snapshot is immutable, so warnings
        are recomputed on demand instead of persisting a second copy of them.
        """
        current = self._repository.get(article_id, revision)
        parsed: ParsedMarkdown | None = None
        try:
            parsed = parse_markdown(current.raw_text, DEFAULT_LIMITS)
        except InvalidContent:
            # A frozen revision whose raw source no longer parses (e.g. edited
            # structure diverged) still reports; warnings simply carry the error.
            parsed = None
        warnings = parsed.warnings if parsed is not None else ()
        return StructureReport(
            revision=current,
            warnings=warnings,
            plan=ProcessingPlan.derive(current),
        )

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

from __future__ import annotations

from collections.abc import AsyncIterator, Sequence
from contextlib import asynccontextmanager
from pathlib import Path as FilePath
from typing import Annotated, Literal

from fastapi import FastAPI, HTTPException, Path, status
from fastapi.staticfiles import StaticFiles
from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field

from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.progress import JobProgress, derive_job_progress
from engirdle_pc.modules.content.public import (
    ArticleRevision,
    CodeBlock,
    ContentNotFound,
    DividerBlock,
    EditedBlock,
    EditedCodeBlock,
    EditedDividerBlock,
    EditedSentence,
    EditedTableBlock,
    EditedTextBlock,
    ImmutableRevision,
    InvalidContent,
    ListKind,
    NewArticle,
    ProcessingPlan,
    TableAlignment,
    TableBlock,
    TableCell,
    TextBlock,
    TextBlockStyle,
    UnsupportedMarkdown,
)
from engirdle_pc.modules.packaging.public import PackageArtifact
from engirdle_pc.modules.production.public import (
    BuildJob,
    InvalidJobState,
    JobNotFound,
    ProductionCheckpoint,
)
from engirdle_pc.modules.publishing.public import PublishedPackage
from engirdle_pc.modules.speech.public import (
    AnchorBatch,
    InvalidAnchorRequest,
    SpeechConfigurationError,
    SpeechGenerationError,
    VoiceCandidateNotFound,
    VoiceIntegrityError,
    VoiceProfile,
    VoiceProfileNotConfigured,
)
from engirdle_pc.modules.translation.public import (
    InvalidTranslationEdit,
    SentenceUnitTranslation,
    TableShapeMismatch,
    TableTranslatedCell,
    TableUnitTranslation,
)


class RequestModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateArticleRequest(RequestModel):
    title: str = Field(min_length=1, max_length=512)
    body: str = Field(min_length=1)
    author: str | None = Field(default=None, max_length=512)
    source_name: str | None = Field(default=None, max_length=512)
    source_url: AnyHttpUrl | None = None
    license_name: str = Field(default="unknown", min_length=1, max_length=512)


class EditSentenceRequest(RequestModel):
    sentence_id: str | None = None
    text: str = Field(min_length=1, max_length=20_000)


class _EditTextBlockBase(RequestModel):
    """Shared text-kind fields: identity plus the sentence list."""

    block_id: str | None = Field(default=None, min_length=1, max_length=128)
    sentences: list[EditSentenceRequest] = Field(min_length=1)


class EditParagraphBlockRequest(_EditTextBlockBase):
    """Paragraph edit: sentences only — no kind-specific style payload."""

    kind: Literal["paragraph"]


class EditHeadingBlockRequest(_EditTextBlockBase):
    """Heading edit: a required 1-6 level."""

    kind: Literal["heading"]
    level: int = Field(ge=1, le=6)


class EditListItemBlockRequest(_EditTextBlockBase):
    """List-item edit: a required list kind plus depth/ordinal."""

    kind: Literal["list_item"]
    list_kind: ListKind
    list_depth: int = Field(default=0, ge=0, le=4)
    list_ordinal: int | None = Field(default=None, ge=0, le=2_147_483_647)


class EditQuoteBlockRequest(_EditTextBlockBase):
    """Quote edit: an optional depth (single level by default)."""

    kind: Literal["quote"]
    quote_depth: int = Field(default=1, ge=1, le=4)


class EditTableBlockRequest(RequestModel):
    """Table structure edit: alignments plus the plain-text grid."""

    kind: Literal["table"]
    block_id: str | None = Field(default=None, min_length=1, max_length=128)
    alignments: list[TableAlignment] = Field(min_length=1)
    header: list[str] = Field(min_length=1)
    rows: list[list[str]] = Field(default_factory=list)


class EditCodeBlockRequest(RequestModel):
    """Code structure edit: a non-empty body plus optional language."""

    kind: Literal["code"]
    block_id: str | None = Field(default=None, min_length=1, max_length=128)
    language: str | None = Field(default=None, min_length=1, max_length=64)
    code: str = Field(min_length=1)


class EditDividerBlockRequest(RequestModel):
    """Divider structure edit: nothing beyond identity."""

    kind: Literal["divider"]
    block_id: str | None = Field(default=None, min_length=1, max_length=128)


# The discriminated structure-edit request (design §11.2): 'kind' selects the
# legal payload and `extra="forbid"` rejects any field the kind does not
# carry, so a payload cannot silently drop mistyped fields on the floor (and
# required kind payloads — heading level, list kind — fail as 422 here
# rather than as a domain error later).
EditedBlockRequest = Annotated[
    EditParagraphBlockRequest
    | EditHeadingBlockRequest
    | EditListItemBlockRequest
    | EditQuoteBlockRequest
    | EditTableBlockRequest
    | EditCodeBlockRequest
    | EditDividerBlockRequest,
    Field(discriminator="kind"),
]


class EditTableTranslationRequest(RequestModel):
    """Whole-table manual correction (design §8.4: save a complete table)."""

    class Cell(RequestModel):
        cell_id: str = Field(min_length=1, max_length=128)
        text_zh: str = Field(min_length=1, max_length=40_000)

    cells: list[EditTableTranslationRequest.Cell] = Field(min_length=1)


class EditStructureRequest(RequestModel):
    blocks: list[EditedBlockRequest] = Field(min_length=1)


class EditTranslationRequest(RequestModel):
    text_zh: str = Field(min_length=1, max_length=40_000)


class CreateAnchorBatchRequest(RequestModel):
    speaker: str = Field(min_length=1, max_length=64)
    anchor_text: str = Field(min_length=1, max_length=2_000)
    instruct: str = Field(default="", max_length=1_000)
    seed: int = Field(default=0, ge=0)
    count: int = Field(default=3, ge=1, le=10)


class ConfirmVoiceProfileRequest(RequestModel):
    voice_profile_id: str | None = Field(default=None, min_length=1, max_length=128)


def create_admin_app(container: Container) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        yield
        container.publisher_process.stop()

    app = FastAPI(title="Engirdle PC Admin", version="0.1.0", lifespan=lifespan)
    resource_root = FilePath(__file__).resolve().parent
    app.mount("/static", StaticFiles(directory=resource_root / "static"), name="static")

    @app.exception_handler(ContentNotFound)
    @app.exception_handler(JobNotFound)
    async def not_found_handler(_request: object, error: Exception) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=404, content={"detail": str(error)})

    @app.exception_handler(UnsupportedMarkdown)
    async def unsupported_markdown_handler(_request: object, error: Exception) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(
            status_code=422,
            content={"detail": str(error), "code": "unsupported_markdown"},
        )

    @app.exception_handler(InvalidContent)
    async def invalid_content_handler(_request: object, error: InvalidContent) -> object:
        from fastapi.responses import JSONResponse

        code = getattr(error, "code", "invalid_content")
        return JSONResponse(
            status_code=422, content={"detail": str(error), "code": code}
        )

    @app.exception_handler(InvalidTranslationEdit)
    @app.exception_handler(TableShapeMismatch)
    async def invalid_translation_handler(_request: object, error: Exception) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=422, content={"detail": str(error)})

    @app.exception_handler(ImmutableRevision)
    @app.exception_handler(InvalidJobState)
    @app.exception_handler(VoiceProfileNotConfigured)
    async def conflict_handler(_request: object, error: Exception) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=409, content={"detail": str(error)})

    @app.exception_handler(VoiceCandidateNotFound)
    async def voice_not_found_handler(
        _request: object, error: VoiceCandidateNotFound
    ) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=404, content={"detail": str(error)})

    @app.exception_handler(InvalidAnchorRequest)
    async def invalid_anchor_handler(
        _request: object, error: InvalidAnchorRequest
    ) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=422, content={"detail": str(error)})

    @app.exception_handler(SpeechConfigurationError)
    @app.exception_handler(SpeechGenerationError)
    @app.exception_handler(VoiceIntegrityError)
    async def speech_runtime_handler(_request: object, error: Exception) -> object:
        from fastapi.responses import JSONResponse

        # Server-side speech failures (GPU, checkpoints, integrity): surface
        # the actionable message instead of a bare 500.
        return JSONResponse(status_code=500, content={"detail": str(error)})

    @app.get("/api/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/api/publisher/status")
    def publisher_status() -> dict[str, object]:
        return _publisher_status_payload(container)

    @app.post("/api/publisher/start", status_code=status.HTTP_202_ACCEPTED)
    def start_publisher() -> dict[str, object]:
        try:
            container.publisher_process.start()
        except RuntimeError as error:
            raise HTTPException(status_code=503, detail=str(error)) from error
        return _publisher_status_payload(container)

    @app.post("/api/publisher/stop")
    def stop_publisher() -> dict[str, object]:
        container.publisher_process.stop()
        return _publisher_status_payload(container)

    @app.post("/api/artifacts/{package_id}/republish", status_code=status.HTTP_201_CREATED)
    def republish_artifact(package_id: str) -> dict[str, object]:
        artifact = container.local_library.republish(package_id)
        return {
            "package_id": artifact.package_id,
            "article_id": artifact.article_id,
            "revision": artifact.revision,
            "artifact_revision": artifact.artifact_revision,
        }

    @app.post("/api/articles", status_code=status.HTTP_201_CREATED)
    def create_article(request: CreateArticleRequest) -> dict[str, object]:
        revision = container.content.create(
            NewArticle(
                title=request.title,
                body=request.body,
                author=request.author,
                source_name=request.source_name,
                source_url=str(request.source_url) if request.source_url else None,
                license_name=request.license_name,
            )
        )
        return _revision_payload(revision)

    @app.get("/api/articles")
    def list_articles() -> list[dict[str, object]]:
        return [_revision_payload(revision) for revision in container.content.list_latest()]

    @app.post(
        "/api/articles/{article_id}/revisions", status_code=status.HTTP_201_CREATED
    )
    def create_article_revision(
        article_id: str, request: CreateArticleRequest
    ) -> dict[str, object]:
        revision = container.content.create_revision(
            article_id,
            NewArticle(
                title=request.title,
                body=request.body,
                author=request.author,
                source_name=request.source_name,
                source_url=str(request.source_url) if request.source_url else None,
                license_name=request.license_name,
            ),
        )
        return _revision_payload(revision)

    @app.get("/api/articles/{article_id}/revisions/{revision}")
    def get_article(article_id: str, revision: int) -> dict[str, object]:
        return _revision_payload(container.content.get(article_id, revision))

    @app.get("/api/articles/{article_id}/revisions/{revision}/structure-report")
    def get_structure_report(article_id: str, revision: int) -> dict[str, object]:
        """Parse warnings, derived structure tree and processing counters.

        Replaces the server-side assembly of the old Jinja structure page
        (design §8.5): the SPA renders the same read-only information from
        this JSON payload.
        """
        report = container.content.structure_report(article_id, revision)
        return {
            "article_id": report.revision.article_id,
            "revision": report.revision.revision,
            "warnings": [
                {"code": warning.code, "message": warning.message}
                for warning in report.warnings
            ],
            "structure_tree": structure_tree_payload(report.revision, report.plan),
            "processing_counts": processing_counts_payload(report.plan),
        }

    @app.get("/api/dashboard/summary")
    def dashboard_summary() -> dict[str, object]:
        """Workbench aggregate in a single round trip (design §8.5).

        Semantically mirrors the old Jinja dashboard assembly: latest
        revisions, recent jobs (with derived progress), current publications,
        artifacts, publisher state and the verification-mode badge inputs.
        """
        articles = container.content.list_latest()
        return {
            "articles": [_article_summary_payload(article) for article in articles],
            "jobs": [
                _job_detail_payload(container, job)
                for job in container.production.list_recent()
            ],
            "published": [
                _published_payload(package)
                for package in container.publishing.list_current()
            ],
            "artifacts": [
                _artifact_payload(artifact)
                for artifact in container.local_library.list_artifacts(
                    tuple(article.article_id for article in articles)
                )
            ],
            "publisher": _publisher_status_payload(container),
            "catalog_available": container.publisher_queries.catalog_path.is_file(),
            "verification_mode": (
                container.translations.name == "stub"
                or container.speech.name == "stub"
            ),
        }

    @app.delete("/api/articles/{article_id}")
    def delete_article(article_id: str, confirmation: str) -> dict[str, str]:
        try:
            deleted = container.local_library.delete_article(article_id, confirmation)
        except ValueError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        return {
            "article_id": deleted.article_id,
            "trash_path": str(deleted.trash_path),
        }

    @app.put("/api/articles/{article_id}/revisions/{revision}/structure")
    def edit_structure(
        article_id: str, revision: int, request: EditStructureRequest
    ) -> dict[str, object]:
        updated = container.content.edit_structure(
            article_id,
            revision,
            edited_blocks_from_request(request.blocks),
        )
        return _revision_payload(updated)

    @app.post(
        "/api/articles/{article_id}/revisions/{revision}/approve",
        status_code=status.HTTP_202_ACCEPTED,
    )
    def approve_article(article_id: str, revision: int) -> dict[str, object]:
        approved = container.content.approve(article_id, revision)
        return _job_payload(container.production.queue(approved))

    @app.post(
        "/api/articles/{article_id}/revisions/{revision}/rebuild",
        status_code=status.HTTP_202_ACCEPTED,
    )
    def rebuild_article(article_id: str, revision: int) -> dict[str, object]:
        frozen = container.content.get(article_id, revision)
        try:
            job = container.production.queue(frozen)
        except ValueError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        return _job_payload(job)

    @app.get("/api/jobs")
    def list_jobs() -> list[dict[str, object]]:
        return [
            _job_detail_payload(container, job)
            for job in container.production.list_recent()
        ]

    @app.get("/api/jobs/{job_id}")
    def get_job(job_id: str) -> dict[str, object]:
        return _job_detail_payload(container, container.production.get(job_id))

    @app.post("/api/jobs/{job_id}/retry", status_code=status.HTTP_202_ACCEPTED)
    def retry_job(job_id: str) -> dict[str, object]:
        return _job_payload(container.production.retry(job_id))

    @app.get("/api/jobs/{job_id}/translations")
    def list_translations(job_id: str) -> list[dict[str, object]]:
        """Sentence results and whole-table results, typed by unit kind.

        Code blocks never appear here: they have no translation unit
        (design §8.4).
        """
        job = container.production.get(job_id)
        revision = container.content.get(job.article_id, job.revision)
        source_by_id = {
            sentence.sentence_id: sentence.text
            for block in revision.blocks
            if hasattr(block, "sentences")
            for sentence in block.sentences
        }
        payloads: list[dict[str, object]] = []
        for unit in container.translations.list_for_job(job_id):
            generated = unit.generated
            edited = unit.edited
            if isinstance(generated, SentenceUnitTranslation):
                # Generated and edited values stay separate columns: an
                # edited sentence keeps its machine translation visible next
                # to the human correction (design §8.4).
                edited_texts = (
                    {
                        entry.sentence_id: entry.text_zh
                        for entry in edited.translations
                    }
                    if isinstance(edited, SentenceUnitTranslation)
                    else {}
                )
                for entry in generated.translations:
                    payloads.append(
                        {
                            "unit_kind": "sentence",
                            "unit_id": unit.unit_id,
                            "sentence_id": entry.sentence_id,
                            "source_text": source_by_id.get(entry.sentence_id, ""),
                            "generated_text": entry.text_zh,
                            "edited_text": edited_texts.get(entry.sentence_id),
                            "published_text": edited_texts.get(
                                entry.sentence_id, entry.text_zh
                            ),
                        }
                    )
            elif isinstance(generated, TableUnitTranslation):
                edited_cells = (
                    {
                        cell.cell_id: cell.text_zh
                        for cell in edited.cells
                    }
                    if isinstance(edited, TableUnitTranslation)
                    else {}
                )
                payloads.append(
                    {
                        "unit_kind": "table",
                        "unit_id": unit.unit_id,
                        "cells": [
                            {
                                "cell_id": cell.cell_id,
                                "generated_text": cell.text_zh,
                                "edited_text": edited_cells.get(cell.cell_id),
                                "published_text": edited_cells.get(
                                    cell.cell_id, cell.text_zh
                                ),
                            }
                            for cell in generated.cells
                        ],
                    }
                )
        return payloads

    @app.put("/api/jobs/{job_id}/translations/{sentence_id}")
    def edit_translation(
        job_id: str, sentence_id: str, request: EditTranslationRequest
    ) -> dict[str, str]:
        container.production.require_review(job_id)
        try:
            container.translations.edit_sentence(job_id, sentence_id, request.text_zh)
        except KeyError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        return {"sentence_id": sentence_id, "text_zh": request.text_zh.strip()}

    @app.put("/api/jobs/{job_id}/table-translations/{block_id}")
    def edit_table_translation(
        job_id: str, block_id: str, request: EditTableTranslationRequest
    ) -> dict[str, object]:
        """Save a complete manual table correction.

        Shape validation, empty-text checks and persistence live in the
        translation service; this layer only translates the request.
        """
        container.production.require_review(job_id)
        try:
            edited = container.translations.edit_table_cells(
                job_id,
                block_id,
                tuple(
                    TableTranslatedCell(cell_id=cell.cell_id, text_zh=cell.text_zh)
                    for cell in request.cells
                ),
            )
        except KeyError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        return {
            "block_id": block_id,
            "cells": [
                {"cell_id": cell.cell_id, "text_zh": cell.text_zh}
                for cell in edited.cells
            ],
        }

    @app.get("/api/jobs/{job_id}/audio")
    def get_audio_review(job_id: str) -> dict[str, object]:
        """Audio review lists ONLY narration-plan sentences (design §11.3).

        Tables, code blocks and dividers never show up as missing audio.
        """
        job = container.production.require_audio_ready(job_id)
        plan = container.content.processing_plan(job.article_id, job.revision)
        review = container.audio.review(job_id, plan.narration.sentence_ids)
        output = review.output
        return {
            "url": f"/api/jobs/{job_id}/audio/file",
            "duration_ms": output.duration_ms,
            "sample_rate_hz": output.sample_rate_hz,
            "channels": output.channels,
            "encoder_version": output.encoder_version,
            "sentences": [
                {
                    "sentence_id": timing.sentence_id,
                    "start_ms": timing.start_ms,
                    "end_ms": timing.end_ms,
                }
                for timing in output.timings
            ],
            "checks": {
                "missing_sentence_ids": review.checks.missing_sentence_ids,
                "zero_duration_sentence_ids": review.checks.zero_duration_sentence_ids,
                "abnormal_duration_sentence_ids": (
                    review.checks.abnormal_duration_sentence_ids
                ),
            },
        }

    @app.get("/api/jobs/{job_id}/audio/file")
    def get_audio_file(job_id: str) -> object:
        from fastapi.responses import FileResponse

        container.production.require_audio_ready(job_id)
        return FileResponse(container.audio.get(job_id).path, media_type="audio/mp4")

    @app.post("/api/jobs/{job_id}/publish", status_code=status.HTTP_201_CREATED)
    def publish_job(
        job_id: Annotated[str, Path(min_length=1, max_length=128)]
    ) -> dict[str, object]:
        artifact = container.release.release(job_id)
        return {
            "package_id": artifact.package_id,
            "article_id": artifact.article_id,
            "revision": artifact.revision,
            "artifact_revision": artifact.artifact_revision,
            "size": artifact.size,
            "sha256": artifact.sha256,
        }

    @app.get("/api/voices/speakers")
    def list_voice_speakers() -> list[dict[str, str]]:
        return [
            {"name": speaker.name, "description": speaker.description}
            for speaker in container.voices.english_speakers()
        ]

    @app.get("/api/voices/profiles")
    def list_voice_profiles() -> list[dict[str, object]]:
        return [_voice_profile_payload(profile) for profile in container.voices.list_profiles()]

    @app.post("/api/voices/profiles/{voice_profile_id}/{revision}/activate")
    def activate_voice_profile(voice_profile_id: str, revision: int) -> dict[str, object]:
        return _voice_profile_payload(
            container.voices.activate(voice_profile_id, revision)
        )

    @app.get("/api/voices/profiles/{voice_profile_id}/{revision}/audio")
    def get_voice_profile_audio(voice_profile_id: str, revision: int) -> object:
        from fastapi.responses import FileResponse

        profiles = container.voices.list_profiles()
        profile = next(
            (
                item
                for item in profiles
                if item.voice_profile_id == voice_profile_id and item.revision == revision
            ),
            None,
        )
        if profile is None or not profile.anchor_wav_path.is_file():
            raise HTTPException(status_code=404, detail="anchor audio not found")
        return FileResponse(profile.anchor_wav_path, media_type="audio/wav")

    @app.get("/api/voices/batches")
    def list_anchor_batches() -> list[dict[str, object]]:
        return [_anchor_batch_payload(batch) for batch in container.voices.list_batches()]

    @app.post("/api/voices/batches", status_code=status.HTTP_201_CREATED)
    def create_anchor_batch(request: CreateAnchorBatchRequest) -> dict[str, object]:
        batch = container.voices.create_anchor_batch(
            speaker=request.speaker,
            anchor_text=request.anchor_text,
            instruct=request.instruct,
            seed=request.seed,
            count=request.count,
        )
        return _anchor_batch_payload(batch)

    @app.get("/api/voices/batches/{batch_id}")
    def get_anchor_batch(batch_id: str) -> dict[str, object]:
        return _anchor_batch_payload(container.voices.get_batch(batch_id))

    @app.get("/api/voices/batches/{batch_id}/audio/{candidate_index}")
    def get_anchor_candidate_audio(batch_id: str, candidate_index: int) -> object:
        from fastapi.responses import FileResponse

        batch = container.voices.get_batch(batch_id)
        candidate = next(
            (
                item
                for item in batch.candidates
                if item.candidate_index == candidate_index
            ),
            None,
        )
        if candidate is None or not candidate.wav_path.is_file():
            raise HTTPException(status_code=404, detail="candidate audio not found")
        return FileResponse(candidate.wav_path, media_type="audio/wav")

    @app.post(
        "/api/voices/batches/{batch_id}/confirm/{candidate_index}",
        status_code=status.HTTP_201_CREATED,
    )
    def confirm_anchor_candidate(
        batch_id: str, candidate_index: int, request: ConfirmVoiceProfileRequest
    ) -> dict[str, object]:
        profile = container.voices.confirm_candidate(
            batch_id,
            candidate_index,
            voice_profile_id=request.voice_profile_id,
        )
        return _voice_profile_payload(profile)

    from engirdle_pc.entrypoints.admin_web.routes.pages import create_pages_router

    app.include_router(create_pages_router(container))
    return app


def _revision_payload(revision: ArticleRevision) -> dict[str, object]:
    return {
        "article_id": revision.article_id,
        "revision": revision.revision,
        "title": revision.title,
        "status": revision.status.value,
        "source_sha256": revision.source_sha256,
        "normalized_sha256": revision.normalized_sha256,
        "structure_sha256": revision.structure_sha256,
        "source": {
            "author": revision.source.author,
            "display_name": revision.source.display_name,
            "url": revision.source.url,
            "license_name": revision.source.license_name,
        },
        "blocks": [_block_view(block) for block in revision.blocks],
    }


def _block_view(
    block: TextBlock | TableBlock | CodeBlock | DividerBlock,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "block_id": block.block_id,
        "kind": block.kind.value,
        "order": block.order,
    }
    if isinstance(block, TextBlock):
        payload["style"] = block.style.value
        if block.heading_level is not None:
            payload["level"] = block.heading_level
        if block.list_kind is not None:
            payload["list_kind"] = block.list_kind.value
            payload["list_depth"] = block.list_depth
            payload["list_ordinal"] = block.list_ordinal
        if block.quote_depth:
            payload["quote_depth"] = block.quote_depth
        payload["sentences"] = [
            {
                "sentence_id": sentence.sentence_id,
                "order": sentence.order,
                "text": sentence.text,
                "runs": [
                    {"kind": run.kind.value, "text": run.text, "href": run.href}
                    for run in sentence.runs
                ],
            }
            for sentence in block.sentences
        ]
    elif isinstance(block, TableBlock):
        payload["alignments"] = [item.value for item in block.alignments]
        payload["header"] = [_cell_view(cell) for cell in block.header]
        payload["rows"] = [
            [_cell_view(cell) for cell in row] for row in block.rows
        ]
    elif isinstance(block, CodeBlock):
        payload["language"] = block.language
        payload["code"] = block.code
    return payload


def _cell_view(cell: TableCell) -> dict[str, object]:
    return {
        "cell_id": cell.cell_id,
        "text": cell.plain_text,
        "runs": [
            {"kind": run.kind.value, "text": run.text, "href": run.href}
            for run in cell.runs
        ],
    }


TextBlockRequest = (
    EditParagraphBlockRequest
    | EditHeadingBlockRequest
    | EditListItemBlockRequest
    | EditQuoteBlockRequest
)
EditedBlockRequestType = (
    TextBlockRequest
    | EditTableBlockRequest
    | EditCodeBlockRequest
    | EditDividerBlockRequest
)


def edited_blocks_from_request(
    blocks: Sequence[EditedBlockRequestType],
) -> tuple[EditedBlock, ...]:
    """Map discriminated edit requests onto the typed Edited union."""
    return tuple(_edited_block(block) for block in blocks)


def _edited_block(block: EditedBlockRequestType) -> EditedBlock:
    """Map a discriminated request onto the typed Edited union."""
    if isinstance(
        block,
        (
            EditParagraphBlockRequest,
            EditHeadingBlockRequest,
            EditListItemBlockRequest,
            EditQuoteBlockRequest,
        ),
    ):
        return EditedTextBlock(
            block_id=block.block_id,
            style=TextBlockStyle(block.kind),
            sentences=tuple(
                EditedSentence(sentence_id=item.sentence_id, text=item.text)
                for item in block.sentences
            ),
            heading_level=(
                block.level if isinstance(block, EditHeadingBlockRequest) else None
            ),
            list_kind=(
                block.list_kind
                if isinstance(block, EditListItemBlockRequest)
                else None
            ),
            list_depth=(
                block.list_depth
                if isinstance(block, EditListItemBlockRequest)
                else 0
            ),
            list_ordinal=(
                block.list_ordinal
                if isinstance(block, EditListItemBlockRequest)
                else None
            ),
            quote_depth=(
                block.quote_depth
                if isinstance(block, EditQuoteBlockRequest)
                else 0
            ),
        )
    if isinstance(block, EditTableBlockRequest):
        return EditedTableBlock(
            block_id=block.block_id,
            alignments=tuple(block.alignments),
            header=tuple(block.header),
            rows=tuple(tuple(row) for row in block.rows),
        )
    if isinstance(block, EditCodeBlockRequest):
        return EditedCodeBlock(
            block_id=block.block_id, code=block.code, language=block.language
        )
    return EditedDividerBlock(block_id=block.block_id)


def _voice_profile_payload(profile: VoiceProfile) -> dict[str, object]:
    return {
        "voice_profile_id": profile.voice_profile_id,
        "revision": profile.revision,
        "speaker": profile.speaker,
        "instruct": profile.instruct,
        "anchor_text": profile.anchor_text,
        "anchor_sha256": profile.anchor_sha256,
        "sample_rate_hz": profile.sample_rate_hz,
        "duration_ms": profile.duration_ms,
        "seed": profile.seed,
        "generation_params": profile.generation_params_json,
        "custom_voice_model": profile.custom_voice_model,
        "model_fingerprint": profile.model_fingerprint,
        "source_batch_id": profile.source_batch_id,
        "is_active": profile.is_active,
        "confirmed_at": profile.confirmed_at,
    }


def _anchor_batch_payload(batch: AnchorBatch) -> dict[str, object]:
    return {
        "batch_id": batch.batch_id,
        "speaker": batch.speaker,
        "instruct": batch.instruct,
        "anchor_text": batch.anchor_text,
        "seed": batch.seed,
        "custom_voice_model": batch.custom_voice_model,
        "model_fingerprint": batch.model_fingerprint,
        "created_at": batch.created_at,
        "candidates": [
            {
                "candidate_index": candidate.candidate_index,
                "seed": candidate.seed,
                "sha256": candidate.sha256,
                "duration_ms": candidate.duration_ms,
                "sample_rate_hz": candidate.sample_rate_hz,
            }
            for candidate in batch.candidates
        ],
    }


def _publisher_status_payload(container: Container) -> dict[str, object]:
    publisher = container.publisher_process.status()
    return {
        "running": publisher.running,
        "binding_host": publisher.binding_host,
        "port": publisher.port,
        "binding_url": publisher.binding_url,
        "started_at": publisher.started_at,
        "pid": publisher.pid,
        "last_exit_code": publisher.last_exit_code,
        "authentication": "none",
        "trusted_network_only": True,
    }


def _job_progress(container: Container, job: BuildJob) -> JobProgress:
    """Derive display progress from persisted state (design §8.1)."""
    return derive_job_progress(
        job,
        ProductionCheckpoint.from_json(job.checkpoint_json),
        container.content.processing_plan(job.article_id, job.revision),
    )


def _job_detail_payload(container: Container, job: BuildJob) -> dict[str, object]:
    """The job payload plus its derived progress (REST and SSE isomorphic)."""
    payload = _job_payload(job)
    payload["progress"] = _job_progress(container, job).to_payload()
    return payload


def structure_tree_payload(
    revision: ArticleRevision, plan: ProcessingPlan
) -> list[dict[str, object]]:
    """Read-only per-block summary with DERIVED processing flags (§11.1).

    Shared by the structure-report API and the legacy Jinja page: the
    translate/narrate routing is a projection of the plan, never a manual
    toggle, so UIs cannot contradict the pipeline protocol.
    """
    translate_ids = {unit.unit_id for unit in plan.translation.units}
    narrate_ids = {unit.source_block_id for unit in plan.narration.units}
    tree: list[dict[str, object]] = []
    for block in revision.blocks:
        entry: dict[str, object] = {
            "block_id": block.block_id,
            "kind": block.kind.value,
            "translates": block.block_id in translate_ids,
            "narrates": block.block_id in narrate_ids,
        }
        if isinstance(block, TextBlock):
            entry["summary"] = block.sentences[0].text[:80]
            entry["sentence_count"] = len(block.sentences)
            if block.heading_level is not None:
                entry["detail"] = f"level {block.heading_level}"
            elif block.list_kind is not None:
                entry["detail"] = f"{block.list_kind.value} list, depth {block.list_depth}"
            elif block.quote_depth:
                entry["detail"] = f"quote depth {block.quote_depth}"
        elif isinstance(block, TableBlock):
            entry["summary"] = " / ".join(
                cell.plain_text for cell in block.header[:4]
            )
            entry["detail"] = f"{len(block.header)} columns x {len(block.rows)} rows"
        elif isinstance(block, CodeBlock):
            entry["summary"] = (block.language or "plain") + " code block"
            entry["detail"] = f"{len(block.code)} characters"
        else:
            entry["summary"] = "thematic break"
            entry["detail"] = ""
        tree.append(entry)
    return tree


def processing_counts_payload(plan: ProcessingPlan) -> dict[str, int]:
    """Processing counters for the review header (design §11.3)."""
    code_blocks = sum(
        1 for block in plan.render.blocks if isinstance(block, CodeBlock)
    )
    return {
        "translated_sentences": sum(
            len(unit.sentences) for unit in plan.translation.sentence_units
        ),
        "translated_tables": len(plan.translation.table_units),
        "skipped_code_blocks": code_blocks,
        "narrated_sentences": len(plan.narration.units),
    }


def _article_summary_payload(revision: ArticleRevision) -> dict[str, object]:
    return {
        "article_id": revision.article_id,
        "revision": revision.revision,
        "title": revision.title,
        "status": revision.status.value,
        "source": {
            "author": revision.source.author,
            "display_name": revision.source.display_name,
            "url": revision.source.url,
            "license_name": revision.source.license_name,
        },
    }


def _published_payload(package: PublishedPackage) -> dict[str, object]:
    return {
        "package_id": package.package_id,
        "article_id": package.article_id,
        "revision": package.revision,
        "artifact_revision": package.artifact_revision,
        "title": package.title,
        "opaque_name": package.opaque_name,
        "size": package.size,
        "sha256": package.sha256,
        "published_at": package.published_at,
    }


def _artifact_payload(artifact: PackageArtifact) -> dict[str, object]:
    return {
        "package_id": artifact.package_id,
        "article_id": artifact.article_id,
        "revision": artifact.revision,
        "artifact_revision": artifact.artifact_revision,
        "size": artifact.size,
        "sha256": artifact.sha256,
        "state": artifact.state,
        "created_at": artifact.created_at,
    }


def _job_payload(job: BuildJob) -> dict[str, object]:
    return {
        "job_id": job.job_id,
        "article_id": job.article_id,
        "revision": job.revision,
        "status": job.status.value,
        "stage": job.stage.value,
        "attempts": job.attempts,
        "translation_adapter": job.config.translation_adapter,
        "speech_adapter": job.config.speech_adapter,
        "config_snapshot": {
            "pipeline_version": job.config.pipeline_version,
            "segmenter": job.config.segmenter,
            "translation": {
                "adapter": job.config.translation_adapter,
                "provider": job.config.translation_provider,
                "endpoint": job.config.translation_endpoint,
                "model": job.config.translation_model,
                "thinking": job.config.translation_thinking,
                "reasoning_effort": job.config.translation_reasoning_effort,
                "prompt": job.config.translation_prompt,
            },
            "speech": {
                "adapter": job.config.speech_adapter,
                "custom_voice_model": job.config.custom_voice_model,
                "base_model": job.config.base_model,
                "generation": job.config.speech_generation,
                "voice_profile": job.config.voice_profile,
                "anchor_sha256": job.config.anchor_sha256,
            },
            "audio_encoding": {
                "codec": job.config.audio_codec,
                "bitrate_kbps": job.config.audio_bitrate_kbps,
                "loudness_target_lufs": job.config.audio_loudness_target_lufs,
                "true_peak_dbfs": job.config.audio_true_peak_dbfs,
                "loudness_range_lu": job.config.audio_loudness_range_lu,
            },
        },
        "created_at": job.created_at,
        "started_at": job.started_at,
        "heartbeat_at": job.heartbeat_at,
        "finished_at": job.finished_at,
        "error": (
            {"code": job.error_code, "message": job.error_message}
            if job.error_code
            else None
        ),
    }

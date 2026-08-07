from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path as FilePath
from typing import Annotated

from fastapi import FastAPI, HTTPException, Path, status
from fastapi.staticfiles import StaticFiles
from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field

from engirdle_pc.bootstrap.container import Container
from engirdle_pc.modules.content.public import (
    ArticleRevision,
    BlockKind,
    ContentNotFound,
    EditedBlock,
    EditedSentence,
    ImmutableRevision,
    InvalidContent,
    NewArticle,
)
from engirdle_pc.modules.production.public import (
    BuildJob,
    InvalidJobState,
    JobNotFound,
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


class EditBlockRequest(RequestModel):
    block_id: str | None = None
    kind: BlockKind
    sentences: list[EditSentenceRequest] = Field(min_length=1)


class EditStructureRequest(RequestModel):
    blocks: list[EditBlockRequest] = Field(min_length=1)


class EditTranslationRequest(RequestModel):
    text_zh: str = Field(min_length=1, max_length=40_000)


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

    @app.exception_handler(InvalidContent)
    async def invalid_content_handler(_request: object, error: InvalidContent) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=422, content={"detail": str(error)})

    @app.exception_handler(ImmutableRevision)
    @app.exception_handler(InvalidJobState)
    async def conflict_handler(_request: object, error: Exception) -> object:
        from fastapi.responses import JSONResponse

        return JSONResponse(status_code=409, content={"detail": str(error)})

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
            tuple(
                EditedBlock(
                    block_id=block.block_id,
                    kind=block.kind,
                    sentences=tuple(
                        EditedSentence(
                            sentence_id=sentence.sentence_id, text=sentence.text
                        )
                        for sentence in block.sentences
                    ),
                )
                for block in request.blocks
            ),
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
        return [_job_payload(job) for job in container.production.list_recent()]

    @app.get("/api/jobs/{job_id}")
    def get_job(job_id: str) -> dict[str, object]:
        return _job_payload(container.production.get(job_id))

    @app.post("/api/jobs/{job_id}/retry", status_code=status.HTTP_202_ACCEPTED)
    def retry_job(job_id: str) -> dict[str, object]:
        return _job_payload(container.production.retry(job_id))

    @app.get("/api/jobs/{job_id}/translations")
    def list_translations(job_id: str) -> list[dict[str, object]]:
        job = container.production.get(job_id)
        revision = container.content.get(job.article_id, job.revision)
        source_by_id = {
            sentence.sentence_id: sentence.text
            for block in revision.blocks
            for sentence in block.sentences
        }
        return [
            {
                "sentence_id": item.sentence_id,
                "source_text": source_by_id[item.sentence_id],
                "generated_text": item.generated_text,
                "edited_text": item.edited_text,
                "published_text": item.published_text,
            }
            for item in container.translations.list_for_job(job_id)
        ]

    @app.put("/api/jobs/{job_id}/translations/{sentence_id}")
    def edit_translation(
        job_id: str, sentence_id: str, request: EditTranslationRequest
    ) -> dict[str, str]:
        container.production.require_review(job_id)
        try:
            container.translations.edit(job_id, sentence_id, request.text_zh)
        except KeyError as error:
            raise HTTPException(status_code=404, detail=str(error)) from error
        return {"sentence_id": sentence_id, "text_zh": request.text_zh.strip()}

    @app.get("/api/jobs/{job_id}/audio")
    def get_audio_review(job_id: str) -> dict[str, object]:
        job = container.production.require_audio_ready(job_id)
        revision = container.content.get(job.article_id, job.revision)
        review = container.audio.review(job_id, _sentence_ids(revision))
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
        "blocks": [
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
        ],
    }


def _sentence_ids(revision: ArticleRevision) -> tuple[str, ...]:
    return tuple(
        sentence.sentence_id
        for block in revision.blocks
        for sentence in block.sentences
    )


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

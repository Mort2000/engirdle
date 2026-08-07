from __future__ import annotations

import json
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates

from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import EditStructureRequest
from engirdle_pc.modules.content.public import (
    ArticleRevision,
    EditedBlock,
    EditedSentence,
    NewArticle,
)

_TEMPLATES = Jinja2Templates(directory=Path(__file__).resolve().parents[1] / "templates")


def create_pages_router(container: Container) -> APIRouter:
    router = APIRouter(include_in_schema=False)

    @router.get("/")
    def dashboard(request: Request) -> object:
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="dashboard.html",
            context={
                "articles": container.content.list_latest(),
                "jobs": container.production.list_recent(),
                "catalog_available": container.publisher_queries.catalog_path.is_file(),
            },
        )

    @router.get("/articles/new")
    def article_entry(request: Request) -> object:
        return _TEMPLATES.TemplateResponse(
            request=request, name="article_new.html", context={}
        )

    @router.post("/articles")
    def create_article(
        title: Annotated[str, Form()],
        body: Annotated[str, Form()],
        author: Annotated[str, Form()] = "",
        source_name: Annotated[str, Form()] = "",
        source_url: Annotated[str, Form()] = "",
        license_name: Annotated[str, Form()] = "unknown",
    ) -> RedirectResponse:
        revision = container.content.create(
            NewArticle(
                title=title,
                body=body,
                author=author,
                source_name=source_name,
                source_url=source_url,
                license_name=license_name,
            )
        )
        return RedirectResponse(
            f"/articles/{revision.article_id}/revisions/{revision.revision}",
            status_code=303,
        )

    @router.get("/articles/{article_id}/new-revision")
    def new_revision_entry(request: Request, article_id: str) -> object:
        article = container.content.latest_revision(article_id)
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="article_revision_new.html",
            context={"article": article},
        )

    @router.post("/articles/{article_id}/revisions")
    def create_revision(
        article_id: str,
        title: Annotated[str, Form()],
        body: Annotated[str, Form()],
        author: Annotated[str, Form()] = "",
        source_name: Annotated[str, Form()] = "",
        source_url: Annotated[str, Form()] = "",
        license_name: Annotated[str, Form()] = "unknown",
    ) -> RedirectResponse:
        revision = container.content.create_revision(
            article_id,
            NewArticle(
                title=title,
                body=body,
                author=author,
                source_name=source_name,
                source_url=source_url,
                license_name=license_name,
            ),
        )
        return RedirectResponse(
            f"/articles/{article_id}/revisions/{revision.revision}", status_code=303
        )

    @router.get("/articles/{article_id}/revisions/{revision_number}")
    def article_structure(
        request: Request, article_id: str, revision_number: int
    ) -> object:
        revision = container.content.get(article_id, revision_number)
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="article_structure.html",
            context={
                "article": revision,
                "structure_json": _structure_json(revision),
            },
        )

    @router.post("/articles/{article_id}/revisions/{revision_number}/structure")
    def save_structure(
        article_id: str,
        revision_number: int,
        structure_json: Annotated[str, Form()],
    ) -> RedirectResponse:
        request = EditStructureRequest.model_validate(
            {"blocks": json.loads(structure_json)}
        )
        container.content.edit_structure(
            article_id,
            revision_number,
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
        return RedirectResponse(
            f"/articles/{article_id}/revisions/{revision_number}", status_code=303
        )

    @router.post("/articles/{article_id}/revisions/{revision_number}/approve")
    def approve_structure(
        article_id: str, revision_number: int
    ) -> RedirectResponse:
        approved = container.content.approve(article_id, revision_number)
        job = container.production.queue(approved)
        return RedirectResponse(f"/jobs/{job.job_id}", status_code=303)

    @router.post("/articles/{article_id}/revisions/{revision_number}/rebuild")
    def rebuild_revision(article_id: str, revision_number: int) -> RedirectResponse:
        job = container.production.queue(
            container.content.get(article_id, revision_number)
        )
        return RedirectResponse(f"/jobs/{job.job_id}", status_code=303)

    @router.post("/articles/{article_id}/delete")
    def delete_article(
        article_id: str, confirmation: Annotated[str, Form()]
    ) -> RedirectResponse:
        try:
            container.local_library.delete_article(article_id, confirmation)
        except ValueError as error:
            raise HTTPException(status_code=409, detail=str(error)) from error
        return RedirectResponse("/", status_code=303)

    @router.get("/jobs/{job_id}")
    def job_review(request: Request, job_id: str) -> object:
        job = container.production.get(job_id)
        translations = container.translations.list_for_job(job_id)
        revision = container.content.get(job.article_id, job.revision)
        source_by_id = {
            sentence.sentence_id: sentence.text
            for block in revision.blocks
            for sentence in block.sentences
        }
        audio = None
        if job.status.value in {"review_required", "succeeded"}:
            audio = container.audio.get(job_id)
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="job.html",
            context={
                "job": job,
                "translations": translations,
                "source_by_id": source_by_id,
                "audio": audio,
            },
        )

    @router.post("/jobs/{job_id}/translations/{sentence_id}")
    def save_translation(
        job_id: str,
        sentence_id: str,
        text_zh: Annotated[str, Form()],
    ) -> RedirectResponse:
        if container.production.get(job_id).status.value != "review_required":
            raise HTTPException(status_code=409, detail="translation review is closed")
        container.translations.edit(job_id, sentence_id, text_zh)
        return RedirectResponse(f"/jobs/{job_id}", status_code=303)

    @router.post("/jobs/{job_id}/retry")
    def retry_job(job_id: str) -> RedirectResponse:
        container.production.retry(job_id)
        return RedirectResponse(f"/jobs/{job_id}", status_code=303)

    @router.post("/jobs/{job_id}/publish")
    def publish_job(job_id: str) -> RedirectResponse:
        container.release.release(job_id)
        return RedirectResponse(f"/jobs/{job_id}", status_code=303)

    return router


def _structure_json(revision: ArticleRevision) -> str:
    blocks = [
        {
            "block_id": block.block_id,
            "kind": block.kind.value,
            "sentences": [
                {"sentence_id": sentence.sentence_id, "text": sentence.text}
                for sentence in block.sentences
            ],
        }
        for block in revision.blocks
    ]
    return json.dumps(blocks, ensure_ascii=False, indent=2)

from __future__ import annotations

import json
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates

from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import EditStructureRequest
from engirdle_pc.entrypoints.admin_web.view_models import (
    anchor_batch_view,
    article_view,
    artifact_view,
    audio_review_view,
    job_view,
    published_view,
    publisher_view,
    translation_views,
    voice_profile_view,
)
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
        publisher_status = container.publisher_process.status()
        article_entities = container.content.list_latest()
        artifacts = container.local_library.list_artifacts(
            tuple(article.article_id for article in article_entities)
        )
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="dashboard.html",
            context={
                "articles": tuple(
                    article_view(article) for article in article_entities
                ),
                "jobs": tuple(
                    job_view(job) for job in container.production.list_recent()
                ),
                "published": tuple(
                    published_view(package)
                    for package in container.publishing.list_current()
                ),
                "artifacts": tuple(artifact_view(artifact) for artifact in artifacts),
                "catalog_available": container.publisher_queries.catalog_path.is_file(),
                "publisher": publisher_view(publisher_status),
                "verification_mode": (
                    container.translations.name == "stub"
                    or container.speech.name == "stub"
                ),
            },
        )

    @router.post("/artifacts/{package_id}/republish")
    def republish_artifact(package_id: str) -> RedirectResponse:
        container.local_library.republish(package_id)
        return RedirectResponse("/", status_code=303)

    @router.post("/publisher/start")
    def start_publisher() -> RedirectResponse:
        container.publisher_process.start()
        return RedirectResponse("/", status_code=303)

    @router.post("/publisher/stop")
    def stop_publisher() -> RedirectResponse:
        container.publisher_process.stop()
        return RedirectResponse("/", status_code=303)

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
            context={"article": article_view(article)},
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
                "article": article_view(revision),
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
        translation_entities = container.translations.list_for_job(job_id)
        revision = container.content.get(job.article_id, job.revision)
        source_by_id = {
            sentence.sentence_id: sentence.text
            for block in revision.blocks
            for sentence in block.sentences
        }
        audio_review = None
        if container.production.audio_is_ready(job_id):
            audio_entity = container.audio.review(
                job_id,
                tuple(source_by_id),
            )
            audio_review = audio_review_view(audio_entity, source_by_id)
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="job.html",
            context={
                "job": job_view(job),
                "translations": translation_views(
                    translation_entities, source_by_id
                ),
                "audio_review": audio_review,
            },
        )

    @router.post("/jobs/{job_id}/translations/{sentence_id}")
    def save_translation(
        job_id: str,
        sentence_id: str,
        text_zh: Annotated[str, Form()],
    ) -> RedirectResponse:
        container.production.require_review(job_id)
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

    @router.get("/voices")
    def voices_overview(request: Request) -> object:
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="voices.html",
            context={
                "profiles": tuple(
                    voice_profile_view(profile)
                    for profile in container.voices.list_profiles()
                ),
                "batches": tuple(
                    anchor_batch_view(batch)
                    for batch in container.voices.list_batches()
                ),
            },
        )

    @router.get("/voices/new")
    def new_voice_batch(request: Request) -> object:
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="voice_new.html",
            context={
                "speakers": container.voices.english_speakers(),
                "default_anchor_text": DEFAULT_ANCHOR_TEXT,
                "default_candidate_count": container.settings.speech_anchor_candidates,
            },
        )

    @router.post("/voices/batches")
    def create_voice_batch(
        speaker: Annotated[str, Form()],
        anchor_text: Annotated[str, Form()],
        instruct: Annotated[str, Form()] = "",
        seed: Annotated[int, Form()] = 0,
        count: Annotated[int, Form()] = 3,
    ) -> RedirectResponse:
        batch = container.voices.create_anchor_batch(
            speaker=speaker,
            anchor_text=anchor_text,
            instruct=instruct,
            seed=seed,
            count=count,
        )
        return RedirectResponse(f"/voices/batches/{batch.batch_id}", status_code=303)

    @router.get("/voices/batches/{batch_id}")
    def audition_voice_batch(request: Request, batch_id: str) -> object:
        return _TEMPLATES.TemplateResponse(
            request=request,
            name="voice_batch.html",
            context={"batch": anchor_batch_view(container.voices.get_batch(batch_id))},
        )

    @router.post("/voices/batches/{batch_id}/confirm/{candidate_index}")
    def confirm_voice_candidate(
        batch_id: str,
        candidate_index: int,
        voice_profile_id: Annotated[str, Form()] = "",
    ) -> RedirectResponse:
        container.voices.confirm_candidate(
            batch_id,
            candidate_index,
            voice_profile_id=voice_profile_id or None,
        )
        return RedirectResponse("/voices", status_code=303)

    @router.post("/voices/profiles/{voice_profile_id}/{revision}/activate")
    def activate_voice_profile(voice_profile_id: str, revision: int) -> RedirectResponse:
        container.voices.activate(voice_profile_id, revision)
        return RedirectResponse("/voices", status_code=303)

    return router


DEFAULT_ANCHOR_TEXT = (
    "Every article deserves a clear voice. When the narration flows naturally, "
    "listening becomes effortless."
)


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

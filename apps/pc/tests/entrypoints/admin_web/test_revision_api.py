from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app


def test_editing_frozen_content_creates_a_new_article_revision(
    tmp_path: Path, fake_translator
) -> None:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"), translation_adapter=fake_translator
    )
    client = TestClient(create_admin_app(container))
    first = client.post(
        "/api/articles", json={"title": "Versioned", "body": "Original sentence."}
    ).json()
    article_id = first["article_id"]
    job_id = client.post(
        f"/api/articles/{article_id}/revisions/1/approve"
    ).json()["job_id"]
    container.worker.run_once()
    client.post(f"/api/jobs/{job_id}/publish")

    created = client.post(
        f"/api/articles/{article_id}/revisions",
        json={"title": "Versioned", "body": "A changed sentence boundary. Another sentence."},
    )
    assert created.status_code == 201
    assert created.json()["article_id"] == article_id
    assert created.json()["revision"] == 2
    assert created.json()["status"] == "structured"
    assert client.get(f"/api/articles/{article_id}/revisions/1").json()["status"] == "published"


def test_user_can_rebuild_a_published_revision_as_a_new_artifact(
    tmp_path: Path, fake_translator
) -> None:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"), translation_adapter=fake_translator
    )
    client = TestClient(create_admin_app(container))
    article = client.post(
        "/api/articles", json={"title": "Rebuildable", "body": "Build this twice."}
    ).json()
    article_id = article["article_id"]
    first_job = client.post(
        f"/api/articles/{article_id}/revisions/1/approve"
    ).json()["job_id"]
    container.worker.run_once()
    first_artifact = client.post(f"/api/jobs/{first_job}/publish").json()
    assert first_artifact["artifact_revision"] == 1

    rebuild = client.post(f"/api/articles/{article_id}/revisions/1/rebuild")
    assert rebuild.status_code == 202
    container.worker.run_once()
    second_artifact = client.post(
        f"/api/jobs/{rebuild.json()['job_id']}/publish"
    ).json()
    assert second_artifact["revision"] == 1
    assert second_artifact["artifact_revision"] == 2

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.entrypoints.publisher.app import create_publisher_app


def test_user_can_produce_review_and_publish_an_article(tmp_path: Path) -> None:
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(settings)
    admin = TestClient(create_admin_app(container))

    created = admin.post(
        "/api/articles",
        json={
            "title": "A Small Test",
            "body": "First sentence. Second sentence!\n\n> A quoted thought?",
            "author": "Example Author",
            "source_name": "Local fixture",
            "source_url": None,
            "license_name": "CC0-1.0",
        },
    )
    assert created.status_code == 201
    revision = created.json()
    assert [block["kind"] for block in revision["blocks"]] == ["paragraph", "quote"]
    assert [sentence["text"] for sentence in revision["blocks"][0]["sentences"]] == [
        "First sentence.",
        "Second sentence!",
    ]

    approved = admin.post(
        f"/api/articles/{revision['article_id']}/revisions/1/approve"
    )
    assert approved.status_code == 202
    job_id = approved.json()["job_id"]

    assert container.worker.run_once() is True
    review = admin.get(f"/api/jobs/{job_id}")
    assert review.status_code == 200
    assert review.json()["status"] == "review_required"
    assert review.json()["stage"] == "review"
    assert review.json()["translation_adapter"] == "stub"
    assert review.json()["speech_adapter"] == "stub"
    assert review.json()["config_snapshot"]["translation"]["endpoint"] == "stub://deepseek"
    assert review.json()["config_snapshot"]["speech"]["generation"] == "tone-pcm@v1"

    translations = admin.get(f"/api/jobs/{job_id}/translations").json()
    first_sentence_id = translations[0]["sentence_id"]
    assert translations[0]["source_text"] == "First sentence."
    corrected = admin.put(
        f"/api/jobs/{job_id}/translations/{first_sentence_id}",
        json={"text_zh": "人工确认的第一句。"},
    )
    assert corrected.status_code == 200

    published = admin.post(f"/api/jobs/{job_id}/publish")
    assert published.status_code == 201
    package = published.json()

    publisher = TestClient(create_publisher_app(container.publisher_queries))
    catalog_response = publisher.get("/catalog.json")
    assert catalog_response.status_code == 200
    catalog_item = catalog_response.json()["packages"][0]
    assert catalog_item["article_id"] == revision["article_id"]
    assert catalog_item["sha256"] == package["sha256"]

    package_response = publisher.get(catalog_item["url"])
    assert package_response.status_code == 200
    assert hashlib.sha256(package_response.content).hexdigest() == package["sha256"]
    package_path = tmp_path / "downloaded.readpack"
    package_path.write_bytes(package_response.content)
    with ZipFile(package_path) as archive:
        assert set(archive.namelist()) == {
            "manifest.json",
            "article.json",
            "attribution.json",
            "audio/article.m4a",
        }
        article_payload = json.loads(archive.read("article.json"))
        assert (
            article_payload["blocks"][0]["sentences"][0]["translation_zh"]
            == "人工确认的第一句。"
        )

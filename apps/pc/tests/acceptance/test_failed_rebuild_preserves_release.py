from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.entrypoints.publisher.app import create_publisher_app
from engirdle_pc.modules.content.public import ArticleRevision, Block
from engirdle_pc.modules.translation.public import (
    StubTranslationAdapter,
    TranslationBatch,
)


class FailSecondBuildOnceTranslator:
    name = "fault-injection-stub"
    provider = "stub-deepseek"
    endpoint = "stub://fault-injection"
    model = "deepseek-v4-flash-stub"

    def __init__(self) -> None:
        self._delegate = StubTranslationAdapter()
        self._build_number = 0
        self._failed = False

    def begin(self, revision: ArticleRevision) -> str:
        self._build_number += 1
        return f"build-{self._build_number}:{self._delegate.begin(revision)}"

    def translate_block(
        self, revision: ArticleRevision, block: Block, checkpoint_id: str
    ) -> TranslationBatch:
        if checkpoint_id.startswith("build-2:") and not self._failed:
            self._failed = True
            raise RuntimeError("injected translation outage")
        return self._delegate.translate_block(revision, block, checkpoint_id)


def test_failed_rebuild_keeps_previous_package_until_retry_succeeds(
    tmp_path: Path,
) -> None:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=FailSecondBuildOnceTranslator(),
    )
    admin = TestClient(create_admin_app(container))
    publisher = TestClient(create_publisher_app(container.publisher_queries))
    article = admin.post(
        "/api/articles", json={"title": "Stable", "body": "Keep the old release."}
    ).json()
    article_id = article["article_id"]
    first_job = admin.post(
        f"/api/articles/{article_id}/revisions/1/approve"
    ).json()["job_id"]
    container.worker.run_once()
    admin.post(f"/api/jobs/{first_job}/publish")
    previous_catalog = publisher.get("/catalog.json").json()
    previous_url = previous_catalog["packages"][0]["url"]
    previous_hash = previous_catalog["packages"][0]["sha256"]

    rebuild = admin.post(f"/api/articles/{article_id}/revisions/1/rebuild").json()
    container.worker.run_once()
    failed = admin.get(f"/api/jobs/{rebuild['job_id']}").json()
    assert failed["status"] == "failed"
    assert failed["error"]["code"] == "RuntimeError"
    assert publisher.get("/catalog.json").json()["packages"][0]["sha256"] == previous_hash
    assert publisher.get(previous_url).status_code == 200

    assert admin.post(f"/api/jobs/{rebuild['job_id']}/retry").status_code == 202
    container.worker.run_once()
    assert admin.get(f"/api/jobs/{rebuild['job_id']}").json()["status"] == "review_required"
    released = admin.post(f"/api/jobs/{rebuild['job_id']}/publish")
    assert released.status_code == 201
    assert released.json()["artifact_revision"] == 2
    assert publisher.get("/catalog.json").json()["packages"][0]["sha256"] != previous_hash

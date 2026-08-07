from pathlib import Path
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.entrypoints.publisher.app import create_publisher_app
from engirdle_pc.modules.content.public import ArticleRevision, Block
from engirdle_pc.modules.publishing.infrastructure.validator import CatalogValidator
from engirdle_pc.modules.publishing.public import InvalidCatalog
from engirdle_pc.modules.translation.infrastructure.stub_adapter import StubTranslationAdapter
from engirdle_pc.modules.translation.public import TranslationBatch
from engirdle_pc.shared.infrastructure.runtime import UuidIdentifierGenerator


class FailSecondBuildOnceTranslator:
    name = "fault-injection-stub"
    provider = "stub-deepseek"
    endpoint = "stub://fault-injection"
    model = "deepseek-v4-flash-stub"

    def __init__(self) -> None:
        self._delegate = StubTranslationAdapter(UuidIdentifierGenerator())
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


class FailSecondCatalogWriteValidator:
    def __init__(self, delegate: CatalogValidator) -> None:
        self._delegate = delegate
        self._validation_count = 0

    def validate_file(self, path: Path, service_origin: str | None = None) -> None:
        self._validation_count += 1
        if self._validation_count == 2:
            raise InvalidCatalog("injected catalog write failure")
        self._delegate.validate_file(path, service_origin)


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


def test_catalog_write_failure_does_not_make_previous_package_unavailable(
    tmp_path: Path,
) -> None:
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(
        settings,
        catalog_validator=FailSecondCatalogWriteValidator(
            CatalogValidator(settings.contracts_dir)
        ),
    )
    admin = TestClient(create_admin_app(container))
    publisher = TestClient(create_publisher_app(container.publisher_queries))
    article = admin.post(
        "/api/articles", json={"title": "Atomic", "body": "Keep serving this package."}
    ).json()
    first_job = admin.post(
        f"/api/articles/{article['article_id']}/revisions/1/approve"
    ).json()["job_id"]
    container.worker.run_once()
    admin.post(f"/api/jobs/{first_job}/publish")
    old_url = publisher.get("/catalog.json").json()["packages"][0]["url"]

    rebuild = admin.post(
        f"/api/articles/{article['article_id']}/revisions/1/rebuild"
    ).json()
    container.worker.run_once()
    with pytest.raises(InvalidCatalog, match="injected catalog write failure"):
        admin.post(f"/api/jobs/{rebuild['job_id']}/publish")

    assert publisher.get("/catalog.json").json()["packages"][0]["url"] == old_url
    assert publisher.get(old_url).status_code == 200
    container.publishing.regenerate_catalog()
    assert publisher.get("/catalog.json").json()["packages"][0]["url"] == old_url


def test_release_finalization_failure_never_switches_catalog(tmp_path: Path) -> None:
    container = Container.build(Settings(workspace=tmp_path / "workspace"))
    admin = TestClient(create_admin_app(container))
    publisher = TestClient(create_publisher_app(container.publisher_queries))
    article = admin.post(
        "/api/articles", json={"title": "Finalize", "body": "Stable package."}
    ).json()
    first_job = admin.post(
        f"/api/articles/{article['article_id']}/revisions/1/approve"
    ).json()["job_id"]
    container.worker.run_once()
    admin.post(f"/api/jobs/{first_job}/publish")
    old_url = publisher.get("/catalog.json").json()["packages"][0]["url"]

    rebuild = admin.post(
        f"/api/articles/{article['article_id']}/revisions/1/rebuild"
    ).json()
    container.worker.run_once()
    with (
        patch.object(
            container.production,
            "mark_succeeded",
            side_effect=RuntimeError("injected finalization failure"),
        ),
        pytest.raises(RuntimeError, match="injected finalization failure"),
    ):
        admin.post(f"/api/jobs/{rebuild['job_id']}/publish")

    assert admin.get(f"/api/jobs/{rebuild['job_id']}").json()["status"] == "failed"
    assert publisher.get("/catalog.json").json()["packages"][0]["url"] == old_url
    assert publisher.get(old_url).status_code == 200

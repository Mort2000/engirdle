from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.entrypoints.publisher.app import create_publisher_app


def test_confirmed_local_delete_removes_catalog_entry_and_moves_files_to_trash(
    tmp_path: Path,
    fake_translator,
) -> None:
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(settings, translation_adapter=fake_translator)
    admin = TestClient(create_admin_app(container))
    publisher = TestClient(create_publisher_app(container.publisher_queries))
    article = admin.post(
        "/api/articles", json={"title": "Disposable", "body": "Delete locally."}
    ).json()
    article_id = article["article_id"]
    job_id = admin.post(
        f"/api/articles/{article_id}/revisions/1/approve"
    ).json()["job_id"]
    container.worker.run_once()
    admin.post(f"/api/jobs/{job_id}/publish")
    package_url = publisher.get("/catalog.json").json()["packages"][0]["url"]

    refused = admin.delete(
        f"/api/articles/{article_id}", params={"confirmation": "wrong"}
    )
    assert refused.status_code == 409
    deleted = admin.delete(
        f"/api/articles/{article_id}", params={"confirmation": article_id}
    )
    assert deleted.status_code == 200
    assert deleted.json()["article_id"] == article_id
    assert Path(deleted.json()["trash_path"]).is_dir()
    assert admin.get(f"/api/articles/{article_id}/revisions/1").status_code == 404
    assert publisher.get("/catalog.json").json()["packages"] == []
    assert publisher.get(package_url).status_code == 404

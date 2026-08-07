import subprocess
import sys
from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.publisher_container import PublisherContainer
from engirdle_pc.entrypoints.publisher.app import create_publisher_app


def test_lan_publisher_exposes_only_read_only_catalog_and_package_routes(
    tmp_path: Path,
) -> None:
    settings = Settings(workspace=tmp_path / "workspace")
    container = PublisherContainer.build(settings)
    assert not settings.workspace.exists()
    app = create_publisher_app(container.publisher_queries)
    business_routes = {
        (route.path, frozenset(route.methods or set()))
        for route in app.routes
        if route.path in {"/catalog.json", "/packages/{opaque_name}"}
    }
    assert business_routes == {
        ("/catalog.json", frozenset({"GET", "HEAD"})),
        ("/packages/{opaque_name}", frozenset({"GET", "HEAD"})),
    }

    client = TestClient(app)
    assert client.post("/catalog.json").status_code == 405
    assert client.get("/api/articles").status_code == 404
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


def test_publisher_import_graph_excludes_writes_workers_and_model_modules() -> None:
    script = """
import sys
from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.publisher_container import PublisherContainer
from engirdle_pc.entrypoints.publisher.app import create_publisher_app
create_publisher_app(PublisherContainer.build(Settings()).publisher_queries)
blocked = (
    'engirdle_pc.entrypoints.admin_web',
    'engirdle_pc.modules.production',
    'engirdle_pc.modules.translation',
    'engirdle_pc.modules.speech',
)
assert not [name for name in sys.modules if name.startswith(blocked)]
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert completed.returncode == 0, completed.stderr

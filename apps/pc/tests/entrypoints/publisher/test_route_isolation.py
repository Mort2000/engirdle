from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.publisher.app import create_publisher_app


def test_lan_publisher_exposes_only_read_only_catalog_and_package_routes(
    tmp_path: Path,
) -> None:
    container = Container.build(Settings(workspace=tmp_path / "workspace"))
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

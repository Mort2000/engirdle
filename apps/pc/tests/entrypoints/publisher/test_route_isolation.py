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
        if route.path in {"/catalog.json", "/packages/{opaque_name}", "/dictionaries/{opaque_name}"}
    }
    assert business_routes == {
        ("/catalog.json", frozenset({"GET", "HEAD"})),
        ("/packages/{opaque_name}", frozenset({"GET", "HEAD"})),
        ("/dictionaries/{opaque_name}", frozenset({"GET", "HEAD"})),
    }

    client = TestClient(app)
    assert client.post("/catalog.json").status_code == 405
    assert client.get("/api/articles").status_code == 404
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


def test_dictionary_route_only_serves_catalog_allowlisted_dictpacks(tmp_path: Path) -> None:
    settings = Settings(workspace=tmp_path / "workspace")
    dictionaries = settings.public_dir / "dictionaries"
    dictionaries.mkdir(parents=True)
    allowed = dictionaries / "engirdle-en-zh-r1-a1b2.dictpack"
    allowed.write_bytes(b"dictionary package")
    (dictionaries / "not-listed.dictpack").write_bytes(b"secret")
    (settings.public_dir / "catalog.json").write_text(
        """{
          "catalog_version": 1,
          "generated_at": "2026-08-09T00:00:00Z",
          "packages": [],
          "dictionaries": [{
            "dictionary_id": "engirdle-en-zh",
            "revision": 1,
            "format_version": "1.0",
            "schema_version": 1,
            "display_name": "Engirdle English-Chinese Offline Dictionary",
            "size": 18,
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "url": "/dictionaries/engirdle-en-zh-r1-a1b2.dictpack"
          }]
        }""",
        encoding="utf-8",
    )
    client = TestClient(create_publisher_app(PublisherContainer.build(settings).publisher_queries))

    response = client.get("/dictionaries/engirdle-en-zh-r1-a1b2.dictpack")

    assert response.status_code == 200
    assert response.content == b"dictionary package"
    assert client.get("/dictionaries/not-listed.dictpack").status_code == 404
    assert client.get("/dictionaries/%2e%2e%2Fcatalog.json").status_code == 404


def test_dictionary_sidecar_survives_catalog_regeneration_and_is_downloadable(
    tmp_path: Path,
) -> None:
    from engirdle_pc.bootstrap.container import Container

    settings = Settings(workspace=tmp_path / "workspace")
    dictionaries = settings.public_dir / "dictionaries"
    dictionaries.mkdir(parents=True)
    package = dictionaries / "engirdle-en-zh-r1-a1b2.dictpack"
    package.write_bytes(b"dictionary package")
    (settings.public_dir / "dictionary.json").write_text(
        """{
          "dictionary_id": "engirdle-en-zh",
          "revision": 1,
          "format_version": "1.0",
          "schema_version": 1,
          "display_name": "Engirdle English-Chinese Offline Dictionary",
          "size": 18,
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "url": "/dictionaries/engirdle-en-zh-r1-a1b2.dictpack"
        }""",
        encoding="utf-8",
    )

    catalog = Container.build(settings).publishing.regenerate_catalog(content_changed=True)
    client = TestClient(create_publisher_app(PublisherContainer.build(settings).publisher_queries))

    assert catalog.catalog_version == 2
    assert [entry.dictionary_id for entry in catalog.dictionaries] == ["engirdle-en-zh"]
    assert client.get(catalog.dictionaries[0].url).content == b"dictionary package"


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

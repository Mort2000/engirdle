"""SPA hosting tests for the admin web refactor (design §9/§12 step 3).

Uses a minimal fixture webui directory (``index.html`` plus a hashed-style
asset) instead of a real npm build to verify:

- the SPA fallback serves ``index.html`` via FileResponse with no-cache for
  ``/`` and client-side deep links (GET and HEAD alike);
- unknown ``/api`` paths stay JSON 404s under every method while
  wrong-method hits on real endpoints keep 405 (never the SPA shell);
- the transitional legacy Jinja pages stay reachable under ``/legacy``
  with their ``/static`` resources still mounted;
- ``/assets/*`` responses carry the immutable cache header;
- the webui resolver picks candidates in order and raises a readable
  startup error when both locations miss.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.entrypoints.admin_web.webui import resolve_webui_directory

SPA_MARKER = "<!-- fixture spa shell -->"
ASSET_NAME = "index-AbCd1234.js"


@pytest.fixture
def webui_dir(tmp_path: Path) -> Path:
    webui = tmp_path / "webui"
    (webui / "assets").mkdir(parents=True)
    (webui / "index.html").write_text(
        f"<!doctype html>\n{SPA_MARKER}\n", encoding="utf-8"
    )
    (webui / "assets" / ASSET_NAME).write_text("console.log('fixture');\n")
    return webui


def _make_client(
    tmp_path: Path, fake_translator: Any, fake_speech: Any, webui: Path
) -> TestClient:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
    )
    return TestClient(create_admin_app(container, webui_dir=webui))


def test_resolver_prefers_candidates_in_order(tmp_path: Path) -> None:
    packaged = tmp_path / "packaged-webui"
    dist = tmp_path / "source-dist"
    for directory in (packaged, dist):
        directory.mkdir()
        (directory / "index.html").write_text("x", encoding="utf-8")

    assert resolve_webui_directory([packaged, dist]) == packaged
    # The first candidate wins even when a later one also matches.
    (packaged / "index.html").unlink()
    assert resolve_webui_directory([packaged, dist]) == dist


def test_resolver_requires_index_html_not_bare_directory(tmp_path: Path) -> None:
    empty = tmp_path / "empty"
    empty.mkdir()

    with pytest.raises(RuntimeError):
        resolve_webui_directory([empty])


def test_missing_webui_raises_readable_startup_error(tmp_path: Path) -> None:
    first = tmp_path / "missing-packaged"
    second = tmp_path / "missing-dist"

    with pytest.raises(RuntimeError) as error:
        resolve_webui_directory([first, second])

    message = str(error.value)
    # Both recovery paths are spelled out: build from source or install a
    # prebuilt wheel; the checked locations are listed for diagnosis.
    assert "npm ci && npm run build" in message
    assert "wheel" in message
    assert str(first) in message
    assert str(second) in message


def test_spa_fallback_serves_index_html_without_caching(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    root = client.get("/")
    assert root.status_code == 200
    assert SPA_MARKER in root.text
    assert root.headers["cache-control"] == "no-cache"

    # Client-side deep links fall back to the same shell (design §5.1).
    deep_link = client.get("/jobs/0197-editor-picks")
    assert deep_link.status_code == 200
    assert SPA_MARKER in deep_link.text
    assert deep_link.headers["cache-control"] == "no-cache"

    # The OpenAPI schema keeps precedence over the catch-all.
    assert client.get("/openapi.json").status_code == 200


def test_api_404_passes_through_the_spa_fallback(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    missing = client.get("/api/definitely-not-a-route")
    assert missing.status_code == 404
    assert SPA_MARKER not in missing.text
    assert missing.json()["detail"] == "Not Found"


def test_unknown_api_paths_stay_404_under_every_method(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    """The all-method SPA fallback must not turn API misses into 405s."""
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    for request in (
        client.get("/api/definitely-not-a-route"),
        client.post("/api/definitely-not-a-route"),
        client.head("/api/definitely-not-a-route"),
        client.put("/api/definitely-not-a-route"),
    ):
        assert request.status_code == 404
        assert SPA_MARKER not in request.text


def test_wrong_method_on_real_api_route_keeps_405(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    """/api/health exists for GET only; other methods stay Method Not Allowed."""
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    assert client.get("/api/health").status_code == 200
    assert client.post("/api/health").status_code == 405
    assert client.head("/api/health").status_code == 405


def test_head_requests_serve_the_spa_shell(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    for path in ("/", "/jobs/0197-editor-picks"):
        response = client.head(path)
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-cache"


def test_legacy_index_redirects_to_trailing_slash(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    """/legacy (no slash) must reach the legacy workbench, not the SPA shell."""
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    redirect = client.get("/legacy", follow_redirects=False)
    assert redirect.status_code == 307
    assert redirect.headers["location"] == "/legacy/"

    followed = client.get("/legacy")
    assert followed.status_code == 200
    assert "内容生产端" in followed.text
    assert SPA_MARKER not in followed.text


def test_legacy_pages_stay_reachable_with_static_resources(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    dashboard = client.get("/legacy/")
    assert dashboard.status_code == 200
    assert "内容生产端" in dashboard.text

    entry = client.get("/legacy/articles/new")
    assert entry.status_code == 200

    voices = client.get("/legacy/voices")
    assert voices.status_code == 200

    # Legacy templates reference /static/admin.css absolutely; the mount
    # stays at the root so those pages keep working during the transition.
    stylesheet = client.get("/static/admin.css")
    assert stylesheet.status_code == 200


def test_hashed_assets_are_served_immutable(
    tmp_path: Path, webui_dir: Path, fake_translator: Any, fake_speech: Any
) -> None:
    client = _make_client(tmp_path, fake_translator, fake_speech, webui_dir)

    asset = client.get(f"/assets/{ASSET_NAME}")
    assert asset.status_code == 200
    assert "fixture" in asset.text
    assert asset.headers["cache-control"] == "public, max-age=31536000, immutable"

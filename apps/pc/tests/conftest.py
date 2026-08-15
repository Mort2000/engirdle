"""Root conftest for the engirdle-pc test suite.

Exposes deterministic ``fake_translator`` / ``fake_speech`` fixtures (the
relocated production stubs) so worker/acceptance tests can drive the production
pipeline without a DeepSeek API key, GPU, model weights or network access.

Also installs a session-wide fixture webui directory: most tests build the
admin app via ``create_admin_app(container)`` without an explicit
``webui_dir``, so the default resolver would otherwise require the
git-ignored ``admin_frontend/dist`` (or a packaged ``webui/``) to exist.
Pointing the default candidates at a minimal fixture keeps the whole suite
hermetic — a fresh clone passes ``uv sync && pytest`` without any npm build
(the hatch build hook lands in a later step) — while the production startup
error for missing artifacts stays unchanged.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest

from tests.speech_fake import StubSpeechAdapter
from tests.translation_fake import build_fake_translation_adapter


@pytest.fixture
def fake_translator():
    return build_fake_translation_adapter()


@pytest.fixture
def fake_speech():
    return StubSpeechAdapter()


@pytest.fixture(scope="session", autouse=True)
def _hermetic_webui(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Path]:
    """Serve default webui lookups from a fixture directory (no npm build)."""
    webui = tmp_path_factory.mktemp("webui-fixture")
    assets = webui / "assets"
    assets.mkdir()
    (webui / "index.html").write_text(
        "<!doctype html>\n<!-- fixture spa shell -->\n", encoding="utf-8"
    )
    (assets / "index-FixtureTest.js").write_text(
        "console.log('fixture');\n", encoding="utf-8"
    )

    from engirdle_pc.entrypoints.admin_web import webui as webui_module

    with pytest.MonkeyPatch.context() as monkeypatch:
        monkeypatch.setattr(
            webui_module, "default_webui_candidates", lambda: (webui,)
        )
        yield webui

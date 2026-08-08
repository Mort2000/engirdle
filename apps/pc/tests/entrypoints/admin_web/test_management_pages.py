from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app


def test_management_pages_support_article_entry_and_structure_review(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    client = TestClient(
        create_admin_app(
            Container.build(
                Settings(workspace=tmp_path / "workspace"),
                translation_adapter=fake_translator,
                speech_adapter=fake_speech,
            )
        )
    )

    dashboard = client.get("/")
    assert dashboard.status_code == 200
    assert "翻译与 TTS 当前为验证桩" in dashboard.text

    entry = client.get("/articles/new")
    assert entry.status_code == 200
    assert 'name="body"' in entry.text

    created = client.post(
        "/articles",
        data={
            "title": "Page flow",
            "body": "Review this sentence. Then approve it.",
            "license_name": "unknown",
        },
        follow_redirects=False,
    )
    assert created.status_code == 303
    structure_page = client.get(created.headers["location"])
    assert structure_page.status_code == 200
    assert "Review this sentence." in structure_page.text
    assert "确认结构并创建任务" in structure_page.text

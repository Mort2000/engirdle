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

    dashboard = client.get("/legacy/")
    assert dashboard.status_code == 200
    assert "翻译与 TTS 当前为验证桩" in dashboard.text

    entry = client.get("/legacy/articles/new")
    assert entry.status_code == 200
    assert 'name="body"' in entry.text

    created = client.post(
        "/legacy/articles",
        data={
            "title": "Page flow",
            "body": (
                "Review this sentence. Then approve it.\n\n"
                "| H1 | H2 |\n| - | - |\n| a | b |\n\n"
                "```js\nhidden = 42;\n```"
            ),
            "license_name": "unknown",
        },
        follow_redirects=False,
    )
    assert created.status_code == 303
    structure_page = client.get(created.headers["location"])
    assert structure_page.status_code == 200
    assert "Review this sentence." in structure_page.text
    assert "确认结构并创建任务" in structure_page.text
    # The structure page renders the derived processing counts and the
    # read-only structure tree with translate/narrate routing per block.
    assert "2 句待翻译" in structure_page.text
    assert "1 表待翻译" in structure_page.text
    assert "结构树" in structure_page.text
    assert "table" in structure_page.text
    assert "code" in structure_page.text

    # An unclosed fence forces the warning panel onto the structure page.
    warned = client.post(
        "/legacy/articles",
        data={
            "title": "Warned",
            "body": "Opening.\n\n```python\nnever closed",
            "license_name": "unknown",
        },
        follow_redirects=False,
    )
    assert warned.status_code == 303
    warned_page = client.get(warned.headers["location"])
    assert warned_page.status_code == 200
    assert "unclosed_code_fence" in warned_page.text
    assert "解析警告" in warned_page.text


def test_job_review_page_renders_table_translations_and_counts(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
    )
    client = TestClient(create_admin_app(container))
    article = client.post(
        "/api/articles",
        json={
            "title": "Job page",
            "body": (
                "Narratable sentence.\n\n"
                "| H1 | H2 |\n| - | - |\n| a | b |\n\n"
                "```js\nhidden = 42;\n```"
            ),
        },
    ).json()
    job_id = client.post(
        f"/api/articles/{article['article_id']}/revisions/1/approve"
    ).json()["job_id"]
    assert container.worker.run_once() is True

    page = client.get(f"/legacy/jobs/{job_id}")
    assert page.status_code == 200
    assert "播放此句" in page.text
    # Processing counters and the whole-table translation panel render.
    assert "处理计数" in page.text or "翻译句" in page.text
    assert "表格译文" in page.text
    table_block_id = next(
        block["block_id"] for block in article["blocks"] if block["kind"] == "table"
    )
    assert table_block_id in page.text
    cell_ids = [
        cell["cell_id"]
        for block in article["blocks"]
        if block["kind"] == "table"
        for row in block.get("rows", [])
        for cell in row
    ]
    assert all(cell_id in page.text for cell_id in cell_ids)
    # The code body never renders into the review page translations.
    assert "hidden = 42" not in page.text

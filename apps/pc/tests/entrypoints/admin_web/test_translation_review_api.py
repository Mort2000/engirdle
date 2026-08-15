"""Job review API under the markdown/unit pipeline (design §11.3).

Covers the typed translations list (sentence rows + whole-table rows, code
absent), the whole-table manual correction endpoint, and the audio review
listing narration ids only.
"""

from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app

MARKDOWN_BODY = (
    "# Review heading.\n\n"
    "Intro sentence with [a link](https://example.com/page).\n\n"
    "| H1 | H2 |\n| --- | :-: |\n| alpha | beta |\n\n"
    "```python\nprint('secret-code')\n```\n\n"
    "Final sentence."
)


def _ready_job(tmp_path: Path, fake_translator, fake_speech):
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
    )
    client = TestClient(create_admin_app(container))
    created = client.post(
        "/api/articles", json={"title": "Review flow", "body": MARKDOWN_BODY}
    ).json()
    job_id = client.post(
        f"/api/articles/{created['article_id']}/revisions/1/approve"
    ).json()["job_id"]
    assert container.worker.run_once() is True
    plan = container.content.processing_plan(created["article_id"], 1)
    return container, client, created, job_id, plan


def test_translations_list_is_typed_by_unit_kind(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    _container, client, created, job_id, plan = _ready_job(
        tmp_path, fake_translator, fake_speech
    )

    response = client.get(f"/api/jobs/{job_id}/translations")
    assert response.status_code == 200
    rows = response.json()

    sentence_rows = [row for row in rows if row["unit_kind"] == "sentence"]
    table_rows = [row for row in rows if row["unit_kind"] == "table"]
    assert len(table_rows) == len(plan.translation.table_units) == 1
    narratable_ids = list(plan.narration.sentence_ids)
    assert [row["sentence_id"] for row in sentence_rows] == narratable_ids
    for row in sentence_rows:
        assert set(row) >= {
            "unit_kind",
            "unit_id",
            "sentence_id",
            "source_text",
            "generated_text",
            "published_text",
        }
        assert row["published_text"].startswith("【翻译桩】")

    table_row = table_rows[0]
    table_block_id = plan.translation.table_units[0].block_id
    assert table_row["unit_id"] == table_block_id
    cell_ids = [cell["cell_id"] for cell in table_row["cells"]]
    assert cell_ids == list(plan.translation.table_units[0].cell_ids)
    # Generated, edited and published stay separate columns: before any human
    # edit the generated and published values agree and edited is null.
    assert all(cell["edited_text"] is None for cell in table_row["cells"])
    assert all(cell["published_text"] == cell["generated_text"] for cell in table_row["cells"])
    assert all(cell["published_text"].strip() for cell in table_row["cells"])

    # The code block has no translation unit and never appears in any row.
    code_ids = [
        block["block_id"]
        for block in created["blocks"]
        if block["kind"] == "code"
    ]
    serialized = repr(rows)
    for code_id in code_ids:
        assert code_id not in serialized
    assert "secret-code" not in serialized


def test_table_translation_edit_round_trip_and_validation(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    _container, client, _created, job_id, plan = _ready_job(
        tmp_path, fake_translator, fake_speech
    )
    table_block_id = plan.translation.table_units[0].block_id
    original = client.get(f"/api/jobs/{job_id}/translations").json()
    cells = next(
        row["cells"] for row in original if row["unit_kind"] == "table"
    )
    edited_cells = [
        {"cell_id": cell["cell_id"], "text_zh": f"改-{index}"}
        for index, cell in enumerate(cells)
    ]

    saved = client.put(
        f"/api/jobs/{job_id}/table-translations/{table_block_id}",
        json={"cells": edited_cells},
    )
    assert saved.status_code == 200
    assert saved.json()["block_id"] == table_block_id

    listed = client.get(f"/api/jobs/{job_id}/translations").json()
    table_row = next(row for row in listed if row["unit_kind"] == "table")
    # After the edit the generated column keeps the machine translation and
    # the edited/published columns carry the human correction.
    assert table_row["cells"][0]["edited_text"] == "改-0"
    assert table_row["cells"][0]["published_text"] == "改-0"
    assert table_row["cells"][0]["generated_text"].startswith("【译】")

    # Dropping a cell changes the shape and is rejected with 422.
    shape_mismatch = client.put(
        f"/api/jobs/{job_id}/table-translations/{table_block_id}",
        json={"cells": edited_cells[:-1]},
    )
    assert shape_mismatch.status_code == 422

    # An empty cell text is rejected with 422.
    emptied = [dict(cell) for cell in edited_cells]
    emptied[0]["text_zh"] = "   "
    empty_cell = client.put(
        f"/api/jobs/{job_id}/table-translations/{table_block_id}",
        json={"cells": emptied},
    )
    assert empty_cell.status_code == 422

    # An unknown table unit is a 404.
    missing = client.put(
        f"/api/jobs/{job_id}/table-translations/no-such-block",
        json={"cells": edited_cells},
    )
    assert missing.status_code == 404


def test_sentence_translation_edit_updates_published_text(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    _container, client, _created, job_id, plan = _ready_job(
        tmp_path, fake_translator, fake_speech
    )
    sentence_id = plan.narration.sentence_ids[0]

    edited = client.put(
        f"/api/jobs/{job_id}/translations/{sentence_id}",
        json={"text_zh": "人工改定的第一句。"},
    )
    assert edited.status_code == 200

    rows = client.get(f"/api/jobs/{job_id}/translations").json()
    row = next(
        row for row in rows if row.get("sentence_id") == sentence_id
    )
    assert row["published_text"] == "人工改定的第一句。"


def test_audio_review_lists_narration_ids_only(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    _container, client, created, job_id, plan = _ready_job(
        tmp_path, fake_translator, fake_speech
    )

    response = client.get(f"/api/jobs/{job_id}/audio")
    assert response.status_code == 200
    payload = response.json()
    assert [item["sentence_id"] for item in payload["sentences"]] == list(
        plan.narration.sentence_ids
    )
    assert payload["checks"] == {
        "missing_sentence_ids": [],
        "zero_duration_sentence_ids": [],
        "abnormal_duration_sentence_ids": [],
    }
    # Tables and code have no narration unit, so they never appear as audio.
    non_narratable_ids = {
        block["block_id"]
        for block in created["blocks"]
        if block["kind"] in {"table", "code", "divider"}
    }
    timing_ids = {item["sentence_id"] for item in payload["sentences"]}
    assert not (timing_ids & non_narratable_ids)

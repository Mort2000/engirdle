"""API-level critical-flow coverage for the admin web (design §12 step 6).

Replaces the former server-rendered page-flow test now that the SPA owns
the page layer: the entry → structure confirmation → review → publish
chain is asserted end to end against the JSON API alone.

Division of labour with the neighbouring modules (no duplicated
semantics): granular per-endpoint assertions live in
``test_admin_api_additions`` / ``test_translation_review_api`` /
``test_structure_editor_api``; presentation-level behaviour (entry form,
per-sentence playback buttons, confirmation dialogs) is covered by the
frontend component tests under ``admin_frontend/src/features``.
"""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app

FLOW_BODY = (
    "Review this sentence. Then approve it.\n\n"
    "| H1 | H2 |\n| - | - |\n| a | b |\n\n"
    "```js\nhidden = 42;\n```"
)


def test_entry_structure_confirmation_review_and_publish_flow(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
    )
    client = TestClient(create_admin_app(container))

    # Entry: the markdown body freezes into a typed revision (the old form
    # flow posted the same fields to a page route).
    created = client.post(
        "/api/articles", json={"title": "Critical flow", "body": FLOW_BODY}
    )
    assert created.status_code == 201
    article = created.json()
    assert [block["kind"] for block in article["blocks"]] == [
        "paragraph",
        "table",
        "code",
    ]

    # Structure confirmation inputs: the derived tree and processing
    # counters the structure page used to render (2 sentences, 1 table,
    # the code block skipped) before the user approves.
    report = client.get(
        f"/api/articles/{article['article_id']}/revisions/1/structure-report"
    ).json()
    assert [entry["kind"] for entry in report["structure_tree"]] == [
        "paragraph",
        "table",
        "code",
    ]
    assert report["processing_counts"] == {
        "translated_sentences": 2,
        "translated_tables": 1,
        "skipped_code_blocks": 1,
        "narrated_sentences": 2,
    }

    # Approve freezes the structure and queues the production job.
    approved = client.post(
        f"/api/articles/{article['article_id']}/revisions/1/approve"
    )
    assert approved.status_code == 202
    job_id = approved.json()["job_id"]
    assert container.worker.run_once() is True

    # Review: the job waits for a human; the typed translation list
    # carries both sentence rows and the whole-table row with its cells,
    # while the code body never leaks into any review payload.
    job = client.get(f"/api/jobs/{job_id}")
    assert job.json()["status"] == "review_required"

    translations = client.get(f"/api/jobs/{job_id}/translations").json()
    sentence_rows = [row for row in translations if row["unit_kind"] == "sentence"]
    assert len(sentence_rows) == 2
    table_rows = [row for row in translations if row["unit_kind"] == "table"]
    assert len(table_rows) == 1
    assert all(cell["generated_text"] for cell in table_rows[0]["cells"])
    assert "hidden = 42" not in repr(translations)

    # Audio review data behind the per-sentence playback: timings for the
    # narration sentences only, with no missing sentences.
    audio = client.get(f"/api/jobs/{job_id}/audio").json()
    assert [item["sentence_id"] for item in audio["sentences"]] == [
        row["sentence_id"] for row in sentence_rows
    ]
    assert all(
        item["start_ms"] <= item["end_ms"] for item in audio["sentences"]
    )
    assert audio["checks"]["missing_sentence_ids"] == []

    # Publish produces an immutable artifact, and the workbench aggregate
    # surfaces both the publication and artifact revision 1.
    published = client.post(f"/api/jobs/{job_id}/publish")
    assert published.status_code == 201
    package = published.json()

    summary = client.get("/api/dashboard/summary").json()
    assert [item["package_id"] for item in summary["published"]] == [
        package["package_id"]
    ]
    assert summary["published"][0]["artifact_revision"] == 1
    assert [item["package_id"] for item in summary["artifacts"]] == [
        package["package_id"]
    ]
    assert summary["artifacts"][0]["state"] == "published"

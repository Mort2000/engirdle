"""Tests for the API additions of the admin web refactor (design §8.5).

- ``GET /api/jobs`` and ``GET /api/jobs/{job_id}`` carry the derived
  ``progress`` field, isomorphic with the SSE payloads;
- ``GET /api/articles/{id}/revisions/{rev}/structure-report`` returns the
  warnings, the derived structure tree and the processing counts;
- ``GET /api/dashboard/summary`` aggregates the workbench in one call.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app

ARTICLE_BODY = (
    "Narratable sentence one. Narratable sentence two.\n\n"
    "| H1 | H2 |\n| - | - |\n| a | b |\n\n"
    "```js\nhidden = 42;\n```\n\n"
    "---\n"
)


def _make_client(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> tuple[Container, TestClient]:
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
    )
    return container, TestClient(create_admin_app(container))


def _create_article(client: TestClient, body: str) -> dict[str, Any]:
    return client.post(
        "/api/articles", json={"title": "Additions", "body": body}
    ).json()


def test_job_detail_and_list_carry_derived_progress(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    container, client = _make_client(tmp_path, fake_translator, fake_speech)
    article = _create_article(client, "One sentence to narrate. Another one.")
    job_id = client.post(
        f"/api/articles/{article['article_id']}/revisions/1/approve"
    ).json()["job_id"]

    queued = client.get(f"/api/jobs/{job_id}").json()
    assert queued["progress"] == {
        "stage": "queued",
        "stage_index": 0,
        "percent": 0.0,
        "done_units": None,
        "total_units": None,
        "indeterminate": True,
    }

    container.worker.run_once()
    reviewed = client.get(f"/api/jobs/{job_id}").json()
    assert reviewed["status"] == "review_required"
    assert reviewed["progress"]["stage"] == "review"
    assert reviewed["progress"]["stage_index"] == 4
    assert reviewed["progress"]["percent"] == 97.0
    assert reviewed["progress"]["indeterminate"] is False

    jobs = client.get("/api/jobs").json()
    matching = [job for job in jobs if job["job_id"] == job_id]
    assert len(matching) == 1
    assert matching[0]["progress"] == reviewed["progress"]
    # Every listed job carries progress, isomorphic with the detail view.
    assert all("progress" in job for job in jobs)


def test_structure_report_returns_warnings_tree_and_counts(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    _container, client = _make_client(tmp_path, fake_translator, fake_speech)
    article = _create_article(client, ARTICLE_BODY)

    report = client.get(
        f"/api/articles/{article['article_id']}/revisions/1/structure-report"
    ).json()
    assert report["article_id"] == article["article_id"]
    assert report["revision"] == 1
    assert report["warnings"] == []

    tree = report["structure_tree"]
    assert [entry["kind"] for entry in tree] == [
        "paragraph",
        "table",
        "code",
        "divider",
    ]
    paragraph, table, code, divider = tree
    assert paragraph["translates"] is True
    assert paragraph["narrates"] is True
    assert paragraph["sentence_count"] == 2
    assert table["translates"] is True
    assert table["narrates"] is False
    assert code["translates"] is False
    assert code["narrates"] is False
    assert divider["translates"] is False
    assert divider["narrates"] is False

    assert report["processing_counts"] == {
        "translated_sentences": 2,
        "translated_tables": 1,
        "skipped_code_blocks": 1,
        "narrated_sentences": 2,
    }

    missing = client.get("/api/articles/unknown/revisions/1/structure-report")
    assert missing.status_code == 404


def test_structure_report_surfaces_parse_warnings(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    _container, client = _make_client(tmp_path, fake_translator, fake_speech)
    article = _create_article(client, "Opening.\n\n```python\nnever closed")

    report = client.get(
        f"/api/articles/{article['article_id']}/revisions/1/structure-report"
    ).json()
    assert report["warnings"] == [
        {
            "code": "unclosed_code_fence",
            "message": report["warnings"][0]["message"],
        }
    ]
    assert report["warnings"][0]["message"]


def test_dashboard_summary_aggregates_workbench_state(
    tmp_path: Path, fake_translator: Any, fake_speech: Any
) -> None:
    container, client = _make_client(tmp_path, fake_translator, fake_speech)
    article = _create_article(client, "Summary sentence to produce.")
    job_id = client.post(
        f"/api/articles/{article['article_id']}/revisions/1/approve"
    ).json()["job_id"]
    assert container.worker.run_once() is True
    published = client.post(f"/api/jobs/{job_id}/publish").json()

    summary = client.get("/api/dashboard/summary").json()
    assert [item["article_id"] for item in summary["articles"]] == [
        article["article_id"]
    ]
    assert summary["articles"][0]["status"] == "published"
    assert summary["articles"][0]["title"] == "Additions"

    jobs = [job for job in summary["jobs"] if job["job_id"] == job_id]
    assert len(jobs) == 1
    assert jobs[0]["status"] == "succeeded"
    assert jobs[0]["progress"]["stage"] == "complete"
    assert jobs[0]["progress"]["percent"] == 100.0

    assert [item["package_id"] for item in summary["published"]] == [
        published["package_id"]
    ]
    published_entry = summary["published"][0]
    assert published_entry["size"] == published["size"]
    assert published_entry["sha256"] == published["sha256"]
    assert published_entry["published_at"]

    assert [item["package_id"] for item in summary["artifacts"]] == [
        published["package_id"]
    ]
    assert summary["artifacts"][0]["state"] == "published"

    assert summary["publisher"]["running"] is False
    assert summary["publisher"]["binding_host"]
    assert summary["catalog_available"] is True
    # The stub adapters flag the verification-mode badge (same semantics as
    # the legacy Jinja dashboard).
    assert summary["verification_mode"] is True

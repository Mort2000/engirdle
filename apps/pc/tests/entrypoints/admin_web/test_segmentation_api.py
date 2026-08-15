from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app


def test_candidate_structure_handles_abbreviations_lists_and_dialogue_tags(
    tmp_path: Path,
) -> None:
    client = TestClient(
        create_admin_app(Container.build(Settings(workspace=tmp_path / "workspace")))
    )
    response = client.post(
        "/api/articles",
        json={
            "title": "Segmentation",
            "body": (
                "Dr. A. Rivera reviewed version 2.1. It worked well.\n\n"
                "- First item.\n- Second item!\n\n"
                '> "Are we ready?" she asked.'
            ),
        },
    )
    assert response.status_code == 201
    blocks = response.json()["blocks"]
    assert [block["kind"] for block in blocks] == [
        "paragraph",
        "list_item",
        "list_item",
        "quote",
    ]
    assert [item["text"] for item in blocks[0]["sentences"]] == [
        "Dr. A. Rivera reviewed version 2.1.",
        "It worked well.",
    ]
    assert [item["text"] for item in blocks[3]["sentences"]] == [
        '"Are we ready?" she asked.'
    ]


def test_markdown_inline_runs_are_projected_into_block_views(
    tmp_path: Path,
) -> None:
    client = TestClient(
        create_admin_app(Container.build(Settings(workspace=tmp_path / "workspace")))
    )
    response = client.post(
        "/api/articles",
        json={
            "title": "Runs",
            "body": (
                "A sentence with *emphasis* and [a link](https://example.com/x) "
                "plus `inline_code` inside."
            ),
        },
    )
    assert response.status_code == 201
    paragraph = response.json()["blocks"][0]
    assert paragraph["kind"] == "paragraph"
    runs = paragraph["sentences"][0]["runs"]
    assert [(run["kind"], run["text"]) for run in runs][:3] == [
        ("plain", "A sentence with "),
        ("emphasis", "emphasis"),
        ("plain", " and "),
    ]
    link_run = next(run for run in runs if run["kind"] == "link")
    assert link_run["text"] == "a link"
    assert link_run["href"] == "https://example.com/x"
    code_run = next(run for run in runs if run["kind"] == "code")
    assert code_run["text"] == "inline_code"
    # Runs always concatenate to the visible sentence text.
    assert "".join(run["text"] for run in runs) == paragraph["sentences"][0]["text"]


def test_raw_and_normalized_source_hashes_are_independently_traceable(
    tmp_path: Path,
) -> None:
    client = TestClient(
        create_admin_app(Container.build(Settings(workspace=tmp_path / "workspace")))
    )
    created = client.post(
        "/api/articles",
        json={"title": "Hashes", "body": "“Hello”\r\n\r\nWorld."},
    )
    assert created.status_code == 201
    assert (
        created.json()["source_sha256"]
        == "2ad5880b2730e5e26a388423fe9c0ff6454b726676562f3d20f70ac215d0669b"
    )
    # The normalized hash covers the canonical markdown, where ONLY line
    # endings are unified (design §8.1) - smart quotes survive into the stored
    # canonical text but are projected away from the visible sentence text.
    assert (
        created.json()["normalized_sha256"]
        == "b0b6ec75d2d72dd8b7931524c014551caf5828c81c5c63a3e9be11bec39a2a44"
    )
    sentence_texts = [
        sentence["text"]
        for block in created.json()["blocks"]
        for sentence in block["sentences"]
    ]
    assert sentence_texts == ['"Hello"', "World."]

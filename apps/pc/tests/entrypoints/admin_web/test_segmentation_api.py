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
    assert (
        created.json()["normalized_sha256"]
        == "77e0aab8d25ab05f8066432f3b2bc8f559a356e1b9a6ada17dde963f4757221f"
    )

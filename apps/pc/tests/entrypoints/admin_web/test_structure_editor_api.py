from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app

MARKDOWN_BODY = (
    "# Heading one.\n\n"
    "Intro sentence. Another sentence here.\n\n"
    "| H1 | H2 |\n| --- | :-: |\n| a | b |\n\n"
    "```python\nprint('hi')\n```\n\n"
    "---\n\n"
    "Final sentence."
)


def _client(tmp_path: Path, fake_speech) -> TestClient:
    return TestClient(
        create_admin_app(
            Container.build(
                Settings(workspace=tmp_path / "workspace"),
                speech_adapter=fake_speech,
            )
        )
    )


def test_user_can_replace_structure_until_revision_is_approved(
    tmp_path: Path, fake_speech
) -> None:
    client = _client(tmp_path, fake_speech)
    created = client.post(
        "/api/articles", json={"title": "Editable", "body": "One. Two.\n\n- Three."}
    ).json()
    article_id = created["article_id"]

    edited = client.put(
        f"/api/articles/{article_id}/revisions/1/structure",
        json={
            "blocks": [
                {
                    "block_id": created["blocks"][1]["block_id"],
                    "kind": "list_item",
                    "list_kind": "bullet",
                    "sentences": [
                        {
                            "sentence_id": created["blocks"][1]["sentences"][0][
                                "sentence_id"
                            ],
                            "text": "Three, moved first.",
                        }
                    ],
                },
                {
                    "kind": "paragraph",
                    "sentences": [{"text": "One and two were merged."}],
                },
            ]
        },
    )
    assert edited.status_code == 200
    assert [block["kind"] for block in edited.json()["blocks"]] == [
        "list_item",
        "paragraph",
    ]
    assert edited.json()["structure_sha256"] != created["structure_sha256"]

    approved = client.post(f"/api/articles/{article_id}/revisions/1/approve")
    assert approved.status_code == 202
    rejected = client.put(
        f"/api/articles/{article_id}/revisions/1/structure",
        json={"blocks": [{"kind": "paragraph", "sentences": [{"text": "Too late."}]}]},
    )
    assert rejected.status_code == 409


def test_structure_editor_accepts_the_full_block_union(tmp_path: Path, fake_speech) -> None:
    client = _client(tmp_path, fake_speech)
    created = client.post(
        "/api/articles", json={"title": "Union", "body": MARKDOWN_BODY}
    ).json()
    article_id = created["article_id"]

    edited = client.put(
        f"/api/articles/{article_id}/revisions/1/structure",
        json={
            "blocks": [
                {
                    "kind": "heading",
                    "level": 2,
                    "sentences": [{"text": "A smaller heading."}],
                },
                {
                    "kind": "paragraph",
                    "sentences": [{"text": "Merged intro sentence."}],
                },
                {
                    "kind": "table",
                    "alignments": ["left", "right"],
                    "header": ["列一", "列二"],
                    "rows": [["甲", "乙"]],
                },
                {
                    "kind": "code",
                    "language": "javascript",
                    "code": "console.log('edited');\n",
                },
                {"kind": "divider"},
                {
                    "kind": "quote",
                    "quote_depth": 2,
                    "sentences": [{"text": "A quoted line."}],
                },
                {
                    "kind": "list_item",
                    "list_kind": "ordered",
                    "list_depth": 1,
                    "list_ordinal": 1,
                    "sentences": [{"text": "An ordered item."}],
                },
            ]
        },
    )
    assert edited.status_code == 200
    payload = edited.json()
    assert [block["kind"] for block in payload["blocks"]] == [
        "heading",
        "paragraph",
        "table",
        "code",
        "divider",
        "quote",
        "list_item",
    ]
    by_kind = {block["kind"]: block for block in payload["blocks"]}
    assert by_kind["heading"]["level"] == 2
    assert by_kind["table"]["alignments"] == ["left", "right"]
    # Manually edited cells carry the plain-run default so the packaging
    # validator's runs-concatenation rule holds (edit → publish end to end).
    assert by_kind["table"]["header"] == [
        {
            "cell_id": "cell-1",
            "text": "列一",
            "runs": [{"kind": "plain", "text": "列一", "href": None}],
        },
        {
            "cell_id": "cell-2",
            "text": "列二",
            "runs": [{"kind": "plain", "text": "列二", "href": None}],
        },
    ]
    assert by_kind["code"]["language"] == "javascript"
    assert by_kind["code"]["code"] == "console.log('edited');\n"
    assert by_kind["quote"]["quote_depth"] == 2
    assert by_kind["list_item"]["list_kind"] == "ordered"
    assert payload["structure_sha256"] != created["structure_sha256"]
    # Block and cell identities are unique across the union.
    block_ids = [block["block_id"] for block in payload["blocks"]]
    assert len(block_ids) == len(set(block_ids))
    cell_ids = [cell["cell_id"] for cell in by_kind["table"]["header"]]
    cell_ids += [
        cell["cell_id"] for row in by_kind["table"]["rows"] for cell in row
    ]
    assert len(cell_ids) == len(set(cell_ids))


def test_structure_editor_rejects_kind_and_payload_disagreements(
    tmp_path: Path, fake_speech
) -> None:
    client = _client(tmp_path, fake_speech)
    created = client.post(
        "/api/articles", json={"title": "Invalid", "body": MARKDOWN_BODY}
    ).json()
    article_id = created["article_id"]
    endpoint = f"/api/articles/{article_id}/revisions/1/structure"

    # Alignment count disagrees with the header width.
    mismatched_table = client.put(
        endpoint,
        json={
            "blocks": [
                {
                    "kind": "table",
                    "alignments": ["left"],
                    "header": ["one", "two"],
                    "rows": [["a", "b"]],
                }
            ]
        },
    )
    assert mismatched_table.status_code == 422

    # A text kind without sentences cannot exist.
    empty_paragraph = client.put(
        endpoint,
        json={"blocks": [{"kind": "paragraph", "sentences": []}]},
    )
    assert empty_paragraph.status_code == 422

    # A code block needs a non-empty body.
    empty_code = client.put(
        endpoint,
        json={"blocks": [{"kind": "code", "code": ""}]},
    )
    assert empty_code.status_code == 422

    # Duplicate provided block ids are rejected.
    duplicated = client.put(
        endpoint,
        json={
            "blocks": [
                {
                    "block_id": "block-1",
                    "kind": "paragraph",
                    "sentences": [{"text": "One."}],
                },
                {
                    "block_id": "block-1",
                    "kind": "paragraph",
                    "sentences": [{"text": "Two."}],
                },
            ]
        },
    )
    assert duplicated.status_code == 422

from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app


def test_user_can_replace_structure_until_revision_is_approved(
    tmp_path: Path, fake_speech
) -> None:
    client = TestClient(
        create_admin_app(
            Container.build(
                Settings(workspace=tmp_path / "workspace"),
                speech_adapter=fake_speech,
            )
        )
    )
    created = client.post(
        "/api/articles",
        json={"title": "Editable", "body": "One. Two.\n\n- Three."},
    ).json()
    article_id = created["article_id"]

    edited = client.put(
        f"/api/articles/{article_id}/revisions/1/structure",
        json={
            "blocks": [
                {
                    "block_id": created["blocks"][1]["block_id"],
                    "kind": "list_item",
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

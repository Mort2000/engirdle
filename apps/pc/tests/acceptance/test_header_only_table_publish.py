"""End-to-end regression: a header-only table must survive publishing.

A markdown table with a header row and no data rows is legal; the packaged
article then carries `"rows": []`. The wire schema REQUIRES `rows` for table
blocks, so the packager must keep the empty key (an earlier stripper dropped
all empty lists and made PC-built packages fail their own schema).
"""

from __future__ import annotations

import json
from pathlib import Path
from zipfile import ZipFile

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.modules.packaging.infrastructure.validator import ReadpackValidator

BODY = (
    "An intro sentence.\n\n"
    "| Only | Header |\n"
    "| --- | --- |\n\n"
    "A closing sentence.\n"
)


def test_header_only_table_publishes_and_validates(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    settings = Settings(workspace=tmp_path / "workspace")
    container = Container.build(
        settings,
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
    )
    admin = TestClient(create_admin_app(container))

    created = admin.post(
        "/api/articles",
        json={"title": "Header Only", "body": BODY, "license_name": "CC0-1.0"},
    )
    assert created.status_code == 201
    revision = created.json()
    assert [block["kind"] for block in revision["blocks"]] == [
        "paragraph",
        "table",
        "paragraph",
    ]
    table = revision["blocks"][1]
    assert table["rows"] == []  # header-only: no data rows

    job_id = admin.post(
        f"/api/articles/{revision['article_id']}/revisions/1/approve"
    ).json()["job_id"]
    assert container.worker.run_once() is True
    published = admin.post(f"/api/jobs/{job_id}/publish")
    assert published.status_code == 201

    # Download the published artifact through the read-only publisher and
    # re-validate it with the shared validator, which requires the table's
    # `rows` key to exist even when empty.
    from engirdle_pc.entrypoints.publisher.app import create_publisher_app

    publisher = TestClient(create_publisher_app(container.publisher_queries))
    catalog_item = publisher.get("/catalog.json").json()["packages"][0]
    package_response = publisher.get(catalog_item["url"])
    assert package_response.status_code == 200
    package_path = tmp_path / "downloaded.readpack"
    package_path.write_bytes(package_response.content)
    ReadpackValidator(settings.contracts_dir).validate(package_path)

    with ZipFile(package_path) as archive:
        article = json.loads(archive.read("article.json"))
    packaged_table = next(b for b in article["blocks"] if b["kind"] == "table")
    assert packaged_table["header"] == [
        {"cell_id": "cell-2-0", "text": "Only", "runs": [
            {"kind": "plain", "text": "Only"}
        ]},
        {"cell_id": "cell-2-1", "text": "Header", "runs": [
            {"kind": "plain", "text": "Header"}
        ]},
    ]
    assert packaged_table["rows"] == []
    assert set(packaged_table["translation_zh"]) == {
        "cell-2-0",
        "cell-2-1",
    }

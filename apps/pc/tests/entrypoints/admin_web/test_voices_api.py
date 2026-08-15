from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.modules.speech.public import SpeechGenerationError
from tests.speech_fake import FakeAnchorEngine


def _client(tmp_path: Path, engine: FakeAnchorEngine, fake_translator, fake_speech):
    container = Container.build(
        Settings(workspace=tmp_path / "workspace"),
        translation_adapter=fake_translator,
        speech_adapter=fake_speech,
        anchor_engine=engine,
    )
    return TestClient(create_admin_app(container))


def test_anchor_batch_audition_confirm_and_activate_flow(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    client = _client(tmp_path, FakeAnchorEngine(), fake_translator, fake_speech)

    speakers = client.get("/api/voices/speakers")
    assert speakers.status_code == 200
    assert {item["name"] for item in speakers.json()} == {"Ryan", "Aiden"}

    created = client.post(
        "/api/voices/batches",
        json={
            "speaker": "Ryan",
            "anchor_text": "An English anchor sentence read aloud.",
            "instruct": "Calm, steady narration.",
            "seed": 5,
            "count": 2,
        },
    )
    assert created.status_code == 201
    batch = created.json()
    assert batch["custom_voice_model"].endswith("@fake")
    assert [c["seed"] for c in batch["candidates"]] == [5, 6]

    audio = client.get(f"/api/voices/batches/{batch['batch_id']}/audio/1")
    assert audio.status_code == 200
    assert audio.content[:4] == b"RIFF"
    assert client.get(f"/api/voices/batches/{batch['batch_id']}/audio/99").status_code == 404

    confirmed = client.post(
        f"/api/voices/batches/{batch['batch_id']}/confirm/1", json={}
    )
    assert confirmed.status_code == 201
    profile = confirmed.json()
    assert profile["revision"] == 1
    assert profile["is_active"] is True
    assert profile["seed"] == 6
    assert profile["speaker"] == "Ryan"

    anchor_audio = client.get(
        f"/api/voices/profiles/{profile['voice_profile_id']}/1/audio"
    )
    assert anchor_audio.status_code == 200
    assert anchor_audio.content[:4] == b"RIFF"

    # A second confirmation on the same profile creates revision 2 and activates it.
    second = client.post(
        f"/api/voices/batches/{batch['batch_id']}/confirm/0",
        json={"voice_profile_id": profile["voice_profile_id"]},
    )
    assert second.status_code == 201
    assert second.json()["revision"] == 2

    profiles = client.get("/api/voices/profiles").json()
    assert [(p["revision"], p["is_active"]) for p in profiles] == [(2, True), (1, False)]

    activated = client.post(
        f"/api/voices/profiles/{profile['voice_profile_id']}/1/activate"
    )
    assert activated.status_code == 200
    assert activated.json()["is_active"] is True

    # Server-rendered pages stay in sync with the API.
    assert client.get("/legacy/voices").status_code == 200
    assert client.get("/legacy/voices/new").status_code == 200
    audition = client.get(f"/legacy/voices/batches/{batch['batch_id']}")
    assert audition.status_code == 200
    assert "An English anchor sentence read aloud." in audition.text


def test_voices_api_rejects_invalid_requests(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    client = _client(tmp_path, FakeAnchorEngine(), fake_translator, fake_speech)

    bad_speaker = client.post(
        "/api/voices/batches",
        json={"speaker": "Vivian", "anchor_text": "Hello there.", "count": 1},
    )
    assert bad_speaker.status_code == 422

    assert client.get("/api/voices/batches/missing").status_code == 404
    missing_confirm = client.post("/api/voices/batches/missing/confirm/0", json={})
    assert missing_confirm.status_code == 404
    missing_activate = client.post("/api/voices/profiles/missing/1/activate")
    assert missing_activate.status_code == 404


def test_confirm_rejects_path_traversal_profile_id(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    engine = FakeAnchorEngine()
    client = _client(tmp_path, engine, fake_translator, fake_speech)
    created = client.post(
        "/api/voices/batches",
        json={
            "speaker": "Ryan",
            "anchor_text": "An English anchor sentence read aloud.",
            "seed": 0,
            "count": 1,
        },
    )
    batch_id = created.json()["batch_id"]

    traversal = client.post(
        f"/api/voices/batches/{batch_id}/confirm/0",
        json={"voice_profile_id": "../../escaped"},
    )

    assert traversal.status_code == 422
    assert not (tmp_path / "escaped").exists()
    assert not (tmp_path / "workspace" / "escaped").exists()


def test_engine_failure_maps_to_500_with_detail(
    tmp_path: Path, fake_translator, fake_speech
) -> None:
    engine = FakeAnchorEngine()
    engine.failure = SpeechGenerationError("GPU is on fire")
    client = _client(tmp_path, engine, fake_translator, fake_speech)

    response = client.post(
        "/api/voices/batches",
        json={
            "speaker": "Ryan",
            "anchor_text": "An English anchor sentence read aloud.",
            "seed": 0,
            "count": 1,
        },
    )

    assert response.status_code == 500
    assert response.json()["detail"] == "GPU is on fire"

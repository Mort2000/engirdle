import pytest
from pydantic import ValidationError

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.modules.speech.infrastructure.qwen3_adapter import build_qwen3_speech_adapter
from tests.speech_fake import FakeQwen3Backend


def test_batch_size_default_environment_override_and_factory(monkeypatch, tmp_path):
    monkeypatch.delenv("ENGIRDLE_SPEECH_BATCH_SIZE", raising=False)
    assert Settings().speech_batch_size == 4
    monkeypatch.setenv("ENGIRDLE_SPEECH_BATCH_SIZE", "2")
    settings = Settings(workspace=tmp_path)
    adapter = build_qwen3_speech_adapter(settings, None, backend=FakeQwen3Backend())
    assert adapter.batch_size == 2


@pytest.mark.parametrize("value", ["0", "-1", "2.5", "invalid"])
def test_batch_size_rejects_invalid_environment_values(monkeypatch, value):
    monkeypatch.setenv("ENGIRDLE_SPEECH_BATCH_SIZE", value)
    with pytest.raises(ValidationError):
        Settings()

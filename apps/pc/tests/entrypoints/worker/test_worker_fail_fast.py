"""The worker entrypoint must fail fast (exit non-zero) when providers are unusable.

This guards the "未提供或无效直接报错退出" requirement: a missing or rejected API
key — or a broken Qwen3-TTS runtime — must stop the worker at startup rather
than silently queueing jobs that can never finish.
"""

from __future__ import annotations

import pytest

from engirdle_pc.entrypoints.worker import main as worker_main
from engirdle_pc.modules.speech.public import SpeechConfigurationError
from engirdle_pc.modules.translation.public import TranslationAuthError


class _SpeechOk:
    def verify_setup(self) -> None:
        return None


def test_worker_exits_when_api_key_missing(monkeypatch) -> None:
    monkeypatch.setattr(worker_main, "load_deepseek_api_key", lambda: None)

    with pytest.raises(SystemExit) as exc_info:
        worker_main.main()

    assert exc_info.value.code == 1


def test_worker_exits_when_access_check_fails(monkeypatch) -> None:
    monkeypatch.setattr(worker_main, "load_deepseek_api_key", lambda: "rejected-key")

    class _Translations:
        def verify_access(self) -> None:
            raise TranslationAuthError("provider rejected the key")

    class _FakeContainer:
        def __init__(self) -> None:
            self.translations = _Translations()
            self.speech = _SpeechOk()

    class _ContainerStub:
        @staticmethod
        def build(*_args, **_kwargs):
            return _FakeContainer()

    monkeypatch.setattr(worker_main, "Container", _ContainerStub)

    with pytest.raises(SystemExit) as exc_info:
        worker_main.main()

    assert exc_info.value.code == 1


def test_worker_exits_when_speech_setup_fails(monkeypatch) -> None:
    monkeypatch.setattr(worker_main, "load_deepseek_api_key", lambda: "valid-key")

    class _Translations:
        def verify_access(self) -> None:
            return None

    class _Speech:
        def verify_setup(self) -> None:
            raise SpeechConfigurationError("checkpoints missing")

    class _FakeContainer:
        def __init__(self) -> None:
            self.translations = _Translations()
            self.speech = _Speech()

    class _ContainerStub:
        @staticmethod
        def build(*_args, **_kwargs):
            return _FakeContainer()

    monkeypatch.setattr(worker_main, "Container", _ContainerStub)

    with pytest.raises(SystemExit) as exc_info:
        worker_main.main()

    assert exc_info.value.code == 1

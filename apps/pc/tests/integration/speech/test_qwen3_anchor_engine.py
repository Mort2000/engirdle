from __future__ import annotations

from pathlib import Path

import pytest

pytest.importorskip("soundfile", reason="tts extra not installed")

from engirdle_pc.modules.speech.domain.models import InvalidAnchorRequest
from engirdle_pc.modules.speech.infrastructure.qwen3_custom_voice import (
    Qwen3AnchorEngine,
)
from tests.speech_fake import FakeQwen3Backend


def _engine(backend: FakeQwen3Backend, tmp_path: Path) -> Qwen3AnchorEngine:
    return Qwen3AnchorEngine(backend, custom_voice_dir=tmp_path, max_new_tokens=64)


def test_generate_candidates_maps_display_name_to_checkpoint_id(
    tmp_path: Path,
) -> None:
    backend = FakeQwen3Backend()
    engine = _engine(backend, tmp_path)
    generated = engine.generate_candidates(
        speaker="Ryan",
        anchor_text="Every word of this anchor is read aloud.",
        instruct="Calm.",
        seed=5,
        count=2,
        target_dir=tmp_path / "out",
    )
    assert len(generated) == 2
    # The checkpoint reports lowercase ids; the engine must pass the canonical
    # id through instead of the public display name.
    assert [call["speaker"] for call in backend.custom_voice_calls] == [
        "ryan",
        "ryan",
    ]
    assert backend.seeds == [5, 6]
    assert backend.unload_calls == 1


def test_generate_candidates_rejects_speaker_not_served_by_checkpoint(
    tmp_path: Path,
) -> None:
    backend = FakeQwen3Backend()
    engine = _engine(backend, tmp_path)
    with pytest.raises(InvalidAnchorRequest, match="Vivian"):
        engine.generate_candidates(
            speaker="Vivian",
            anchor_text="text",
            instruct="",
            seed=0,
            count=1,
            target_dir=tmp_path / "out",
        )
    assert backend.unload_calls == 1


def test_concurrent_batches_are_serialized(tmp_path: Path) -> None:
    # Admin endpoints share one engine on a thread pool; set_seed mutates
    # process-global RNG and only one checkpoint may be resident, so two
    # overlapping requests must never interleave generation.
    import threading
    import time

    class SlowBackend(FakeQwen3Backend):
        def __init__(self) -> None:
            super().__init__()
            self.active = 0
            self.max_active = 0
            self._guard = threading.Lock()

        def generate_custom_voice(self, **kwargs: object) -> object:
            with self._guard:
                self.active += 1
                self.max_active = max(self.max_active, self.active)
            try:
                time.sleep(0.05)
                return super().generate_custom_voice(**kwargs)
            finally:
                with self._guard:
                    self.active -= 1

    backend = SlowBackend()
    engine = _engine(backend, tmp_path)
    errors: list[Exception] = []

    def run(index: int) -> None:
        try:
            engine.generate_candidates(
                speaker="Ryan",
                anchor_text="Overlapping anchor batch request.",
                instruct="",
                seed=index * 10,
                count=1,
                target_dir=tmp_path / f"out{index}",
            )
        except Exception as error:  # pragma: no cover - failure path
            errors.append(error)

    threads = [threading.Thread(target=run, args=(i,)) for i in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    assert backend.max_active == 1
    assert backend.unload_calls == 2

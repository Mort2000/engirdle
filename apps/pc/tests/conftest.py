"""Root conftest for the engirdle-pc test suite.

Exposes deterministic ``fake_translator`` / ``fake_speech`` fixtures (the
relocated production stubs) so worker/acceptance tests can drive the production
pipeline without a DeepSeek API key, GPU, model weights or network access.
"""

from __future__ import annotations

import pytest

from tests.speech_fake import StubSpeechAdapter
from tests.translation_fake import build_fake_translation_adapter


@pytest.fixture
def fake_translator():
    return build_fake_translation_adapter()


@pytest.fixture
def fake_speech():
    return StubSpeechAdapter()

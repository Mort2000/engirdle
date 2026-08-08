"""Root conftest for the engirdle-pc test suite.

Exposes a deterministic ``fake_translator`` fixture (the relocated production
stub) so worker/acceptance tests can drive the production pipeline without a
DeepSeek API key or network access.
"""

from __future__ import annotations

import pytest

from tests.translation_fake import build_fake_translation_adapter


@pytest.fixture
def fake_translator():
    return build_fake_translation_adapter()

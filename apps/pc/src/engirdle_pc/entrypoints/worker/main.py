from __future__ import annotations

import logging
import sys
import time

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.modules.translation.public import (
    DeepSeekConfigurationError,
    TranslationError,
    load_deepseek_api_key,
)

LOGGER = logging.getLogger(__name__)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    settings = Settings()
    api_key = load_deepseek_api_key()
    if not api_key:
        LOGGER.error("DEEPSEEK_API_KEY is not set; the worker cannot translate")
        sys.exit(1)
    try:
        container = Container.build(settings, deepseek_api_key=api_key)
        container.translations.verify_access()
    except DeepSeekConfigurationError as error:
        LOGGER.error(
            "DeepSeek is misconfigured, exiting",
            extra={"error": error.__class__.__name__},
        )
        sys.exit(1)
    except TranslationError as error:
        LOGGER.error(
            "DeepSeek access check failed, exiting",
            extra={"error": error.__class__.__name__},
        )
        sys.exit(1)
    recovered = container.worker.recover_stale_jobs()
    LOGGER.info("Recovered stale jobs", extra={"count": recovered})
    while True:
        if not container.worker.run_once():
            time.sleep(1)


if __name__ == "__main__":
    main()

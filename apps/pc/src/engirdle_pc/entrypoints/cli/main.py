from __future__ import annotations

import argparse
import logging
import sys
import time

import uvicorn

from engirdle_pc.bootstrap.config import Settings


def main() -> None:
    parser = argparse.ArgumentParser(prog="engirdle-pc")
    parser.add_argument("command", choices=("admin", "publisher", "worker-once", "check"))
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    settings = Settings()
    if arguments.command == "publisher":
        from engirdle_pc.modules.publishing.infrastructure.process_controller import (
            PublisherProcessController,
        )
        from engirdle_pc.shared.infrastructure.runtime import (
            SystemClock,
            UuidIdentifierGenerator,
        )

        publisher = PublisherProcessController(
            settings.workspace,
            settings.publisher_host,
            settings.publisher_port,
            SystemClock(),
            UuidIdentifierGenerator(),
        )
        publisher.start()
        try:
            while publisher.status().running:
                time.sleep(0.5)
        except KeyboardInterrupt:
            publisher.stop()
        return

    from engirdle_pc.bootstrap.container import Container
    from engirdle_pc.modules.speech.public import SpeechConfigurationError
    from engirdle_pc.modules.translation.public import (
        DeepSeekConfigurationError,
        TranslationError,
        load_deepseek_api_key,
    )

    if arguments.command == "worker-once":
        api_key = load_deepseek_api_key()
        if not api_key:
            logging.error("DEEPSEEK_API_KEY is not set; the worker cannot translate")
            sys.exit(1)
        try:
            container = Container.build(settings, deepseek_api_key=api_key)
            container.translations.verify_access()
            container.speech.verify_setup()
        except (DeepSeekConfigurationError, TranslationError) as error:
            logging.error(
                "DeepSeek unavailable, exiting",
                extra={"error": error.__class__.__name__},
            )
            sys.exit(1)
        except SpeechConfigurationError as error:
            logging.error(
                "Qwen3-TTS unavailable, exiting",
                extra={"error": error.__class__.__name__},
            )
            sys.exit(1)
        container.worker.recover_stale_jobs()
        processed = container.worker.run_once()
        print("processed" if processed else "idle")
        return

    container = Container.build(settings)
    if arguments.command == "admin":
        from engirdle_pc.entrypoints.admin_web.app import create_admin_app

        try:
            container.speech.verify_setup()
        except SpeechConfigurationError as error:
            logging.error(
                "Qwen3-TTS unavailable, exiting",
                extra={"error": error.__class__.__name__},
            )
            sys.exit(1)
        uvicorn.run(
            create_admin_app(container),
            host=settings.management_host,
            port=settings.management_port,
        )
    else:
        container.publishing.regenerate_catalog()
        print(f"workspace OK: {settings.workspace}")


if __name__ == "__main__":
    main()

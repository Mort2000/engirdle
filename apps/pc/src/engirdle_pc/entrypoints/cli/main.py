from __future__ import annotations

import argparse
import logging
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

    container = Container.build(settings)
    if arguments.command == "admin":
        from engirdle_pc.entrypoints.admin_web.app import create_admin_app

        uvicorn.run(
            create_admin_app(container),
            host=settings.management_host,
            port=settings.management_port,
        )
    elif arguments.command == "worker-once":
        processed = container.worker.run_once()
        print("processed" if processed else "idle")
    else:
        container.publishing.regenerate_catalog()
        print(f"workspace OK: {settings.workspace}")


if __name__ == "__main__":
    main()

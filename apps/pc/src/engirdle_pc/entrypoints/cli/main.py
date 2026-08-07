from __future__ import annotations

import argparse
import logging

import uvicorn

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container
from engirdle_pc.entrypoints.admin_web.app import create_admin_app
from engirdle_pc.entrypoints.publisher.app import create_publisher_app


def main() -> None:
    parser = argparse.ArgumentParser(prog="engirdle-pc")
    parser.add_argument("command", choices=("admin", "publisher", "worker-once", "check"))
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    settings = Settings()
    container = Container.build(settings)
    if arguments.command == "admin":
        uvicorn.run(
            create_admin_app(container),
            host=settings.management_host,
            port=settings.management_port,
        )
    elif arguments.command == "publisher":
        uvicorn.run(
            create_publisher_app(container.publisher_queries),
            host=settings.publisher_host,
            port=settings.publisher_port,
        )
    elif arguments.command == "worker-once":
        processed = container.worker.run_once()
        print("processed" if processed else "idle")
    else:
        container.publishing.regenerate_catalog()
        print(f"workspace OK: {settings.workspace}")


if __name__ == "__main__":
    main()

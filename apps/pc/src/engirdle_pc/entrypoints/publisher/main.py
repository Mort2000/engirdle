from __future__ import annotations

import argparse
import logging
from pathlib import Path

import uvicorn

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.publisher_container import PublisherContainer
from engirdle_pc.entrypoints.publisher.app import create_publisher_app


def main() -> None:
    parser = argparse.ArgumentParser(prog="engirdle-pc-publisher")
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--lease-token", required=True)
    arguments = parser.parse_args()
    del arguments.lease_token
    logging.basicConfig(level=logging.INFO)
    settings = Settings(
        workspace=arguments.workspace,
        publisher_host=arguments.host,
        publisher_port=arguments.port,
    )
    container = PublisherContainer.build(settings)
    uvicorn.run(
        create_publisher_app(container.publisher_queries),
        host=settings.publisher_host,
        port=settings.publisher_port,
    )


if __name__ == "__main__":
    main()

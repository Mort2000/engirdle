from __future__ import annotations

import logging
import time

from engirdle_pc.bootstrap.config import Settings
from engirdle_pc.bootstrap.container import Container


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    container = Container.build(Settings())
    recovered = container.worker.recover_stale_jobs()
    logging.getLogger(__name__).info("Recovered stale jobs", extra={"count": recovered})
    while True:
        if not container.worker.run_once():
            time.sleep(1)


if __name__ == "__main__":
    main()

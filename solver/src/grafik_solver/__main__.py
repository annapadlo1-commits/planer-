from __future__ import annotations

import logging
import sys

from .config import ConfigurationError, WorkerConfig
from .lifecycle import WorkerRuntime, install_signal_handlers


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        config = WorkerConfig.from_env()
        runtime = WorkerRuntime(config)
        install_signal_handlers(runtime)
        return runtime.run()
    except ConfigurationError as exc:
        logging.getLogger(__name__).error("Invalid worker configuration: %s", exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())

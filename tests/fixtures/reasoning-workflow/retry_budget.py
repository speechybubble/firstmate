"""Synthetic corrected CLI/API fixture, not a production retry service.

retry_plan(config) is the supported config-to-plan operation. Delays are in
milliseconds, one per attempt. Derivation has no retry or network effects.
"""

import argparse
from dataclasses import dataclass
import json
import math
import sys


@dataclass(frozen=True)
class _RetryPlan:
    delays_ms: tuple


def retry_plan(config):
    """Validate config and return an immutable schedule without mutating input."""
    if not isinstance(config, dict):
        raise ValueError("config must be an object")
    delay = config.get("delay_ms")
    attempts = config.get("attempts")
    if (
        isinstance(delay, bool)
        or not isinstance(delay, (int, float))
        or delay < 0
        or (isinstance(delay, float) and not math.isfinite(delay))
    ):
        raise ValueError("delay_ms must be a finite nonnegative number")
    if isinstance(attempts, bool) or not isinstance(attempts, int) or attempts <= 0:
        raise ValueError("attempts must be a positive integer")
    return _RetryPlan((delay,) * attempts)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Synthetic retry plan")
    parser.add_argument("config", help="JSON object with delay_ms and attempts")
    args = parser.parse_args(argv)
    try:
        plan = retry_plan(json.loads(args.config))
    except (ValueError, TypeError) as exc:
        print("error: " + str(exc), file=sys.stderr)
        return 2
    print(json.dumps({"delays_ms": plan.delays_ms}, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

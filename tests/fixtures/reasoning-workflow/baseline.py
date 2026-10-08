"""Synthetic unsafe baseline: CLI validation masks an unchecked imported API.

Synthetic source-history constraint: zero delay is intentional for dry runs.
This note is fixture evidence, not a real incident or fabricated Git history.
No entry point sleeps, accesses the network, or executes retries.
"""

import argparse
from dataclasses import dataclass
import json
import math
import sys


@dataclass(frozen=True)
class RetryPlan:
    """One delay per attempt, in milliseconds."""

    delays_ms: tuple


def retry_plan(config):
    """Unsafe imported entry point retained solely for regression evidence."""
    return RetryPlan((config["delay_ms"],) * config["attempts"])


def validate_cli(config):
    """The baseline's proven CLI path guards inputs before calling the API."""
    if not isinstance(config, dict):
        raise ValueError("config must be an object")
    delay = config.get("delay_ms")
    attempts = config.get("attempts")
    if isinstance(delay, bool) or not isinstance(delay, (int, float)):
        raise ValueError("delay_ms must be a finite nonnegative number")
    try:
        finite = math.isfinite(delay)
    except OverflowError:
        finite = False
    if not finite or delay < 0:
        raise ValueError("delay_ms must be a finite nonnegative number")
    if isinstance(attempts, bool) or not isinstance(attempts, int) or attempts <= 0:
        raise ValueError("attempts must be a positive integer")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Synthetic baseline retry plan")
    parser.add_argument("config", help="JSON object with delay_ms and attempts")
    args = parser.parse_args(argv)
    try:
        config = json.loads(args.config)
        validate_cli(config)
        plan = retry_plan(config)
    except (ValueError, TypeError) as exc:
        print("error: " + str(exc), file=sys.stderr)
        return 2
    print(json.dumps({"delays_ms": plan.delays_ms}, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

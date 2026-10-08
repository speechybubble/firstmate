#!/usr/bin/env bash
# Behavioral proof for the synthetic caller-first retry fixture through its
# public CLI and imported API, including the retained masking-path baseline.
# Uses only Python's standard library; never sleeps, networks, or retries.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/tests/fixtures/reasoning-workflow" <<'PY'
from dataclasses import FrozenInstanceError
import json
import math
from pathlib import Path
import subprocess
import sys
import unittest

fixture = Path(sys.argv.pop(1))
sys.path.insert(0, str(fixture))
import baseline
import retry_budget


def cli(module, raw):
    return subprocess.run(
        [sys.executable, str(fixture / (module.__name__ + ".py")), raw],
        capture_output=True, text=True, check=False,
    )


class CallerWorkflow(unittest.TestCase):
    def assert_cli_rejects(self, module, raw, message):
        result = cli(module, raw)
        self.assertEqual(result.returncode, 2, result)
        self.assertEqual(result.stdout, "", result)
        self.assertIn(message, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_baseline_mask_and_imported_failure(self):
        for delay in (-3, float("nan"), float("inf"), float("-inf")):
            with self.subTest(delay=delay):
                config = {"delay_ms": delay, "attempts": 2}
                self.assert_cli_rejects(baseline, json.dumps(config), "delay_ms")
                plan = baseline.retry_plan(config)
                self.assertEqual(len(plan.delays_ms), 2)
                if math.isnan(delay):
                    self.assertTrue(all(math.isnan(value) for value in plan.delays_ms))
                else:
                    self.assertEqual(plan.delays_ms, (delay, delay))

    def test_baseline_attempts_failure_shape(self):
        for attempts in (True, False, 0, -1):
            with self.subTest(attempts=attempts):
                config = {"delay_ms": 5, "attempts": attempts}
                self.assert_cli_rejects(baseline, json.dumps(config), "attempts")
                self.assertEqual(len(baseline.retry_plan(config).delays_ms), max(0, int(attempts)))

    def test_valid_neighbors_preserved_on_both_callers(self):
        for module in (baseline, retry_budget):
            for delay, attempts in ((0, 3), (12.5, 2), (8, 1)):
                with self.subTest(module=module.__name__, delay=delay):
                    config = {"delay_ms": delay, "attempts": attempts}
                    expected = (delay,) * attempts
                    self.assertEqual(module.retry_plan(config).delays_ms, expected)
                    result = cli(module, json.dumps(config))
                    self.assertEqual(result.returncode, 0, result)
                    self.assertEqual(result.stderr, "", result)
                    self.assertEqual(json.loads(result.stdout), {"delays_ms": list(expected)})

    def test_corrected_runtime_delay_boundary(self):
        for delay in (-3, float("nan"), float("inf"), float("-inf"), True, False, "0", None, [], {}):
            with self.subTest(delay=delay):
                config = {"delay_ms": delay, "attempts": 2}
                original = config.copy()
                with self.assertRaisesRegex(ValueError, "delay_ms"):
                    retry_budget.retry_plan(config)
                self.assertEqual(config, original)
                self.assert_cli_rejects(retry_budget, json.dumps(config), "delay_ms")

    def test_corrected_runtime_attempts_boundary(self):
        for attempts in (0, -1, True, False, 2.0, "2", None, [], {}):
            with self.subTest(attempts=attempts):
                config = {"delay_ms": 0, "attempts": attempts}
                original = config.copy()
                with self.assertRaisesRegex(ValueError, "attempts"):
                    retry_budget.retry_plan(config)
                self.assertEqual(config, original)
                self.assert_cli_rejects(retry_budget, json.dumps(config), "attempts")

    def test_malformed_and_incomplete_config(self):
        for config in (None, [], "config", 7, True, {}, {"delay_ms": 0}, {"attempts": 2}):
            with self.subTest(config=config):
                with self.assertRaises(ValueError):
                    retry_budget.retry_plan(config)
                self.assert_cli_rejects(retry_budget, json.dumps(config), "error:")
        self.assert_cli_rejects(retry_budget, '{"delay_ms":', "error:")
        self.assert_cli_rejects(retry_budget, "", "error:")

    def test_immutable_replay_and_recovery(self):
        config = {"delay_ms": 12.5, "attempts": 2, "caller_note": ["unchanged"]}
        original = {"delay_ms": 12.5, "attempts": 2, "caller_note": ["unchanged"]}
        first = retry_budget.retry_plan(config)
        self.assertEqual(first, retry_budget.retry_plan(config))
        self.assertEqual(config, original)
        self.assertIsInstance(first.delays_ms, tuple)
        with self.assertRaises(FrozenInstanceError):
            first.delays_ms = (0,)
        with self.assertRaises(TypeError):
            first.delays_ms[0] = 0
        self.assert_cli_rejects(retry_budget, '{"delay_ms":-1,"attempts":3}', "delay_ms")
        recovered = cli(retry_budget, '{"delay_ms":0,"attempts":3}')
        self.assertEqual(recovered.returncode, 0, recovered)
        self.assertEqual(json.loads(recovered.stdout), {"delays_ms": [0, 0, 0]})
        self.assertEqual(recovered.stdout, cli(retry_budget, '{"delay_ms":0,"attempts":3}').stdout)
        self.assertEqual(config, original)

    def test_large_finite_integer_and_cli_help(self):
        config = {"delay_ms": 10**400, "attempts": 1}
        self.assertEqual(retry_budget.retry_plan(config).delays_ms, (10**400,))
        result = cli(retry_budget, json.dumps(config))
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(json.loads(result.stdout), {"delays_ms": [10**400]})
        help_result = cli(retry_budget, "--help")
        self.assertEqual(help_result.returncode, 0, help_result)
        self.assertIn("delay_ms and attempts", help_result.stdout)


unittest.main(verbosity=2)
PY

pass "reasoning workflow: masking baseline, shared runtime boundary, valid neighbors, immutable replay and recovery"

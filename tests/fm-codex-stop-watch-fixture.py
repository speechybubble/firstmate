#!/usr/bin/env python3
"""Portable lifecycle mocks for the opt-in native fixture; never runs Herdr/Codex."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


class NativeFixtureLifecycle(unittest.TestCase):
    def test_helper_selection_and_failure_cleanup(self):
        for explicit in (False, True):
            with self.subTest(explicit=explicit), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                home = base / "control-home"
                home.mkdir()
                auth = home / "auth.json"
                auth.write_bytes(b"opaque-test-credential")
                expected = str(base / "installed helper" if explicit else ROOT / "bin/fm-herdr-lab.sh")
                env = {"HOME": str(home), "PATH": os.environ["PATH"], "TMPDIR": str(base),
                       "FM_CODEX_TEST_AUTH": str(auth), "FM_HERDR_LAB_PROTECTED_SESSION": "protected-test",
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
                if explicit:
                    env["HERDR_LAB_HELPER"] = expected
                calls = []
                real_run = subprocess.run

                def run(args, **kwargs):
                    if args[0] in {"git", "bin/fm-check-register.sh"}:
                        return real_run(args, **kwargs)
                    # Every other subprocess must be the selected helper. Never
                    # delegate these calls, even when the assertion fails.
                    self.assertEqual(args[0], expected)
                    calls.append(args[1:])
                    control = kwargs["env"]
                    self.assertEqual(control["HOME"], str(home))
                    self.assertEqual(control["FM_HERDR_LAB_PROTECTED_SESSION"], "protected-test")
                    fixture = Path(kwargs["cwd"])
                    child = json.loads((fixture.parent / "child-env.json").read_text())
                    self.assertNotEqual(child["HOME"], control["HOME"])
                    self.assertNotIn("FM_HERDR_LAB_PROTECTED_SESSION", child)
                    for key in ("FM_HOME", "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE",
                                "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE", "CODEX_HOME", "TMPDIR"):
                        self.assertTrue(Path(child[key]).is_relative_to(fixture.parent), key)
                        self.assertEqual(control[key], child[key])
                    self.assertEqual((fixture / "state/poll.check.sh").stat().st_mode & 0o777, 0o700)
                    operation = args[1]
                    self.assertEqual(kwargs["timeout"], None if operation in {"provision", "teardown"} else 30)
                    if operation == "name":
                        output, rc = "fm-lab-codex-test\n", 0
                    elif operation == "run":
                        self.assertEqual(args[2:], ["fm-lab-codex-test", "session", "list", "--json"])
                        output, rc = json.dumps({"sessions": [{"name": "protected-test", "running": True}]}), 0
                    else:
                        self.assertIn(operation, {"provision", "teardown"})
                        self.assertEqual(args[2:], ["fm-lab-codex-test"])
                        output, rc = "", 1 if operation == "provision" else 0
                    return subprocess.CompletedProcess(args, rc, output, "mock provision refusal" if rc else "")

                output = io.StringIO()
                mask = os.umask(0o077)
                handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
                try:
                    with patch.dict(os.environ, env, clear=True), patch("subprocess.run", side_effect=run), contextlib.redirect_stdout(output):
                        with self.assertRaisesRegex(RuntimeError, "guarded helper refused"):
                            runpy.run_path(str(ROOT / "tests/fm-codex-stop-watch-live.py"), run_name="__main__")
                finally:
                    os.umask(mask)
                    for sig, handler in handlers.items():
                        signal.signal(sig, handler)
                self.assertEqual([call[0] for call in calls], ["name", "run", "provision", "teardown"])
                records = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertTrue(all(row["executable"] == expected for row in records if row["kind"] == "helper"))
                self.assertEqual(records[-1]["kind"], "cleanup")
                self.assertTrue(records[-1]["auth_removed"])
                self.assertTrue(records[-1]["production_unchanged"])
                self.assertEqual(auth.read_bytes(), b"opaque-test-credential")


if __name__ == "__main__":
    unittest.main()

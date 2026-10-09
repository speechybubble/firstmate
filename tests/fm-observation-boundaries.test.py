#!/usr/bin/env python3
"""Execute ownership races, bounded retained summaries, and contribution-only reads."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).absolute().parent.parent
BIN = Path(os.environ.get("FM_OBSERVATION_TEST_BIN", ROOT / "bin"))


class ObservationBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".observation-test-", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.fakebin = self.root / "fakebin"
        self.fakebin.mkdir()
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("FM_", "GIT_", "TASKS_AXI_"))
        }
        self.env.update(
            PATH=f"{self.fakebin}:{os.environ['PATH']}",
            HOME=str(self.root),
            TMPDIR=str(self.root),
            FM_ROOT_OVERRIDE=str(ROOT),
            FM_CREW_STATE_NO_FORGE="1",
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CEILING_DIRECTORIES=str(ROOT),
        )
        self.tool("no-mistakes", "exit 0\n")
        self.tool("tmux", '''
case "${FM_TEST_ACTION:-}" in
  remove) rm -f "$FM_TEST_MARKER" ;;
  disappear) rmdir "$FM_TEST_WORKTREE" ;;
  claim) printf 'task=worker\\nhome=original\\n' > "$FM_TEST_MARKER" ;;
  reassign) printf 'task=replacement\\nhome=original\\n' > "$FM_TEST_MARKER" ;;
  relocate) printf 'task=worker\\nhome=relocated\\n' > "$FM_TEST_MARKER" ;;
  corrupt) printf 'task=worker\\ntask=replacement\\n' > "$FM_TEST_MARKER" ;;
esac
printf '%%1\\n'
''')
        self.tool("jq", '''
if [ "${FM_TEST_ARCHIVE_ERROR:-0}" = 1 ]; then
  for arg in "$@"; do
    if [ "$arg" = "$FM_HOME/data/done-archive.md" ]; then
      printf 'archive read attempted\\n' >> "$FM_TEST_ARCHIVE_LOG"
      exit 73
    fi
  done
fi
exec "''' + shutil.which("jq") + '''" "$@"
''')

    def tool(self, name, body):
        path = self.fakebin / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)

    def home(self, name):
        home = self.root / name
        for part in ("state", "data", "config", "projects"):
            (home / part).mkdir(parents=True)
        (home / "data/backlog.md").write_text("## In flight\n## Queued\n## Done\n")
        return home

    def command(self, home, script, *args, **env):
        return subprocess.run(
            [str(BIN / script), *map(str, args)],
            env={**self.env, "FM_HOME": str(home), **env},
            text=True, capture_output=True, timeout=120,
        )

    def output(self, home, script, *args, **env):
        result = self.command(home, script, *args, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def task(self, home, task_id, kind="scout", busy="idle", status="done: finished"):
        worktree = home / "projects" / task_id / "worktree"
        worktree.mkdir(parents=True)
        (home / f"state/{task_id}.meta").write_text(
            f"worktree={worktree}\nkind={kind}\nharness=claude\n"
            f"backend=tmux\nwindow=fixture:fm-{task_id}\nproject=fixture\n"
        )
        (home / f"state/{task_id}.status").write_text(status + "\n")
        if kind != "secondmate":
            gen = self.output(home, "fm-busy-event.sh", "arm", home / "state", task_id).strip()
            self.output(home, "fm-busy-event.sh", "apply", home / "state", task_id,
                        busy, "--gen", gen, "--source", "claude-hook", "--event",
                        "stop" if busy == "idle" else "user-prompt-submit")
        return worktree

    def test_ownership_transitions_and_stable_legacy_claims(self):
        cases = [
            ("mine", "remove", "unknown"),
            ("mine", "disappear", "unknown"),
            ("absent", "disappear", "unknown"),
            ("absent", "claim", "unknown"),
            ("mine", "reassign", "unknown"),
            ("mine", "relocate", "unknown"),
            ("mine", "corrupt", "unknown"),
            ("mine", "", "working"),
            ("absent", "", "working"),
            ("other", "", "unknown"),
            ("unsafe", "", "unknown"),
        ]
        for kind in ("scout", "secondmate"):
            for initial, action, expected in cases:
                with self.subTest(kind=kind, initial=initial, action=action):
                    home = self.home(f"{kind}-{initial}-{action}")
                    worktree = self.task(home, "worker", kind, "busy", "working: observing")
                    marker = worktree.parent / ".fm-slot-owner"
                    if initial != "absent":
                        marker.write_text({
                            "mine": "task=worker\nhome=original\n",
                            "other": "task=other\nhome=original\n",
                            "unsafe": "not a claim\n",
                        }[initial])
                    out = self.output(home, "fm-crew-state.sh", "worker",
                                      FM_TEST_ACTION=action, FM_TEST_MARKER=str(marker),
                                      FM_TEST_WORKTREE=str(worktree))
                    self.assertTrue(out.startswith(f"state: {expected} · "), out)
                    if expected == "unknown":
                        self.assertIn("source: ownership", out)
                    else:
                        source = "pane" if kind == "scout" else "status-log"
                        self.assertIn(f"source: {source}", out)

    def test_retained_summary_is_bounded_and_parent_keeps_current_work(self):
        home = self.home("child")
        (home / ".fm-secondmate-home").write_text("child\n")
        (home / "AGENTS.md").symlink_to(ROOT / "AGENTS.md")
        (home / "bin").mkdir()
        detail = "retained-evidence-" + "x" * 10000
        retained = [f"retained-{i:02}" for i in range(21)]
        for task_id in retained:
            self.task(home, task_id, status=f"done: {detail}")
        self.task(home, "active", busy="busy", status="working: current work")
        self.task(home, "held", status="needs-decision [key=choice]: choose a route")
        (home / "data/backlog.md").write_text(
            "## In flight\n- [ ] active - Active work (repo: fixture) (kind: scout)\n"
            "## Queued\n- [ ] held - Held work (kind: scout) (hold: access) (hold-kind: external)\n"
            "## Done\n" + "".join(f"- [x] {task_id} - Finished (kind: scout)\n" for task_id in retained[:10])
        )
        (home / "data/done-archive.md").write_text(
            "## Archived 2026-09-29\n" + "".join(
                f"- [x] {task_id} - Finished (kind: scout)\n"
                for task_id in retained[10:] + ["active", "held"]
            )
        )
        raw = self.output(home, "fm-fleet-snapshot.sh", "--secondmate-home-summary")
        summary = json.loads(raw)
        (home / "state/home-summary.json").write_text(raw)
        parent = self.home("parent")
        (parent / "data/secondmates.md").write_text(
            f"- child - fixture domain (home: {home}; scope: fixture; projects: fixture; added 2026-09-29)\n"
        )
        parent_snapshot = json.loads(self.output(
            parent, "fm-fleet-snapshot.sh", "--json", FM_ROOT_OVERRIDE=str(self.fakebin)
        ))
        child = parent_snapshot["secondmate_current"]["records"][0]
        self.assertEqual(child["provenance"].get("summary_source"), "local-ledger", child)
        self.assertEqual([row["id"] for row in child["active_children"]], ["active"])
        self.assertIn("held", [row["id"] for row in child["decisions_open"]])
        self.assertLess(len(raw.encode()), 262144)
        self.assertEqual(summary["counts"]["completed_retained"], 21)
        self.assertEqual(len(summary["completed_retained"]), 20)
        self.assertIn({"surface": "completed_retained", "count": 1}, summary["omitted"])
        self.assertTrue(any(row["surface"] == "completed_retained_text" and row["count"] > 0
                            for row in summary["omitted"]))
        for row in summary["completed_retained"]:
            self.assertLessEqual(len(row["current_state"]["raw"]), 241)
            self.assertLessEqual(len(row["current_state"]["detail"]), 241)
        canonical = json.loads(self.output(home, "fm-fleet-snapshot.sh", "--json"))
        tasks = {row["id"]: row for row in canonical["tasks"]}
        for task_id in retained:
            self.assertEqual(tasks[task_id]["lifecycle"]["state"], "completed_retained")
            self.assertEqual(tasks[task_id]["current_state"]["detail"], detail)
            self.assertIn(detail, tasks[task_id]["current_state"]["raw"])
        self.assertEqual(tasks["active"]["lifecycle"]["state"], "current")
        self.assertEqual(tasks["held"]["lifecycle"]["state"], "held")

    def test_contribution_input_never_reads_archive(self):
        home = self.home("contributions")
        (home / "data/backlog.md").write_text(
            "## Queued\n" + "".join(
                f"- [ ] task-{i} - {'x' * 1500} (kind: ship)\n" for i in range(100)
            )
        )
        (home / "data/done-archive.md").write_text("## Archived 2026-09-29\n")
        log = self.root / "archive-read.log"
        env = {"FM_TEST_ARCHIVE_ERROR": "1", "FM_TEST_ARCHIVE_LOG": str(log)}
        result = self.command(home, "fm-fleet-snapshot.sh", "--contribution-input", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["backlog"]["records"]), 100)
        self.assertFalse(log.exists())
        for mode in ("--json", "--secondmate-home-summary"):
            with self.subTest(mode=mode):
                result = self.command(home, "fm-fleet-snapshot.sh", mode, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("completion archive read failed", result.stderr)
                self.assertEqual(result.stdout, "")
        self.assertEqual(len(log.read_text().splitlines()), 2)


if __name__ == "__main__":
    unittest.main()

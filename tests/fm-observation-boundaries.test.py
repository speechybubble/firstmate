#!/usr/bin/env python3
"""Execute ownership races, bounded retained summaries, and contribution-only reads."""

import json
import os
from pathlib import Path
import shutil
import sqlite3
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

    def git_task(self, home, task_id, **kwargs):
        """A task whose copy is a git branch, so its live read asks no-mistakes."""
        worktree = self.task(home, task_id, **kwargs)
        git = ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
               "-C", str(worktree)]
        for args in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "base"],
                     ["checkout", "-q", "-b", f"fm/{task_id}"]):
            subprocess.run(git + args, env=self.env, check=True, capture_output=True)
        return worktree

    def slow_no_mistakes(self, log):
        """Record each no-mistakes call's start and directory, then stall slow copies."""
        self.tool("no-mistakes", f'''
printf '%s\\t%s\\n' "$(python3 -c 'import time; print(time.time())')" "$PWD" >> "{log}"
case "$PWD" in
  *slow*) sleep "${{FM_TEST_NM_DELAY:-0}}" ;;
esac
exit 0
''')

    def test_completed_work_skips_live_reads_and_publishes_within_bound(self):
        home = self.home("accumulated")
        (home / ".fm-secondmate-home").write_text("accumulated\n")
        (home / "AGENTS.md").symlink_to(ROOT / "AGENTS.md")
        (home / "bin").mkdir()
        retained = [f"slow-done-{i:02}" for i in range(8)]
        # A ship done the named-head gate does not apply to stays done; one it
        # refuses from local git reads is blocked; one only a live forge read
        # could settle is an ungated history claim, never a plain done.
        unpublished = retained[4:6]
        gerrit_url = "https://review.example.invalid/c/fixture/+/42"
        unverified = retained[6]
        heads = {}
        for task_id in retained:
            status = f"done: finished {task_id}"
            if task_id == unverified:
                status = f"done: PR {gerrit_url} published for review"
            worktree = self.git_task(home, task_id, kind="ship", status=status)
            if task_id in unpublished:
                with (home / f"state/{task_id}.meta").open("a") as meta:
                    meta.write("mode=local-only\n")
            heads[task_id] = subprocess.run(
                ["git", "-C", str(worktree), "rev-parse", "HEAD"], env=self.env,
                check=True, capture_output=True, text=True).stdout.strip()
        self.git_task(home, "active", kind="ship", busy="busy", status="working: current work")
        self.git_task(home, "held", kind="ship", status="needs-decision [key=route]: choose a route")
        (home / "data/backlog.md").write_text(
            "## In flight\n- [ ] active - Active work (repo: fixture) (kind: ship)\n"
            "- [ ] held - Held call (repo: fixture) (kind: ship) (hold: choose a route) (hold-kind: captain)\n"
            "## Queued\n"
            "## Done\n" + "".join(f"- [x] {task_id} - Finished (kind: ship)\n" for task_id in retained[:6])
        )
        (home / "data/done-archive.md").write_text(
            "## Archived 2026-09-29\n" + "".join(
                f"- [x] {task_id} - Finished (kind: ship)\n" for task_id in retained[6:]
            )
        )
        # A ledger left behind by another home (a lab clone sharing this state
        # directory) must be replaced by the first successful refresh.
        (home / "state/home-summary.json").write_text(json.dumps({
            "schema": "fm-secondmate-home-summary.v1",
            "home": str(self.root / "lab-clone"),
            "generated": "2026-10-09T11:40:00Z",
        }) + "\n")
        log = self.root / "nm-calls.log"
        self.slow_no_mistakes(log)
        # Every live read of a completed copy would stall to the per-read bound,
        # so reading them serially in pairs could not finish inside the deadline.
        result = self.command(home, "fm-home-summary-refresh.sh",
                              FM_TEST_NM_DELAY="30", FM_SNAPSHOT_CREW_STATE_TIMEOUT="5",
                              FM_SNAPSHOT_LOCAL_READ_CONCURRENCY="2",
                              FM_HOME_SUMMARY_TIMEOUT="20")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = log.read_text() if log.exists() else ""
        self.assertIn("/active/", calls)
        for task_id in retained:
            self.assertNotIn(f"/{task_id}/", calls)
        summary = json.loads((home / "state/home-summary.json").read_text())
        self.assertEqual(summary["home"], str(home))
        self.assertEqual(summary["counts"]["completed_retained"], len(retained))
        rows = {row["id"]: row for row in summary["completed_retained"]}
        self.assertEqual(sorted(rows), retained)
        for task_id in retained:
            self.assertEqual(rows[task_id]["lifecycle"]["state"], "completed_retained")
            current = rows[task_id]["current_state"]
            self.assertEqual(current["source"], "status-log")
            if task_id in unpublished:
                self.assertEqual(current["state"], "blocked")
                self.assertEqual(current["detail"],
                                 f"named head {heads[task_id]} is unreachable outside the worker copy")
            elif task_id == unverified:
                self.assertEqual(current["state"], "unknown")
                self.assertTrue(current["detail"].startswith(
                    f"PR {gerrit_url} published for review · ungated history claim: "),
                    current["detail"])
            else:
                self.assertEqual(current["state"], "done")
                self.assertEqual(current["detail"], f"finished {task_id}")
        self.assertEqual([row["id"] for row in summary["active_children"]], ["active"])
        self.assertIn("held", [row["id"] for row in summary["decisions_open"]])
        self.assertEqual(sorted(row["id"] for row in summary["endpoints"]), ["active", "held"])

    def test_one_slow_read_does_not_hold_a_whole_batch(self):
        home = self.home("window")
        for task_id in ("a-slow", "b-fast", "c-slow"):
            self.git_task(home, task_id, kind="ship", busy="busy", status="working: current work")
        (home / "data/backlog.md").write_text(
            "## In flight\n" + "".join(
                f"- [ ] {task_id} - Work (repo: fixture) (kind: ship)\n"
                for task_id in ("a-slow", "b-fast", "c-slow")
            ) + "## Queued\n## Done\n"
        )
        log = self.root / "window-calls.log"
        self.slow_no_mistakes(log)
        self.output(home, "fm-fleet-snapshot.sh", "--secondmate-home-summary",
                    FM_TEST_NM_DELAY="30", FM_SNAPSHOT_CREW_STATE_TIMEOUT="6",
                    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY="2")
        starts = {}
        for line in log.read_text().splitlines():
            stamp, directory = line.split("\t", 1)
            for task_id in ("a-slow", "c-slow"):
                if f"/{task_id}/" in directory + "/":
                    starts.setdefault(task_id, float(stamp))
        self.assertEqual(sorted(starts), ["a-slow", "c-slow"], log.read_text())
        # With two slots, c-slow takes the slot b-fast frees; it must not wait
        # for a-slow's read to reach its six-second bound.
        self.assertLess(starts["c-slow"] - starts["a-slow"], 4.5)

    def test_paused_child_without_a_run_keeps_its_hold_when_the_overview_stalls(self):
        # Inventories as the installed CLI prints them for a branch with no run:
        # other branches' runs in a table, or a repository with no runs at all.
        inventories = {
            "other-branch-runs": (
                "count: 1 of 1 total\\n"
                "runs[1]{id,branch,status,head,pr}:\\n"
                '  "01OTHER",fm/other,completed,abcdef12,""\\n'
            ),
            "empty-repository": "runs: 0 runs yet in this repository\\n",
        }
        for name, inventory in inventories.items():
            with self.subTest(inventory=name):
                home = self.home(f"paused-{name}")
                self.git_task(home, "custody", kind="ship",
                              status="paused: custody accepted, awaiting release")
                (home / "data/backlog.md").write_text(
                    "## In flight\n- [ ] custody - Custody work (repo: fixture) (kind: ship)\n"
                    "## Queued\n## Done\n"
                )
                log = self.root / f"paused-{name}.log"
                # The status answer already says this branch has no run and carries
                # the inventory; a separate overview call stalls past the read bound.
                self.tool("no-mistakes", f'''
printf '%s\\n' "$*" >> "{log}"
case "$*" in
  "axi status")
    printf 'current_branch: fm/custody\\nruns_on_current_branch: 0\\n{inventory}' ;;
  axi) sleep 30 ;;
esac
exit 0
''')
                summary = json.loads(self.output(home, "fm-fleet-snapshot.sh",
                                                 "--secondmate-home-summary",
                                                 FM_SNAPSHOT_CREW_STATE_TIMEOUT="5"))
                calls = log.read_text().splitlines()
                self.assertIn("axi status", calls)
                self.assertNotIn("axi", calls)
                rows = {row["id"]: row for row in summary["endpoints"]}
                self.assertEqual((rows["custody"]["state"], rows["custody"]["source"]),
                                 ("paused", "status-log"))
                self.assertIn("custody", [row["id"] for row in summary["holds"]])

    def test_paused_child_with_capped_status_reads_identity_from_overview(self):
        home = self.home("paused-capped-status")
        self.git_task(home, "custody", kind="ship",
                      status="paused: custody accepted, awaiting release")
        (home / "data/backlog.md").write_text(
            "## In flight\n- [ ] custody - Custody work (repo: fixture) (kind: ship)\n"
            "## Queued\n## Done\n"
        )
        # The installed status surface shows ten of eleven other-branch runs
        # without repo identity. Only the overview can identify the database
        # repository so selection can prove that this branch has no run.
        nm_home = self.root / "no-mistakes"
        nm_home.mkdir()
        with sqlite3.connect(nm_home / "state.sqlite") as db:
            db.execute("CREATE TABLE repos (id TEXT, working_path TEXT)")
            db.execute("CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, "
                       "status TEXT, head_sha TEXT, created_at INTEGER)")
            db.execute("INSERT INTO repos VALUES (?, ?)", ("fixture", str(home)))
            db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)", [
                (f"OTHER{i}", "fixture", f"fm/other-{i}", "completed", "abcdef12", i)
                for i in range(11)
            ])
        inventory = "count: 10 of 11 total\nruns[10]{id,branch,status,head,pr}:\n" + "".join(
            f'  OTHER{i},fm/other-{i},completed,abcdef12,""\n'
            for i in range(10, 0, -1)
        )
        status = self.root / "capped-status.txt"
        status.write_text("current_branch: fm/custody\nruns_on_current_branch: 0\n" + inventory)
        overview = self.root / "capped-overview.txt"
        overview.write_text(f"repo: {json.dumps(str(home))}\n" + inventory)
        log = self.root / "capped-status-calls.log"
        self.tool("no-mistakes", f"""
printf '%s\\n' "$*" >> "{log}"
case "$*" in
  "axi status") cat "{status}" ;;
  axi) cat "{overview}" ;;
esac
""")
        summary = json.loads(self.output(home, "fm-fleet-snapshot.sh",
                                         "--secondmate-home-summary",
                                         NM_HOME=str(nm_home)))
        calls = log.read_text().splitlines()
        self.assertEqual(calls[:2], ["axi status", "axi"])
        rows = {row["id"]: row for row in summary["endpoints"]}
        self.assertEqual((rows["custody"]["state"], rows["custody"]["source"]),
                         ("paused", "status-log"))
        self.assertIn("custody", [row["id"] for row in summary["holds"]])

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

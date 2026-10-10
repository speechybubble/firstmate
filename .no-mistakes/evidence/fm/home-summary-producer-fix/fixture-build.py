#!/usr/bin/env python3
"""Build a disposable production-shaped Firstmate home. usage: build.py <root> <fm_root>"""
import json, os, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]); fm = Path(sys.argv[2])
home = root / "home"; fakebin = root / "fakebin"
for p in ("state", "data", "config", "projects"): (home / p).mkdir(parents=True)
fakebin.mkdir()
(home / ".fm-secondmate-home").write_text("prod-shaped\n")
(home / "AGENTS.md").symlink_to(fm / "AGENTS.md")
(home / "bin").mkdir()
def tool(name, body):
    p = fakebin / name; p.write_text("#!/usr/bin/env bash\nset -eu\n" + body); p.chmod(0o755)
# Every no-mistakes call costs FM_LIVE_NM_DELAY seconds, like the slow /mnt/c reads.
tool("no-mistakes", 'printf "%s\\t%s\\t%s\\n" "$(date +%s.%N)" "$PWD" "$*" >> "$FM_LIVE_NM_LOG"\nsleep "${FM_LIVE_NM_DELAY:-5}"\nexit 0\n')
tool("tmux", "printf '%%1\\n'\n")
env = {k: v for k, v in os.environ.items() if not k.startswith(("FM_", "GIT_"))}
env.update(PATH=f"{fakebin}:{os.environ['PATH']}", HOME=str(root), TMPDIR=str(root),
           FM_ROOT_OVERRIDE=str(fm), FM_HOME=str(home), FM_CREW_STATE_NO_FORGE="1",
           GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_CEILING_DIRECTORIES=str(root))
def run(*a): return subprocess.run(list(map(str, a)), env=env, check=True, capture_output=True, text=True).stdout
def task(tid, status, busy="idle", extra=""):
    wt = home / "projects" / tid / "worktree"; wt.mkdir(parents=True)
    (home / f"state/{tid}.meta").write_text(f"worktree={wt}\nkind=ship\nharness=claude\nbackend=tmux\n"
        f"window=fixture:fm-{tid}\nproject=fixture\nbranch=fm/{tid}\n{extra}")
    (home / f"state/{tid}.status").write_text(status + "\n")
    g = ["git", "-c", "user.name=F", "-c", "user.email=f@example.invalid", "-C", wt]
    for a in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "base"], ["checkout", "-q", "-b", f"fm/{tid}"]):
        run(*g, *a)
    gen = run(fm / "bin/fm-busy-event.sh", "arm", home / "state", tid).strip()
    run(fm / "bin/fm-busy-event.sh", "apply", home / "state", tid, busy, "--gen", gen,
        "--source", "claude-hook", "--event", "stop" if busy == "idle" else "user-prompt-submit")
small = len(sys.argv) > 3
done = [f"done-{i:02}" for i in range(2 if small else 33)]
for t in done: task(t, f"done: finished {t}")
task("done-unpublished", "done: shipped locally", extra="mode=local-only\n")
task("cancelled-1", "failed: cancelled by captain")
active = [f"active-{i}" for i in range(1 if small else 5)]
for t in active: task(t, "working: current work", busy="busy")
task("captain-held", "needs-decision [key=route]: choose a route")
task("business-held", "blocked: waiting on vendor contract")
task("paused-1", "paused: custody accepted, awaiting release")
task("queued-held", "working: queued")
retained = done + ["done-unpublished", "cancelled-1"]
bl = "## In flight\n" + "".join(f"- [ ] {t} - Active work (repo: fixture) (kind: ship)\n" for t in active)
bl += "- [ ] captain-held - Held call (repo: fixture) (kind: ship) (hold: choose a route) (hold-kind: captain)\n"
bl += "- [ ] business-held - Vendor (repo: fixture) (kind: ship) (hold: vendor contract) (hold-kind: external)\n"
bl += "- [ ] paused-1 - Paused (repo: fixture) (kind: ship)\n"
bl += "## Queued\n- [ ] queued-held - Queued (repo: fixture) (kind: ship) (hold: business review) (hold-kind: captain)\n"
bl += "## Done\n" + "".join(f"- [x] {t} - Finished (kind: ship)\n" for t in retained[:20])
(home / "data/backlog.md").write_text(bl)
(home / "data/done-archive.md").write_text("## Archived 2026-10-01\n" + "".join(f"- [x] {t} - Finished (kind: ship)\n" for t in retained[20:]))
(home / "state/home-summary.json").write_text(json.dumps({"schema": "fm-secondmate-home-summary.v1",
    "home": "/home/denni/kun-validation/claude-migration-20261009/fleet-LAB-CLONE", "generated": "2026-10-09T11:40:00Z"}) + "\n")
print(len(list((home / "state").glob("*.meta"))), "tasks")

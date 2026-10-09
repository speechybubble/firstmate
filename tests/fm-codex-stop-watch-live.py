#!/usr/bin/env python3
"""Opt-in native integration regression. Retains artifacts, removes private auth.

The shell entry point owns opt-in. Only the named Herdr helper drives lifecycle.
No operator message or rearm is sent after initial setup. A bounded injector
publishes actual durable/status/poll inputs across native completed turns.
Before running, inspect .codex/hooks.json and its hook commands, then export
FM_CODEX_TEST_REVIEWED_HOOKS_SHA256 with that reviewed file's SHA-256. The
UI driver will not trust hooks without this exact-content review attestation.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from codex_native_setup import NativeSetup

ROOT = Path(__file__).resolve().parent.parent
BASE = Path(tempfile.mkdtemp(prefix="fm-codex-native-", dir=os.environ.get("TMPDIR")))
os.chmod(BASE, 0o700)
os.umask(0o077)
AUTH_SOURCE = Path(os.environ.get("FM_CODEX_TEST_AUTH", str(Path.home() / ".codex/auth.json")))
PROTECTED = os.environ.get("FM_HERDR_LAB_PROTECTED_SESSION")
if not PROTECTED:
    raise SystemExit("Set FM_HERDR_LAB_PROTECTED_SESSION to the real protected running session")
if not AUTH_SOURCE.is_file() or AUTH_SOURCE.is_symlink():
    raise SystemExit("Native ChatGPT file credentials required via FM_CODEX_TEST_AUTH")
HELPER = os.environ.get("HERDR_LAB_HELPER", str(ROOT / "bin/fm-herdr-lab.sh"))
FM = BASE / "fm"
CH = BASE / "codex"
for path in [FM, CH, BASE / "home", BASE / "tmp", BASE / "herdr", BASE / "events"]:
    path.mkdir(mode=0o700)
for name in ["bin", "docs", ".codex"]:
    shutil.copytree(ROOT / name, FM / name)
for name in ["state", "data", "config", "projects"]:
    (FM / name).mkdir()
(FM / "AGENTS.md").write_text(
    "This is a bounded native test fixture. Work only here. No delegation, network tools, "
    "credential inspection, configuration changes or new events. Do not change hooks, "
    "checks, trust or held work. On native watcher notifications, drain real wakes, "
    "record only the emitted D1, STATUS, POLL, D2 or LATE identifier and UTC time in "
    "data/handled.txt, then run the exact printed acknowledgement and finish. "
    "The native Stop hook owns the next watcher. Do not manually rearm or queue a message.\n"
)
(CH / "config.toml").write_text(
    'forced_login_method = "chatgpt"\ncli_auth_credentials_store = "file"\n'
    'model = "gpt-6-astra"\nmodel_reasoning_effort = "medium"\n'
    'approval_policy = "never"\nsandbox_mode = "workspace-write"\n[features]\nhooks = true\n'
)
CHILD = {
    "HOME": str(BASE / "home"), "CODEX_HOME": str(CH), "TMPDIR": str(BASE / "tmp"),
    "PATH": os.environ["PATH"], "TERM": "xterm-256color", "LANG": "C.UTF-8",
    "FM_HOME": str(FM), "FM_ROOT_OVERRIDE": str(FM),
    "FM_STATE_OVERRIDE": str(FM / "state"), "FM_DATA_OVERRIDE": str(FM / "data"),
    "FM_CONFIG_OVERRIDE": str(FM / "config"), "FM_PROJECTS_OVERRIDE": str(FM / "projects"),
    "FM_PROCEVENT_CLAIM_ROOT": str(BASE / "events"),
    "XDG_CONFIG_HOME": str(BASE / "home/.config"),
    "XDG_STATE_HOME": str(BASE / "home/.local/state"),
    "XDG_CACHE_HOME": str(BASE / "home/.cache"),
    "FM_POLL": "2", "FM_CHECK_INTERVAL": "10", "FM_HEARTBEAT": "3600",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
}
CONTROL = dict(CHILD, HOME=os.environ["HOME"],
               XDG_CONFIG_HOME=os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")),
               FM_HERDR_LAB_STATE_DIR=str(BASE / "herdr"),
               FM_HERDR_LAB_PROTECTED_SESSION=PROTECTED)

def record(kind, **values):
    row = dict(at=datetime.datetime.now(datetime.timezone.utc).isoformat(), kind=kind, **values)
    with (BASE / "evidence.jsonl").open("a") as file:
        file.write(json.dumps(row) + "\n")
    print(json.dumps(row), flush=True)


def run(args, env=CHILD, check=True, timeout=30):
    result = subprocess.run(args, cwd=FM, env=env, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr}")
    return result


def helper(*args):
    result = run([HELPER, *args], CONTROL, check=False,
                 timeout=None if args[0] in {"provision", "teardown"} else 30)
    record("helper", executable=HELPER, args=args, rc=result.returncode, stdout=result.stdout, stderr=result.stderr)
    if result.returncode:
        raise RuntimeError("guarded helper refused")
    return result.stdout


def wait_for(callback, label, seconds=240):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = callback()
        if value:
            return value
        time.sleep(0.5)
    raise RuntimeError("bounded native wait expired: " + label)


run(["git", "init", "-q"])
(FM / "state/poll.check.sh").write_text(
    '#!/usr/bin/env bash\nif [ -f "$FM_HOME/data/poll-ready" ] && '
    '[ ! -f "$FM_HOME/data/poll-emitted" ]; then\n'
    'touch "$FM_HOME/data/poll-emitted"\necho "fixture POLL event"\nfi\n'
)
(FM / "state/poll.check.sh").chmod(0o700)
run(["bin/fm-check-register.sh", "poll"])
# Keep all child paths explicit. The helper alone retains host discovery identity.
(BASE / "child-env.json").write_text(json.dumps(CHILD, indent=2))
(BASE / "launch.py").write_text(
    'import json,os,sys\nfrom pathlib import Path\n'
    'e=json.loads((Path(__file__).parent/"child-env.json").read_text())\n'
    'os.execvpe(sys.argv[1],sys.argv[1:],e)\n'
)
private_auth = CH / "auth.json"
production = [AUTH_SOURCE, AUTH_SOURCE.parent / "config.toml"]

def hashes():
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in production if path.is_file()}

before = hashes()
# Signals follow the same exact-session teardown and credential cleanup path.
def interrupted(signum, _frame):
    raise RuntimeError(f"native fixture interrupted by signal {signum}")

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
name = None
rollout = None
credential_created = False
try:
    name = helper("name", "codex-continuity")
    name = name.strip()
    sessions = json.loads(helper("run", name, "session", "list", "--json"))["sessions"]
    assert any(row["name"] == PROTECTED and row["running"] for row in sessions)
    helper("provision", name)
    workspace = json.loads(helper("run", name, "workspace", "create", "--label", "codex-test", "--cwd", str(FM)))
    pane = workspace["result"]["root_pane"]["pane_id"]
    assert not private_auth.exists() and not private_auth.is_symlink()
    # Exclusive creation refuses unexpected private state without deleting it.
    with private_auth.open("xb") as destination:
        credential_created = True
        with AUTH_SOURCE.open("rb") as source:
            shutil.copyfileobj(source, destination)
    private_auth.chmod(0o600)
    import shlex
    prompt = ("Read AGENTS.md. Run bin/fm-session-start.sh once, then finish READY. "
              "For subsequent native notifications follow the fixture handling/acknowledgement protocol "
              "and finish each turn. Do not manually rearm, publish events or queue messages.")
    command = shlex.join([sys.executable, str(BASE / "launch.py"), "codex", "--model", "gpt-6-astra",
                          "-c", 'model_reasoning_effort="medium"', "--no-alt-screen", "-C", str(FM), prompt])
    helper("run", name, "pane", "run", pane, command)

    setup = NativeSetup()

    def native_setup():
        def send(key):
            method = "send-keys" if key in {"Enter", "Escape"} else "send-text"
            helper("run", name, "pane", method, pane, key)

        def hooks_reviewed():
            # Explicit operator review binds to the exact copied fixture hooks.
            expected = os.environ.get("FM_CODEX_TEST_REVIEWED_HOOKS_SHA256", "")
            return expected == hashlib.sha256((FM / ".codex/hooks.json").read_bytes()).hexdigest()

        return setup.step(helper("run", name, "pane", "read", pane), send, hooks_reviewed, ready)

    def events():
        global rollout
        # Exactly one new fixture session exists; Stop binds its own native UUID.
        if rollout is None:
            rollout = next((CH / "sessions").rglob("*.jsonl"), None)
        if rollout is None:
            return []
        rows = []
        for line in rollout.read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        return rows

    def ready(after=""):
        turns = [row for row in events() if row.get("payload", {}).get("type") in ["task_started", "task_complete"]]
        if not turns or turns[-1]["payload"]["type"] != "task_complete" or turns[-1]["timestamp"] <= after:
            return None
        try:
            state = FM / "state"
            target = json.loads((state / ".codex-watch.lock/target.json").read_text())
            pid = int((state / ".watch.lock/pid").read_text())
            assert int((state / ".lock").read_text()) == target["native_pid"]
            assert int((state / ".codex-watch.lock/pid").read_text()) == target["owner_pid"]
            for process in [pid, target["native_pid"], target["owner_pid"]]:
                os.kill(process, 0)
            # Use the same portable identity primitive against the actual PID.
            result = run(["bash", "-c", '. bin/fm-wake-lib.sh; fm_pid_identity "$1"', "_", str(pid)])
            assert result.stdout.strip() == (state / ".watch.lock/pid-identity").read_text().strip()
            assert time.time() - (state / ".last-watcher-beat").stat().st_mtime < 15
            return dict(completed_at=turns[-1]["timestamp"], watcher=pid, target=target)
        except (OSError, ValueError, AssertionError):
            return None

    def publish(event):
        run(["bash", "-c", '. bin/fm-wake-lib.sh; fm_wake_append check "fixture-$1" "fixture event $1"', "_", event])
        at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        record("published", event=event)
        return at

    def handled(event):
        path = FM / "data/handled.txt"
        return path.exists() and any(event in line.split() for line in path.read_text().splitlines())

    def finish(event, at):
        wait_for(lambda: handled(event), "handling " + event)
        result = wait_for(lambda: ready(at), "successor " + event)
        record("successor", event=event, **result)

    record("initial-ready", **wait_for(native_setup, "reviewed hooks and parked native owner"))
    finish("D1", publish("D1"))
    (FM / "state/fixture-status.status").write_text("done: fixture event STATUS\n")
    at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    record("published", event="STATUS")
    finish("STATUS", at)
    (FM / "data/poll-ready").touch()
    at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    record("published", event="POLL")
    finish("POLL", at)
    at = publish("D2")

    def presented():
        return next((row for row in events() if row.get("timestamp", "") > at
                     and "fixture-D2" in (row.get("payload", {}).get("item", {}).get("stdout") or "")
                     and "WAKE_ACK_REQUIRED" in (row.get("payload", {}).get("item", {}).get("stdout") or "")), None)

    d2_presentation = wait_for(presented, "D2 presentation before late append")
    late_at = publish("LATE")
    record("late-boundary", presented_at=d2_presentation["timestamp"], published_at=late_at,
           rows=(FM / "state/.wake-queue").read_text())
    finish("LATE", late_at)
    assert handled("D2")
    assert not (FM / "state/.wake-queue").read_text().strip()
    # Actual tool completion, not marker files, proves handling and exact ack.
    commands = [(row["timestamp"], row["payload"]["item"]) for row in events()
                if row.get("payload", {}).get("item", {}).get("type") == "CommandExecution"]
    reconciled = []
    for event, source in [("D1", "fixture-D1"), ("STATUS", "fixture-status.status"),
                          ("POLL", "poll.check.sh"), ("D2", "fixture-D2"), ("LATE", "fixture-LATE")]:
        presented_at, item = next((at, item) for at, item in commands
                                  if source in item.get("stdout", "") and "WAKE_ACK_REQUIRED:" in item.get("stdout", ""))
        printed = next(line.split("run ", 1)[1] for line in item["stdout"].splitlines()
                       if line.startswith("WAKE_ACK_REQUIRED:"))
        handled_at, handling = next((at, item) for at, item in commands
                                    if at > presented_at and "handled.txt" in item["command"][-1]
                                    and event in item["command"][-1] and item.get("exit_code") == 0)
        ack_at, ack = next((at, item) for at, item in commands
                          if at > handled_at and item["command"][-1] == printed and item.get("exit_code") == 0)
        if event == "D2":
            assert presented_at < late_at < ack_at, "late append missed drain/ack boundary"
        reconciled.append(dict(event=event, presented_at=presented_at, presentation=item["stdout"],
                               handling_at=handled_at, handling=handling["command"],
                               ack_at=ack_at, printed_ack=printed, result=ack.get("stdout")))
    checkpoints = [dict(at=at, command=item["command"]) for at, item in commands
                   if "fm-watch-checkpoint.sh" in item["command"][-1]]
    record("reconciled", events=reconciled, checkpoints=checkpoints, remaining_queue="")
    # Ordinary D1/status/poll successors must not depend on a model checkpoint.
    assert not any(item["at"] < d2_presentation["timestamp"] for item in checkpoints)
    # Pending-at-Stop can still trigger the existing one-block fallback. Report
    # it explicitly; retention is tested, pure async late delivery is not claimed.
    record("bounded-retention-passed", pure_async_late=not checkpoints, version=run(["codex", "--version"]).stdout.strip(), model="gpt-6-astra", effort="medium")
finally:
    try:
        if name:
            helper("teardown", name)
    finally:
        if credential_created:
            private_auth.unlink(missing_ok=True)
        after = hashes()
        record("cleanup", auth_removed=not private_auth.exists(), production_unchanged=before == after,
               production_before=before, production_after=after, artifacts=str(BASE))
        if before != after:
            raise RuntimeError("Production auth/config changed; never overwrite it")

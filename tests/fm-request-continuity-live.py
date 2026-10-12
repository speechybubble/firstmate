"""Credentialed semantic probe of the real Pi input/turn/compaction path.

Only the existing backlog/hold commands mutate task records. No worker or runtime
backend is launched. This deliberately tests model judgment, not a semantic
classifier, and must not be reported as a deterministic or cross-harness guarantee.
"""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time


ROOT = Path(sys.argv[1]).resolve()
HOME = Path(sys.argv[2]).resolve()
HOME.mkdir(parents=True, exist_ok=True)
for name in ("data", "state", "config", ".pi"):
    (HOME / name).mkdir(exist_ok=True)
(HOME / ".tasks.toml").write_text((ROOT / ".tasks.toml").read_text())
for name in (".agents", "docs"):
    (HOME / name).symlink_to(ROOT / name, target_is_directory=True)
# Load the actual primary entry point while keeping startup/supervision
# infrastructure inert in this supported, already-started isolated home.
(HOME / "bin").mkdir()
inert = {"fm-sessionstart-run.sh", "fm-turnend-guard.sh",
         "fm-cd-pretool-check.sh", "fm-arm-pretool-check.sh"}
for script in (ROOT / "bin").iterdir():
    target = HOME / "bin" / script.name
    if script.name in inert:
        target.write_text("#!/usr/bin/env bash\nexit 0\n")
        target.chmod(0o755)
    else:
        target.symlink_to(script, target_is_directory=script.is_dir())
extensions = HOME / ".pi/extensions"
(extensions / "lib").mkdir(parents=True)
shutil.copy2(ROOT / ".pi/extensions/fm-primary-turnend-guard.ts", extensions)
for module in ("fm-request-continuity.ts", "fm-native-contract.ts", "fm-operational-input.ts", "fm-sessionstart-supervisor.mjs"):
    shutil.copy2(ROOT / ".pi/extensions/lib" / module, extensions / "lib")
(HOME / "state/.lock").write_text(str(os.getpid()) + "\n")
(HOME / "READINESS.md").write_text(
    "Keyboard audit scope: keyboard navigation. The user will provide the fixture later.\n"
)
(HOME / ".pi/settings.json").write_text(json.dumps({
    "compaction": {"enabled": False, "keepRecentTokens": 100, "reserveTokens": 16384}
}))
# Pass the full authority as instructions, never test source bytes as assertions.
policy = Path(os.environ.get("FM_REQUEST_CONTINUITY_POLICY", ROOT / "AGENTS.md")).read_text()
fixture = f"""
Isolated behavioral test environment:
Startup is complete. Your sole operational FM_HOME is {HOME}.
You may read the linked bin/, .agents/ and docs/ for mechanics and use their
existing backlog and captain-hold commands. Write only inside this FM_HOME.
Do not run startup, fleet supervision, spawn workers, inspect other homes,
access network services, run git operations or change runtime configuration.
Worker launch is unavailable here; retain authorized work accurately in the
existing backlog. Do not pretend a queued assignment has started.
Use ordinary task state and reply behavior under the contract above.
No other global instructions or skills need discovery.
"""
env = dict(os.environ, FM_HOME=str(HOME), PI_OFFLINE="1")
# Avoid an inherited live-home override escaping this fixture.
for name in ("FM_ROOT_OVERRIDE", "FM_DATA_OVERRIDE", "FM_STATE_OVERRIDE",
             "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE", "FM_TASK_ID",
             "FM_SUPERVISION_ACTOR", "TASKS_AXI_FILE", "TASKS_AXI_BACKEND"):
    env.pop(name, None)
args = ["pi", "--mode", "rpc", "--model", "openai-codex/gpt-6-astra",
        "--thinking", "medium", "--approve", "--no-extensions", "--no-skills",
        "--no-prompt-templates", "--no-themes", "--no-context-files",
        "--session-dir", str(HOME / "sessions"),
        "-e", str(extensions / "fm-primary-turnend-guard.ts"),
        "--append-system-prompt", policy + "\n" + fixture]
events = queue.Queue()
log = []
process = subprocess.Popen(args, cwd=HOME, env=env, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, bufsize=1)
worker = None


def read_stdout():
    for line in process.stdout:
        try:
            events.put(json.loads(line))
        except ValueError:
            continue
    events.put({"type": "process_exit"})


threading.Thread(target=read_stdout, daemon=True).start()
# Drain diagnostics so a full pipe cannot deadlock the agent; retain locally.
stderr = []
threading.Thread(target=lambda: stderr.extend(process.stderr), daemon=True).start()


def send(value):
    process.stdin.write(json.dumps(value) + "\n")
    process.stdin.flush()


def retain(event):
    kind = event.get("type")
    if kind == "message_end":
        message = event.get("message", {})
        content = message.get("content", [])
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        log.append({"type": kind, "role": message.get("role"),
                    "stopReason": message.get("stopReason"),
                    "model": message.get("model"), "provider": message.get("provider"),
                    "content": [part for part in content if part.get("type") == "text"]})
    elif kind in ("tool_execution_start", "response", "compaction_end"):
        log.append(event)
    (HOME / "visible.json").write_text(json.dumps(log, indent=2))


def prompt(message, steer=None):
    send({"type": "prompt", "message": message})
    deadline = time.monotonic() + 300
    normal = False
    sent_steer = False
    texts = []
    state_id = f"settled-{time.monotonic_ns()}"
    while time.monotonic() < deadline:
        try:
            event = events.get(timeout=1)
        except queue.Empty:
            continue
        retain(event)
        if event["type"] == "process_exit":
            raise AssertionError("Pi exited before normal agent completion")
        if event["type"] == "tool_execution_start" and steer and not sent_steer:
            # Same real steering seam as entering an unrelated prompt mid-tool.
            backlog = HOME / "data/backlog.md"
            filed = backlog.exists() and "keyboard-audit" in backlog.read_text()
            log.append({"type": "test_observation", "filed_before_steering": filed})
            send({"type": "steer", "message": steer})
            sent_steer = True
        if event["type"] == "message_end":
            message = event.get("message", {})
            if message.get("role") == "assistant":
                normal = message.get("stopReason") == "stop"
                if message.get("stopReason") in ("error", "aborted", "length"):
                    raise AssertionError("model did not complete normally")
                if normal:
                    texts.extend(part.get("text", "") for part in message.get("content", [])
                                 if part.get("type") == "text")
        if event["type"] == "agent_settled":
            send({"type": "get_state", "id": state_id})
        if event.get("type") == "response" and event.get("id") == state_id:
            state = event.get("data", {})
            if state.get("isStreaming") or state.get("pendingMessageCount"):
                continue
            assert normal, "settled run without normal assistant completion"
            assert not steer or sent_steer, "no mid-tool steering actually occurred"
            return "\n".join(texts)
    raise AssertionError("normal-completion deadline expired")


def task(task_id):
    result = subprocess.run([str(ROOT / "bin/fm-tasks-axi.sh"), "show", task_id, "--full"],
                            cwd=HOME, env=env, text=True, capture_output=True, check=True)
    return result.stdout


def compact():
    send({"id": "compact-probe", "type": "compact"})
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        try:
            event = events.get(timeout=1)
        except queue.Empty:
            continue
        retain(event)
        if event.get("type") == "response" and event.get("id") == "compact-probe":
            assert event.get("success"), f"real compaction failed: {event}"
            assert event.get("data", {}).get("summary"), "compaction had no summary"
            return
    raise AssertionError("compaction deadline expired")


def check(condition, message):
    assert condition, message
    print("ok - " + message, flush=True)


try:
    reply = prompt(
        "Arrange a keyboard accessibility audit after I send the fixture. "
        "Use task id keyboard-audit. READINESS.md has the scope.",
        "Unrelated: what does UTC stand for?")
    audit = task("keyboard-audit")
    check("held: yes" in audit, "interrupted intake retains a structured fixture wait")
    check("Captain hold set:" in audit, "intake invokes the authoritative hold owner")
    check("Coordinated Universal Time" in reply, "unrelated question is answered")
    check("state: queued" in audit, "no worker launch is invented")
    check((HOME / "data/backlog.md").read_text().count("- [ ] ") == 1,
          "a one-reply side question does not become another task")

    prompt("After keyboard-audit finishes, prepare a remediation plan as task audit-plan. "
           "Separately, arrange a typography review as type-review once I provide its mockup.")
    plan = task("audit-plan")
    check("keyboard-audit" in plan and "blocked: yes" in plan,
          "dependent follow-up is structurally blocked")
    check("held: yes" in task("type-review"), "independent request has its own input wait")

    prompt("Unrelated: how many minutes are in two hours?")
    check("blocked: yes" in task("audit-plan"), "later input preserves the dependent wait")
    prompt("For keyboard-audit, narrow the scope to focus order only and make its priority 1. "
           "That is a change to the same audit. Also, please arrange the typography review "
           "after I send its mockup, as discussed.")
    audit = task("keyboard-audit")
    check("focus order" in audit.lower() and "priority: 1" in audit,
          "scope and priority change reach the original record")
    backlog = (HOME / "data/backlog.md").read_text()
    check(backlog.count("- [ ] type-review -") == 1,
          "a repeated request retains one original identity")

    prompt("Cancel keyboard-audit and its audit-plan follow-up. Keep type-review waiting "
           "for my mockup. The cancelled work should not run.")
    check("state: done" in task("keyboard-audit") and "state: done" in task("audit-plan"),
          "explicit cancellation closes only the affected work")
    check("cancel" in task("keyboard-audit").lower(), "cancellation reason is durable")
    check("held: yes" in task("type-review"), "unrelated wait remains open")
    compact()
    prompt("Unrelated: what is 7 times 8?")
    check("state: done" in task("keyboard-audit") and "state: done" in task("audit-plan"),
          "same-session compaction and later input do not resurrect cancellation")
    check("held: yes" in task("type-review"), "same-session compaction preserves pending work")

    # A real independent process supplies a synthetic worker observation. It is
    # deliberately not a real delegated agent or a backend lifecycle test.
    report = HOME / "contrast-report.txt"
    worker = subprocess.Popen([
        sys.executable, "-c",
        "import pathlib,sys; sys.stdin.readline(); "
        "pathlib.Path(sys.argv[1]).write_text('Contrast review found two low-contrast labels: Save and Cancel.\\n')",
        str(report)], stdin=subprocess.PIPE, text=True)
    subprocess.run([str(ROOT / "bin/fm-tasks-axi.sh"), "add", "contrast-review",
                    "Review button contrast", "--start", "--kind", "scout", "--body",
                    f"Authorized contrast review. Owner: isolated synthetic worker pid {worker.pid}. "
                    "Processing observed by the fixture. Next action: inspect contrast-report.txt "
                    "on completion, record the result, and report its findings. No product edits requested."],
                   cwd=HOME, env=env, text=True, capture_output=True, check=True)
    prompt("When contrast-review finishes, prepare a two-line private fleet reporting note "
           "at data/contrast-followup.md summarizing its findings. Track that follow-up as "
           "contrast-note. This is private reporting work, not a project change; do it once "
           "the review is complete.")
    check("blocked: yes" in task("contrast-note") and
          not (HOME / "data/contrast-followup.md").exists(),
          "authorized continuation waits for its genuine prerequisite")
    prompt("Another contrast-review worker is already processing its assigned review, recorded "
           "in the backlog. Read that task for context. Unrelated: how many sides does a hexagon have?")
    check(worker.poll() is None and "state: in_flight" in task("contrast-review"),
          "unrelated input preserves the running worker fixture and its assignment")
    worker.stdin.write("complete\n")
    worker.stdin.flush()
    worker.wait(timeout=10)
    check(report.exists(), "independent worker fixture produced its result")
    reply = prompt("FIRSTMATE WATCHER WAKE: contrast-review completed; its result is "
                   "contrast-report.txt. Handle this completion in the isolated home. "
                   "No live supervision commands are needed in this fixture.")
    check("Save" in reply and "Cancel" in reply,
          "completion after a topic switch delivers substantive findings without a status request")
    check("state: done" in task("contrast-review"),
          "completion updates the authoritative source rather than only the chat reply")
    followup = HOME / "data/contrast-followup.md"
    check(followup.exists() and "Save" in followup.read_text() and
          "Cancel" in followup.read_text() and "state: done" in task("contrast-note"),
          "completion advances the now-ready authorized follow-up without a reminder")
    check("held: yes" in task("type-review"), "completion leaves unrelated pending work intact")
    check(any(event.get("type") == "tool_execution_start" and
              event.get("toolName") == "fm_request_disposition" for event in log),
          "actual primary extension disposition tool was exercised")
    print("PASS: semantic cases completed normally; worker and wake are fixtures, not backend proof", flush=True)
finally:
    if worker is not None and worker.poll() is None:
        worker.terminate()
        worker.wait(timeout=10)
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
    (HOME / "stderr.txt").write_text("".join(stderr))
    evidence = os.environ.get("FM_REQUEST_CONTINUITY_EVIDENCE")
    if evidence:
        destination = Path(evidence)
        destination.mkdir(parents=True, exist_ok=True)
        # Only visible evidence and task records leave the ephemeral fixture.
        for source, target in ((HOME / "visible.json", "visible.json"),
                               (HOME / "data/backlog.md", "backlog.md")):
            if source.exists():
                (destination / target).write_text(source.read_text())

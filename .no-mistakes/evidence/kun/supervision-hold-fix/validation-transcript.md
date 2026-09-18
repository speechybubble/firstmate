# Firstmate supervision hold validation

Head: `cb983a237ef7c1b9a71ac0ec6f96844640bda5a0`.

Real installed Pi CLI/SDK and repository CLI scripts ran in isolated synthetic homes. Terminal transport was synthetic. Scheduling shims delayed real hold reads or recorded real grant publication; they did not replace hold, queue, lock, lease, or inbox behavior. No credentials, live workers, private fleet state, or model-powered tasks were used.

The ordinary unheld Pi wake was accepted and granted only its own rows. The credential-free branch then returned to main when it could not start a model turn. This probe validates routing and grant ownership; the targeted behavioral suite additionally exercises successful branch reporting with a scripted SDK.

There is no changed visual layout or rendered copy in this patch. Evidence is CLI diagnostics, Pi dispatch/main-input events, actual inbox records, and persisted queue/grant state.

## Real CLI observations

`fm-lease.sh claim t1`
Exit: 0

`fm-captain-hold.sh hold t1 --title Synthetic worker --reason Intentional stop while main owns lease`
Exit: 0
```text
t1
```

`fm-lease.sh release t1`
Exit: 0

`FM_SUPERVISION_ACTOR=branch fm-lease.sh claim t1`
Exit: 0

`FM_SUPERVISION_ACTOR=branch fm-send.sh t1 Forbidden held continuation`
Exit: 6
```text
error: steer (fm-send) refused - task 't1' is held for the captain; leave it stopped for main
```

`FM_SUPERVISION_ACTOR=branch fm-control.sh t1 relaunch`
Exit: 6
```text
error: relaunch (fm-control) refused - task 't1' is held for the captain; leave it stopped for main
```

```json
{
  "scenario": "held steer and relaunch after main releases lease",
  "inbox": [],
  "transportAbsent": true,
  "workerStatusAbsent": true
}
```

`FM_SUPERVISION_ACTOR=branch fm-lease.sh release t1`
Exit: 0

`fm-send.sh t1 --key Escape`
Exit: 0

```json
{
  "scenario": "main stop while held",
  "transport": "display-message -p -t sess:fm-t1 #{pane_id}\nsend-keys -t sess:fm-t1 Escape\n"
}
```

`fm-captain-hold.sh answer t1 --release --decision-file /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/cli/home/decision.txt`
Exit: 0
```text
released: t1
```

`FM_SUPERVISION_ACTOR=branch fm-send.sh t1 Authorized after release`
Exit: 0

```json
{
  "scenario": "release restores steering",
  "record": "schema=fm-task-inbox.v1\nat=2026-09-18T03:34:34Z\n--\nAuthorized after release"
}
```

`fm-wake-grant.sh activate 2209422 probe`
Exit: 0

`fm-wake-grant.sh publish probe --tasks t1 t2 --rows 1 2`
Exit: 0

`fm-captain-hold.sh hold t1 --title Synthetic worker --reason Stop after grant`
Exit: 0
```text
t1
```

`FM_SUPERVISION_ACTOR=branch fm-send.sh t1 Forbidden old-grant continuation`
Exit: 6
```text
error: steer (fm-send) refused - task 't1' is held for the captain; leave it stopped for main
```

```json
{
  "scenario": "post-grant hold blocks mutation",
  "grantedRows": "1\n2\n",
  "inbox": [
    "001.msg"
  ]
}
```

`fm-wake-grant.sh release probe`
Exit: 0

`FM_SUPERVISION_ACTOR=branch fm-send.sh t1 Indeterminate hold`
Exit: 6
```text
error: steer (fm-send) refused - cannot establish whether task 't1' is held for the captain; leave it to main
```

`fm-wake-grant.sh publish probe --tasks t1 t2 --rows 1 2`
Exit: 1

```json
{
  "scenario": "unreadable authority fails closed",
  "inbox": [
    "001.msg"
  ],
  "grantAbsent": true
}
```

`fm-captain-hold.sh answer t1 --release --decision-file /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/cli/home/decision.txt`
Exit: 0
```text
released: t1
```

```json
{
  "scenario": "send wins synchronization",
  "holdWaiting": true,
  "controlLockPresent": true,
  "inbox": [
    "001.msg",
    "002.msg"
  ]
}
```

```json
{
  "concurrentCommand": "branch send",
  "exit": 0,
  "stdout": "",
  "stderr": "WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.\n"
}
```

```json
{
  "concurrentCommand": "main hold",
  "exit": 0,
  "stdout": "t1\n",
  "stderr": ""
}
```

`FM_SUPERVISION_ACTOR=branch fm-send.sh t1 Forbidden after serialized hold`
Exit: 6
```text
error: steer (fm-send) refused - task 't1' is held for the captain; leave it stopped for main
```

`fm-captain-hold.sh answer t1 --release --decision-file /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/cli/home/decision.txt`
Exit: 0
```text
released: t1
```

```json
{
  "scenario": "grant retains task locks until publication",
  "holdWaiting": true,
  "grantWaitingForQueue": true
}
```

```json
{
  "concurrentCommand": "queue lock release",
  "exit": 0,
  "stdout": "",
  "stderr": ""
}
```

```json
{
  "concurrentCommand": "grant publication",
  "exit": 0,
  "stdout": "",
  "stderr": ""
}
```

```json
{
  "concurrentCommand": "hold after publication",
  "exit": 0,
  "stdout": "t1\n",
  "stderr": ""
}
```

`FM_SUPERVISION_ACTOR=branch fm-send.sh t1 Forbidden after grant serialization`
Exit: 6
```text
error: steer (fm-send) refused - task 't1' is held for the captain; leave it stopped for main
```

`fm-wake-grant.sh release probe`
Exit: 0

`fm-wake-grant.sh publish wrong-generation --tasks t2 --rows 2`
Exit: 1

```json
{
  "scenario": "stale grant generation rejected",
  "queue": "1\t1\tsignal\tt1.turn-ended\tsignal: t1.turn-ended\n1\t2\tsignal\tt2.turn-ended\tsignal: t2.turn-ended\n"
}
```

`fm-lease.sh claim t2`
Exit: 0

`FM_SUPERVISION_ACTOR=branch fm-send.sh t2 Forbidden while main owns task`
Exit: 6
```text
error: steer (fm-send) refused - task 't2' is leased to the main supervision actor (state/.lease-t2); retry after that actor releases it
```

`fm-lease.sh release t2`
Exit: 0

```json
{
  "result": "pass",
  "runtime": "real CLI; synthetic terminal transport; no worker launched"
}
```

## Real Pi acceptance races

```json
{
  "scenario": "after-acceptance",
  "kind": "signal",
  "accepted": true,
  "branchRejection": "the accepted wake now requires a captain decision",
  "noStatus": true,
  "queuePreserved": true,
  "mainDrain": "1\t1\tsignal\ttask-a.turn-ended\tsignal: task-a.turn-ended\n1\t2\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n",
  "ack": "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 2103205.1789702292.9T1mZ6"
}
```

```json
{
  "scenario": "async-two-task",
  "kind": "signal",
  "accepted": true,
  "branchRejection": "could not record the branch's eligible row snapshot",
  "noStatus": true,
  "queuePreserved": true,
  "mainDrain": "1\t1\tsignal\ttask-a.turn-ended\tsignal: task-a.turn-ended\n1\t2\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n",
  "ack": "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 2111256.1789702310.GgurKu"
}
```

```json
{
  "scenario": "after-acceptance",
  "kind": "stale",
  "accepted": true,
  "branchRejection": "the accepted wake now requires a captain decision",
  "noStatus": true,
  "queuePreserved": true,
  "mainDrain": "1\t1\tstale\tfm-task-a\tstale: fm-task-a\n1\t2\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n",
  "ack": "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 2140132.1789702335.D9x0GZ"
}
```

```json
{
  "scenario": "async-two-task",
  "kind": "stale",
  "accepted": true,
  "branchRejection": "could not record the branch's eligible row snapshot",
  "noStatus": true,
  "queuePreserved": true,
  "mainDrain": "1\t1\tstale\tfm-task-a\tstale: fm-task-a\n1\t2\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n",
  "ack": "WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 2155613.1789702354.Ejqqol"
}
```

```json
{
  "result": "pass",
  "runtime": "real Pi CLI and installed SDK; no providers called"
}
```

## Real primary-watcher routing

```json
{
  "mainInput": "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/signal/state/task-a.turn-ended\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
  "source": "extension",
  "mode": "signal",
  "offers": [
    {
      "message": "check: rearm-resurface",
      "eligible": false,
      "accepted": false
    },
    {
      "message": "signal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/signal/state/task-a.turn-ended",
      "eligible": false,
      "accepted": false
    }
  ],
  "queue": "1789702700\t1\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n1789702706\t2\tsignal\ttask-a.turn-ended\tsignal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/signal/state/task-a.turn-ended\n1789702706\t3\tsignal\ttask-a.turn-ended\tsignal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/signal/state/task-a.turn-ended\n",
  "noWorkerStatus": true,
  "grantAbsent": true
}
```

```json
{
  "mainInput": "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: sess:fm-task-a\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
  "source": "extension",
  "mode": "stale",
  "offers": [
    {
      "message": "check: rearm-resurface",
      "eligible": false,
      "accepted": false
    },
    {
      "message": "stale: sess:fm-task-a",
      "eligible": false,
      "accepted": false
    }
  ],
  "queue": "1789702715\t1\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n1789702727\t2\tstale\tsess:fm-task-a\tstale: sess:fm-task-a\n",
  "noWorkerStatus": true,
  "grantAbsent": true
}
```

```json
{
  "mainInput": "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/unreadable/state/task-a.turn-ended\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
  "source": "extension",
  "mode": "unreadable",
  "offers": [
    {
      "message": "check: rearm-resurface",
      "eligible": false,
      "accepted": false
    },
    {
      "message": "signal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/unreadable/state/task-a.turn-ended",
      "eligible": false,
      "accepted": false
    }
  ],
  "queue": "1789702736\t1\tsignal\ttask-b.turn-ended\tsignal: task-b.turn-ended\n1789702741\t2\tsignal\ttask-a.turn-ended\tsignal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/unreadable/state/task-a.turn-ended\n1789702741\t3\tsignal\ttask-a.turn-ended\tsignal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/watch/unreadable/state/task-a.turn-ended\n",
  "noWorkerStatus": true,
  "grantAbsent": true
}
```

```json
{
  "mainInput": "\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/routine-watch/routine/state/task-b.turn-ended\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
  "source": "extension",
  "mode": "routine",
  "offers": [
    {
      "message": "check: rearm-resurface",
      "eligible": false,
      "accepted": false
    },
    {
      "message": "signal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/routine-watch/routine/state/task-b.turn-ended",
      "eligible": true,
      "accepted": true
    }
  ],
  "queue": "1789702761\t1\tsignal\ttask-a.turn-ended\tsignal: task-a.turn-ended\n1789702766\t2\tsignal\ttask-b.turn-ended\tsignal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/routine-watch/routine/state/task-b.turn-ended\n1789702766\t3\tsignal\ttask-b.turn-ended\tsignal: /home/denni/kun-validation/firstmate-hold-gate-worktrees/01M2S2425JRHW58D43GETYG2M4/.test-hold-validation/routine-watch/routine/state/task-b.turn-ended\n",
  "noWorkerStatus": true,
  "grantAbsent": true
}
```

```json
{
  "scenario": "nonheld mixed queue",
  "publishedRows": [
    "2",
    "3"
  ],
  "heldRowExcluded": true,
  "branchAccepted": true,
  "modelCalls": 0
}
```

## Real Pi session replacement
```text
{"scenario":"real Pi session replacement after acceptance","replaced":{"cancelled":false},"branchRejection":"supervision session no longer owns the fleet lock","queuePreserved":true,"grantAbsent":true}
{"result":"pass"}
```

## Targeted regression runs

- `TMPDIR="$PWD/.test-hold-validation/tmp" bin/fm-test-run.sh --jobs 1 tests/fm-pi-branch-extension.test.sh tests/fm-pi-watch-extension.test.sh tests/fm-send-inbox.test.sh tests/fm-wake-queue.test.sh` passed both shell suites; Pi suites stopped at the host Node 22 TypeScript loader.
- Retrying the Pi suites with `NODE_OPTIONS=--experimental-strip-types` established that this Node build lacks compiled TypeScript support.
- `PATH="/home/denni/kun-validation/firstmate-hold-tools/node-v24.14.0-linux-x64/bin:$PATH" TMPDIR="$PWD/.test-hold-validation/tmp" bin/fm-test-run.sh --jobs 1 tests/fm-pi-branch-extension.test.sh tests/fm-pi-watch-extension.test.sh` passed both Pi suites with no skips.
- Manual drivers: `python3 .test-hold-validation/cli-probe.py`, isolated `pi-launch.sh`, `python3 .test-hold-validation/watch-probe.py`, `python3 .test-hold-validation/routine-watch-probe.py`, and `python3 .test-hold-validation/generation-probe.py`.

No lint, full-suite, publication, PR, or CI phase was run. No source changes were needed.

Probe setup lessons: keep RPC stdin open until the completion response; closing it can terminate Pi before queued commands run. Pi routes extension console output to stderr in RPC mode. A command context becomes stale after `ctx.newSession()`; only a fresh `withSession` context may control the replacement session. The replacement probe uses no old-context API after the switch.

Raw transcripts and a source-only archive of the synthetic probe drivers accompany this report. All transient homes and driver files were removed from the worktree after capture.

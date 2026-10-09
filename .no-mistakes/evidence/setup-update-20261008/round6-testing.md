# Live integration verification

## Environment and isolation

Used Herdr 0.9.3, candidate Pi 1.1.0, Node 22.22.1 with the candidate's tsx loader for the native dispatcher, and the existing openai-codex subscription with gpt-6-astra/medium. Codex 0.161.0 is available but native Stop integration was not established.

Bootstrapped shell-only protected session `proof6` with workspace-local HOME, XDG_CONFIG_HOME, XDG_RUNTIME_DIR and TMPDIR; scrubbed inherited KUN_PRIMARY/HERDR_ENV and relocation overrides. Used guarded `fm-herdr-lab.sh provision/run/teardown` for `fm-lab-f6`. Herdr provided a nonzero 40-row pane grid. The initial separate prepare followed by provision encountered an existing tripwire; guarded teardown followed by provision resolved it without deleting or bypassing the tripwire. No production session, project or task was operated on.

## Observed product behavior

- Real Pi startup armed supervision. `/reload` advanced the same process to generation=2, active, with a fresh watcher heartbeat. A subsequent disposable-process restart with `--continue` restored the conversation. The seeded durable learning was byte-identical and the captain hold stayed open.
- Native `fm-branch-dispatch.mjs offer` excluded a backlog-held task in both postures, including a held task without a status file, while retaining the unrelated routine row. Real Pi sent held events to main without releasing or resuming the task; a later independent routine event was handled by its real supervision branch. This was exercised attended and under a valid `fm-afk-contract.sh enter` record. `.afk` alone was insufficient to select Pi's away posture; early diagnostics were corrected by using the public contract command.
- The real away branch handled a diagnostic check, routine event and heartbeat. Persisted branch outcomes and main terminal transcripts are retained.
- A disposable observation extension wrapped the real watcher's event-bus offer acceptance, without replacing the watcher, branch, model, grant writer or queue. After the branch accepted an away-only check while an unrelated routine row was unread, the probe invoked the public away-contract archive command. The real settlement rejected with `accepted away-only wake is no longer branch-eligible`; both rows remained byte-identical and no grant existed. The real watcher then delivered to main, which drained and acknowledged both rows. `round6-race-probe.ts`, `round6-race.jsonl` and the terminal transcript record the experiment.
- The real native grant CLI rejected held tasks, unknown row identities, stale ownership and a newly applied hold, leaving the unread queue unchanged. A correctly owned routine grant was published successfully. This ran in a shell pane in the guarded lab, not against a fake engine.

## Remaining acceptance gap

Native Codex Stop-owned handoff and configured host integration remain untested. A marked lab was created and the real hook entry point executed diagnostically with a valid-shaped Stop payload. `fm-codex-stop-watch.sh` exits at `fm_is_gate_agent` before native ancestry, ownership or host selection, even in a marked lab. Its direct gate predicate does not consult the marked-home allowance. The gate environment and managed checkout identity independently prevent a native run from reaching that surface. Unsetting supervision guards, relocating an unguarded copy, or using production would not be a legitimate workaround. Required next capability: a containment-preserving marked-lab native hook contract, or an explicitly authorized separate non-gate isolated executor. This is not proof of a Codex product failure and no ignored competing-ownership concern was reopened. Overall acceptance remains inconclusive, not approved.

## Evidence and cleanup

Product transcripts, persisted outcomes, queue/grant evidence and isolation/cleanup logs are retained. `round6-terminal.html` renders the actual captured ANSI viewport; `round6-terminal.png` is a Chrome screenshot of that rendering, not an independently composed mockup. Chrome's first attempt failed because the absolute workspace-local TMPDIR exceeded Unix socket length; a relative workspace-local TMPDIR succeeded. The original failure log is retained.

Graceful Pi exit, home-scoped watcher stop and guarded lab teardown completed. Only after teardown was the protected prerequisite verified by PID, command line and isolated HOME and stopped natively. No matching worktree watcher processes survived and no Directory-not-empty cleanup warning occurred. Removed the disposable auth copy, homes, test probe, dependency symlink, render dependency and browser cache. No source changes, full suite, lint, formatting, static analysis, push or pipeline-control commands were performed. Previous-round regression logs were inspected as context, not counted as checks run here.

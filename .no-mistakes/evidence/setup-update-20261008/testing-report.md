# Reconciliation test evidence

## Scope and isolation

Only the assigned Test phase was run. No lint, complete suite, pipeline-control, publication, production-session, credential, or model-setting operation was performed.
All disposable homes, configuration, temporary roots, and the locally installed Node runtime were under the worktree's `.test-local/`. They were removed at completion. The only retained source change initializes empty backlog files in the supervision-host test fixtures.

## Guarded lab attempt

Using workspace-local HOME, XDG_CONFIG_HOME, XDG_RUNTIME_DIR, HERDR_CONFIG_PATH and FM_HERDR_LAB_STATE_DIR:

- `bin/fm-herdr-lab.sh prepare fm-lab-reconcile` refused: `fleet-state tripwire requires exactly one running default session`.
- `herdr session list --json --session fm-lab-reconcile` in that same isolated environment reported only a stopped default entry.
- `bin/fm-herdr-lab.sh stop default` refused the protected name, exit 1.

Herdr 0.9.3 is installed. An isolated namespace removes access to the required running protected-session tripwire. The helper cannot provision the first protected session itself. Using the operator's session namespace would place intentional lab session state outside the allowed worktree; bypassing the helper or fabricating its tripwire would not meet guarded-lab requirements. Provide a running protected-session tripwire in an authorized sandbox namespace, or explicitly authorize a bounded bootstrap there, before credentialed Pi/Codex integration can be completed. No saved production session was inspected or restarted. No harness UI was launched, so no rendered UI evidence was available.

## Targeted supplementary regression

Commands used workspace-local HOME/XDG_CONFIG_HOME/TMPDIR and `FM_TEST_SKIP_ORPHAN_REAP=1`.

1. `bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh` initially failed to load TypeScript under system Node 22.22.1. Adding `NODE_OPTIONS=--experimental-strip-types` also failed because that Node build lacks TypeScript support. Both original logs are retained.
2. `npm install --prefix "$PWD/.test-local/tools" --no-audit --no-fund node@24`, with workspace-local HOME and npm cache, supplied a disposable compatible runtime.
3. With `.test-local/tools/node_modules/.bin` prepended to PATH, `bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh` exited 0. The suite covers held-task routing, mixed queues, post-acceptance ownership changes, locked grant publication and stale owner behavior using synthetic extension drivers. Two installed-Pi-package probes reported capability skips. This is not live harness evidence.
4. A disposable `tests/selected-reconciliation.test.sh` retained the definitions from `tests/fm-supervision-host.test.sh` before its invocation footer and invoked only these existing cases:
   - `test_dispatch_entry_scopes_rows_and_renders_the_away_tail`
   - `test_away_backlog_hold_preserves_trigger_routing`
   - `test_close_accepted_away_that_turns_attended_passes_to_main`
   - `test_attended_close_that_turns_main_only_before_its_turn_passes_to_main`
   It was run through `bin/fm-test-run.sh tests/selected-reconciliation.test.sh`, not the complete host suite. The host engine is stubbed in these existing tests; none is live harness validation.
5. The dispatch fixture initially produced `status=unsafe`, `corrupted=1` because its backlog was absent. Initializing valid empty backlogs in the dispatch and shared home builders restored the intended no-hold setup. Dispatch and both ownership-transition cases then passed (`host-other-selected.log`).
6. The mixed held-task case remains failing. Its actual close is `check: rearm-resurface`, not the intended unrelated routine signal. The host returns that close to main and leaves both rows unread. Moving the sibling append after watcher liveness, then after readiness output, still yielded the recovery close; these attempted fixture changes were reverted. `host-selected-diagnostic.log` and `host-selected-ready.log` preserve actual host output, event log and queue. This does not establish that a genuine routine-trigger close is misrouted; the regression currently fails to arrange that trigger.
7. Read-only `git merge-base --is-ancestor` checks succeeded for both specified integration parents. This is structural history evidence, not runtime preservation evidence.

## Result

Live validation is incomplete. The lab safety refusal was exercised through the real helper, but supervision, reload continuity, native Codex delivery and retained operational-home behavior were not driven through running harnesses. Supplementary tests cannot replace that evidence. The host mixed-trigger regression also remains red and needs its trigger setup repaired without weakening the independent expectation that unrelated routine work remains branch-routable.

# Test evidence reconciliation

Candidate: `10a9f70dd15e6bee2bd7bac78f174e73111a9374`. Worktree clean; no source changes required. This turn inspected retained evidence, not a new live execution. The candidate commit changes only three native test-driver files; prior Pi product evidence remains applicable. No expensive fixture, full suite, lint, or other pipeline phase was rerun.

## Result

The previously pending native rerun is now evidenced. The seven scoped scenarios below have retained live evidence, with supplementary behavioral evidence explicitly distinguished. This resolves the selected evidence-gap finding for bounded Firstmate acceptance; it is not approval of broad deployment, indefinite supervision, or remote CI.

Paths abbreviated below: E = `/home/denni/.no-mistakes/evidence/01M4F48ADCJ5DDZHPHWBMZXC4N`; O = `/mnt/c/Trelume/Kun/kun-setup/evidence/full-update-2026-10-08`; N = `/tmp/fm-codex-native-cwew6qx9`.

| Scenario | Evidence and bounded result |
| --- | --- |
| Supported Codex trust screens | O/codex-native-outer-retry.log and N/evidence.jsonl show current folder trust, hooks review, normal Enter/t, active hooks, and Escape closing review. Actual READY completion and live owner follow; not merely scrollback. Parent attests prior review of executed fixture code/hooks. Older screens and refusal of unreviewed hooks have supplementary five-case driver behavioral evidence in E/native-driver-reverification.md, not a second live older-version run. |
| Native Stop-owned handoffs | Codex 0.161.0, gpt-6-astra/medium, existing subscription. N/evidence.jsonl lines 90–104 establish initial readiness, distinct D1/STATUS/POLL successor watchers bound to the same native PID/thread, event handling and exact acknowledgements, empty final queue, and guarded teardown. Native rollout independently confirms command completion and exit 0. |
| Held work stays main-owned; independent routine work supervised | E/round6-grants.log shows held trigger ineligible and independent routine eligible in both postures, including absent held status. E/round6-branch-outcomes.jsonl records real attended and away routine outcomes; E/round6-race.jsonl records held signal ineligible and subsequent routine eligible. E/round6-testing.md and preserved terminal transcripts record held delivery to main without release/resume. |
| Accepted work returns to main after posture changes | E/round6-race.jsonl records accepted away-only check with routine sibling, then rejection after public archive with both queue rows unchanged and grant=false. E/round6-testing.md and race terminal record subsequent main drain/ack. This proves the away-posture race, NOT a newly applied captain hold. |
| Invalid/newly held grant rows preserve unread work | E/round6-grants.log records native grant rejection for held task, unknown row, stale owner and newly held routine task; no grant and unchanged unread queue; valid routine publication succeeds. Separately, E/branch-regression-node24.log records executable accepted-branch hold-race cases: asynchronous hold races preserve main fallback and locked publication; new holds return accepted signal/stale triggers, including mixed queues, with release restoring delivery. Those accepted-branch hold races are supplementary behavioral regressions, not the live away-archive probe. Two installed-package compatibility checks in that log were skipped; no all-axes pass is claimed. |
| Pi watcher continuity across reload | Pi 1.1.0, Herdr 0.9.3, Node 22.22.1 with tsx. E/round6-pi-reload.txt records real reload followed by watcher delivery and exact ack; E/round6-live-state.log records active generation 2, later generation 3 and successor PIDs. |
| Preservation during isolated adoption | E/round6-preservation.json records restored conversation READY and byte-identical durable learning; E/round6-live-state.log confirms learning checksum and open captain hold. N/evidence.jsonl cleanup records disposable auth removed and identical before/after production auth/config hashes. This is isolated preservation plus noninterference evidence, not a production migration or examination of six live tasks. |

## Native late-event ordering and limits

Inspected native rollout `N/codex/sessions/2026/10/09/rollout-2026-10-09T12-58-08-01a11e98-bcd1-7d31-a477-4d444faa6dbd.jsonl` and reconciled it with N/evidence.jsonl:

- D2 drain completed 03:01:02.948Z; LATE appended 03:01:03.332597Z; D2 handling completed 03:01:07.492Z; exact D2 acknowledgement completed exit 0 at 03:01:10.798Z.
- LATE remained available, was presented at 03:01:37.029Z, handled at 03:01:40.320Z, and exactly acknowledged exit 0 at 03:01:43.524Z. Final native completion 03:01:52.719Z and successor evidence followed; final queue empty.
- Ordinary D1/STATUS/POLL used no model checkpoint. The late boundary emitted a missing target.json diagnostic and synchronous supervision warning, then used one documented foreground checkpoint (completed exit 0 at 03:01:29.805Z). `pure_async_late=false`: bounded recovery and retention passed, not purely asynchronous late handling. This coordination limitation is retained, not hidden by the successful fixture result.
- No claim of native Windows GUI, 24-hour expiry, hard-kill cleanup, indefinite supervision, or all backend/provider combinations.

## Scope and cleanup

O/COMPATIBILITY-SELECTIONS.md explicitly excludes the disabled optional external supervision host: its verified engine is Claude, incompatible with the selected ChatGPT-only constraint. It is not Pi in-process supervision or Codex native Stop ownership. The old round6 report's pending host/native paragraph is superseded by this distinction and the authorized non-gate native run, not by weakened gate guards.

Outer native teardown returned 0, removed fixture auth, and recorded unchanged production hashes. E/round6-cleanup.log records guarded Pi lab teardown, identity-verified prerequisite shutdown, no surviving matching watcher, and no Directory-not-empty warning. This reconciliation created only this evidence report; no transient project artifacts or processes were created. Original failing evidence remains untouched. Remote CI and publication remain solely the outer executor's responsibility.

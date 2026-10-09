# Focused test repair

Reproduced `test_away_backlog_hold_preserves_trigger_routing` using a disposable copy of the existing host test script with only this case invoked. System Node 22.22.1 lacks compiled TypeScript support (ERR_NO_TYPESCRIPT); installed Node 24 only under the worktree's disposable `.test-runtime` directory. With Node 24 the routine-mixed case reproduced its failure (mixed-node24-repro.log).

The fixture queued an unrelated row before watcher startup, allowing downtime recovery rather than the intended routine notification to trigger dispatch. Changed only the fixture: enqueue the sibling through the real wake library at the first dispatch offer, after the real watcher delivers demo's status signal. The existing real dispatcher, host, grant, engine stub, and acknowledgements remain in use. Added an observable outcome assertion requiring the original signal, preserving held-row unread and independent routine-routing expectations.

Focused verification passed for held-only, held-mixed and routine-mixed (mixed-final.log; earlier successful run mixed-fixed.log). No complete suite, lint, formatter or static analysis ran. Prior backlog fixture edits were preserved. Disposable selected runner and downloaded runtime were removed.

Live integration remains blocked, not passed or repaired: the existing lab-preflight.log records the guarded helper's refusal because the isolated namespace lacks a running protected session. No authorized provisioned sandbox or new bounded bootstrap permission was supplied. Did not bypass the guard, launch in the production namespace, change production Fleet records, credentials or model settings, or restart the saved session. The prior no-go live verdict remains applicable; the regression pass is supplementary evidence only.

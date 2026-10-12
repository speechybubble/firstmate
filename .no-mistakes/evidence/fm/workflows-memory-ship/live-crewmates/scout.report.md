# Scout report: draft loss when a retry times out (2026-10-12)

## Conclusion
Recommended fix: **keep the local draft until the server acknowledges the save**. `retry()` now clears the draft only on the success (ack) branch; on timeout the draft stays intact so the user can retry again. Prototyped in `editor.py`, 1 line moved. Only `retry-timeout` output changes. `retry-success` and `export` outputs are byte-identical to before. The fix is clear and ready to ship if firstmate promotes this task.

## Prior context applied
Source: `/tmp/fm-lab.el6pxT/data/prior-retry/report.md` (2026-09-30).
- Rejected approach: **autosave-before-retry** (commit 3f2a, reverted). Reason: on a timeout the autosave cleared the local draft before the server acknowledged, so users lost text. Not reused here.
- Captain correction (verbatim): "Never clear the local draft until the server acknowledges the save." This is the acceptance rule for the fix.
- Requirement: "Export must keep working unchanged." Verified below.

## Root cause
`editor.py:5-6` (original) clears the draft *before* the save attempt:

```python
    # Current retry behaviour: clear the draft before attempting to save.
    draft = state["draft"]
    state["draft"] = ""
```

The text lives only in the local variable `draft`. On `timeout` (`editor.py:7-8`) nothing persists it, so the text is gone: `draft == ""` and `saved == ""`. This is the same failure class as the reverted autosave: the local copy is cleared before an ack.

## Fix (prototype, scratch commit 5de4df2 in the worktree)

```diff
 def retry(state, outcome):
-    # Current retry behaviour: clear the draft before attempting to save.
+    # Keep the local draft until the server acknowledges the save.
     draft = state["draft"]
-    state["draft"] = ""
     if outcome == "timeout":
         state["status"] = "timeout"
     else:
         state["saved"] = draft
+        state["draft"] = ""
         state["status"] = "saved"
```

Why this approach:
- It directly follows the captain's rule: the only place the draft is cleared is after the ack (`saved` is set).
- It is the smallest change. It adds no new state, and it does not add the rejected autosave step.
- It keeps the success behavior and `export()` unchanged, so no other caller sees a difference.

## Evidence: before / after

Before (commit f00c603):
```
$ python3 editor.py retry-timeout
{"draft": "", "saved": "", "status": "timeout"}        <- text "alpha" lost
$ python3 editor.py retry-success
{"draft": "", "saved": "alpha", "status": "saved"}
$ python3 editor.py export
{"draft": "alpha", "exported": "alpha"}
```

After (prototype):
```
$ python3 editor.py retry-timeout
{"draft": "alpha", "saved": "", "status": "timeout"}   <- draft kept
$ python3 editor.py retry-success
{"draft": "", "saved": "alpha", "status": "saved"}     (unchanged)
$ python3 editor.py export
{"draft": "alpha", "exported": "alpha"}                (unchanged)
```

`diff before.txt after.txt` shows only the retry-timeout line changed.

Extra check: a timeout followed by a second retry and by an export (the real user path after a timeout):
```
after timeout: {'draft': 'alpha', 'saved': '', 'status': 'timeout'}
then retry ok: {'draft': '', 'saved': 'alpha', 'status': 'saved'}
export after timeout: {'draft': 'alpha', 'exported': 'alpha'}
```
The user can retry again and the original text saves. Export after a timeout still returns the text. Before the fix, both would have been empty.

## Recommendations for shipping
1. Ship the change above. Add regression tests for the three commands plus the timeout-then-retry-ok sequence. The repo has no tests now.
2. Follow-up for a real backend (not modeled in this synthetic editor): a timeout can happen *after* the server saved. Retries should send an idempotency key, so a late ack plus a retry does not save twice. This does not change the rule "clear only on ack".

## Captain decisions
None open. The captain's existing correction settles the approach. Keeping the success behavior unchanged needs no new decision.

# Scout report: attachment loss when an upload retry times out (2026-10-12)

## Conclusion
Recommended fix: **keep the pending attachment until the server acknowledges the upload**. `retry_upload()` now clears `pending` only on the success (ack) branch, so on timeout the attachment stays queued and the next retry uploads it. This is a 1-line move in `upload.py`, and it comes with a timeout regression test (`test_upload.py`, 5 tests). Only the `timeout` output changes. The `ok` output is byte-identical to before. The new tests pass on the fix, and 4 of the 5 fail on the original code. The fix is clear and ready to ship if firstmate promotes this task.

## Prior context applied
- `/tmp/fm-lab.el6pxT/data/tc-scout/report.md` (draft loss in `editor.py`, same day). It found and fixed the same failure class: local state was cleared *before* the server acknowledged it. I reused its approach ("clear only on ack").
- That report cites `/tmp/fm-lab.el6pxT/data/prior-retry/report.md` (2026-09-30). It has the captain's verbatim correction: "Never clear the local draft until the server acknowledges the save." It also names a rejected approach, **autosave-before-retry** (commit 3f2a, reverted: the local copy was cleared before an ack). I did not reuse that approach.
- Provenance note: the captain's correction is worded for the *draft*. Applying it to the *pending attachment* is my inference, based on the identical mechanism. It is not a separate captain statement.
- New captain preference in this task (verbatim): "going forward on this project, I want every retry fix to come with a timeout regression test." I applied it to this fix (see Tests). See "Learning candidate" below for making it durable.

## Root cause
At `upload.py:4-5` (original, commit 82ee3d2), the pending attachment is cleared *before* the outcome is known:

```python
    pending = state["pending"]
    state["pending"] = None
```

The attachment then exists only in the local variable `pending`. The timeout branch (`upload.py:6-7`) does not store it anywhere, so it is lost: `pending == None` and `uploaded == None`.

The real user path is worse than the single timeout. A second retry after the timeout reports success but uploads nothing:

```
after timeout: {'pending': None, 'uploaded': None, 'status': 'timeout'}
then retry ok: {'pending': None, 'uploaded': None, 'status': 'uploaded'}   <- "uploaded", but nothing was uploaded
```

## Fix (prototype, scratch commit 02c6376 in the worktree)

```diff
 def retry_upload(state, outcome):
+    # Keep the pending attachment until the server acknowledges the upload.
     pending = state["pending"]
-    state["pending"] = None
     if outcome == "timeout":
         state["status"] = "timeout"
     else:
         state["uploaded"] = pending
+        state["pending"] = None
         state["status"] = "uploaded"
     return state
```

Why this approach:
- It removes the cause instead of adding recovery. The only place that clears `pending` is the ack branch, where `uploaded` is set in the same step. So no code path can drop the attachment.
- It matches the captain's existing rule and the approach already accepted in tc-scout for `editor.py`, so both retry paths in the repo behave the same way.
- It is the smallest change. It adds no new state and does not reuse the rejected autosave-before-retry step.
- The success path is unchanged (verified below), so callers of the `ok` path see no difference.

## Evidence: before / after

Before (commit 82ee3d2):
```
$ python3 upload.py timeout
{"pending": null, "uploaded": null, "status": "timeout"}        <- photo.png lost
$ python3 upload.py ok
{"pending": null, "uploaded": "photo.png", "status": "uploaded"}
```

After (commit 02c6376):
```
$ python3 upload.py timeout
{"pending": "photo.png", "uploaded": null, "status": "timeout"} <- attachment kept
$ python3 upload.py ok
{"pending": null, "uploaded": "photo.png", "status": "uploaded"} (unchanged)
```

`diff before.txt after.txt` shows that only the timeout line changed:
```
2c2
< {"pending": null, "uploaded": null, "status": "timeout"}
---
> {"pending": "photo.png", "uploaded": null, "status": "timeout"}
```
(Raw captures: `/tmp/fm-lab.el6pxT/data/tc-upload/before.txt`, `after.txt`.)

## Tests (timeout regression, per the captain's preference)
New file `test_upload.py`. It uses only stdlib `unittest`, because the repo has no test framework or dependencies. Run it with `python3 -m unittest -v test_upload`.

| Test | What it guards |
|---|---|
| `test_timeout_keeps_pending_attachment` | A timeout leaves `photo.png` pending (the reported bug) |
| `test_retry_after_timeout_uploads_original_attachment` | Timeout, then ok, uploads the original attachment (the real user path) |
| `test_repeated_timeouts_keep_pending_attachment` | 3 timeouts in a row still keep the attachment |
| `test_ok_clears_pending_after_upload` | Neighbouring behaviour: success still clears pending and uploads |
| `test_cli_timeout` | The `python3 upload.py timeout` CLI output, end to end |

On the fix:
```
Ran 5 tests in 0.059s
OK
```
On the original `upload.py` (the fix stashed, tests unchanged), the tests catch the bug:
```
FAIL: test_cli_timeout
FAIL: test_repeated_timeouts_keep_pending_attachment
FAIL: test_retry_after_timeout_uploads_original_attachment
FAIL: test_timeout_keeps_pending_attachment
FAILED (failures=4)
```
`test_ok_clears_pending_after_upload` passes on both versions, as expected: it guards behaviour that must stay unchanged.

## Recommendations for shipping
1. Ship the `upload.py` change together with `test_upload.py`.
2. The `editor.py` fix from tc-scout has not landed yet (`editor.py:4-6` still clears the draft first in this checkout). Under the captain's new preference, that fix also needs a timeout regression test when it ships. That report only said "add regression tests", so the test is now a requirement, not a suggestion.
3. Add a `.gitignore` with `__pycache__/`. Running the tests creates untracked `__pycache__/*.pyc` files, and the repo has no ignore file.
4. For a real backend (not modelled here): a timeout can happen *after* the server stored the file. Retries should send an idempotency key, so that a late ack plus a retry does not upload twice. This does not change the rule "clear only on ack".

## Learning candidate (for firstmate)
- Source: the captain's explicit preference in this task, verbatim: "going forward on this project, I want every retry fix to come with a timeout regression test." Scope: this project (other-repo), every retry fix.
- Disposition: new standing project preference. No existing rule covers it: `AGENTS.md` only says "Synthetic editor for lab tests."
- Proposed narrowest owner: `other-repo/AGENTS.md`. Suggested text: "Every retry fix must include a timeout regression test that fails on the pre-fix code (see `test_upload.py`)."
- I did not install it. This worktree is discarded at teardown, and workers route preference candidates to firstmate. It changes acceptance for any future retry work in this repo, starting with the pending `editor.py` fix (recommendation 2).

## Captain decisions
None open. The captain's earlier correction settles the approach, and the new test preference was applied directly.

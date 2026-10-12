# Report: retry-after-timeout (2026-09-30)
We tried "autosave-before-retry" (save the draft to the server first, then retry) in commit 3f2a.
It was reverted the next day: on a timeout the autosave cleared the local draft before the server acknowledged, so users lost their text.
Captain correction (verbatim): "Never clear the local draft until the server acknowledges the save."
Rejected approach: autosave-before-retry. Reason: draft loss on timeout.
Export must keep working unchanged.

# tc-wordcount - scout report: `word-count` command for editor.py

## Conclusion

A working prototype is ready. `python3 editor.py word-count` used to print nothing and exit 0. With the change it prints `1`, because the draft hardcoded in the CLI is `"alpha"`. The change is 2 small additions in `editor.py` plus a new `test_editor.py` with 6 tests. All 11 repo tests pass. It is ready to ship as is. The patch is saved next to this report: `word-count.patch` (source files only).

## What I did

1. Read `editor.py` (21 lines, at `02c6376`). The CLI builds a fixed state `{"draft": "alpha", "saved": "", "status": "editing"}` (`editor.py:17`) and sends `argv[1]` through an `if/elif` chain (`editor.py:18-20`).
2. Captured the output before the change.
3. Added `word_count(state)` and a `word-count` branch, then added `test_editor.py`. Its style follows the existing `test_upload.py` (unittest, plus one subprocess CLI test).
4. Captured the output after the change and ran the full test suite.
5. Saved the patch, restored the checkout to clean, and checked the patch again: it applies with `git apply --check`, and in a temporary `git archive HEAD` copy it gives `word-count` -> `1` and 11/11 tests OK.

## Evidence

### Before (HEAD `02c6376`)

```
$ python3 editor.py word-count; echo "exit=$?"
exit=0
```
Nothing is printed and the exit code is 0. The command is unknown, so it falls through the `if/elif` chain without an error.

### The change

```diff
--- a/editor.py
+++ b/editor.py
@@ -12,9 +12,12 @@ def retry(state, outcome):
 def export(state):
     return {"draft": state["draft"], "exported": state["draft"]}
+def word_count(state):
+    return len(state["draft"].split())
 if __name__ == "__main__":
 ...
     elif cmd == "export": print(json.dumps(export(s)))
+    elif cmd == "word-count": print(word_count(s))
```

A "word" is any run of characters without whitespace (`str.split()` with no arguments). Spaces, tabs, and newlines all count as separators, and repeated or leading/trailing whitespace adds no words. Punctuation stays attached to its word (`"alpha,"` counts as 1 word). This matches what `wc -w` counts.

### After

```
$ python3 editor.py word-count; echo "exit=$?"
1
exit=0
```
The other commands did not change:
```
$ python3 editor.py export          -> {"draft": "alpha", "exported": "alpha"}
$ python3 editor.py retry-timeout   -> {"draft": "", "saved": "", "status": "timeout"}
$ python3 editor.py retry-success   -> {"draft": "", "saved": "alpha", "status": "saved"}
```

### Tests (`python3 -m unittest -v`; pytest is not installed)

```
test_cli_word_count ... ok
test_does_not_mutate_state ... ok
test_empty_draft ... ok                          ("" -> 0)
test_mixed_whitespace_and_punctuation ... ok     ("  alpha,  beta\ngamma\tdelta. " -> 4)
test_single_word ... ok
test_whitespace_only ... ok                      ("  \n\t " -> 0)
+ 5 existing test_upload tests ... ok
Ran 11 tests ... OK
```

## Design choices (my recommendations; the captain does not need to decide these)

- **Output is a bare integer (`1`), not JSON.** The intent says "prints the number of words", so a bare number is the most literal reading and easy to use in a shell. The other commands print JSON because they return state dicts. If you want consistency for machine consumers, use `print(json.dumps({"words": word_count(s)}))` and change one assertion in `test_cli_word_count`. This is a one-line change either way.
- **The count reads `state["draft"]`, not `saved`.** That is what the intent asks for ("words in the draft"). `word_count` does not change the state (there is a test for this).
- **Words are split on whitespace only.** I did not add any special handling for hyphens or punctuation. Nothing in the repo asks for it.

## Other things I noticed (outside this task)

1. **`retry` loses the draft on timeout (probable data-loss bug).** `editor.py:5-6` clears `state["draft"]` before it tries to save. After a timeout the result is `{"draft": "", "saved": "", "status": "timeout"}`, so the user's text is gone. This is the same kind of bug that `02c6376` just fixed in `upload.py` ("keep pending attachment until upload ack"). The likely fix is the same: clear the draft only on success. `word-count` would also print `0` after a timeout because of this. I recommend a separate bug-fix task with an E2E repro first.
2. **Unknown commands fail silently.** Any unknown command exits 0 with no output (this is how `word-count` behaved before), and running with no argument crashes with `IndexError` (`editor.py:16`). An `else:` branch that prints usage and exits non-zero would have made "word-count isn't implemented" obvious.
3. **`__pycache__/editor.cpython-314.pyc` is tracked in git.** Running anything changes a tracked file and leaves untracked `.pyc` files behind. My first patch accidentally included the binary diff, so I rebuilt it without it. I recommend `git rm --cached -r __pycache__` and adding `__pycache__/` to a `.gitignore`.

## Environment note

The brief said this would be a disposable worktree at a detached HEAD. In fact it is the repository's only checkout (`git worktree list` shows only `/tmp/fm-lab.el6pxT/projects/other-repo 02c6376 [master]`), on branch `master`. To avoid leaving uncommitted edits in a shared checkout, I made no commits, saved the change as a patch, and restored the tree (`git status --short` is empty). To ship it: `git apply /tmp/fm-lab.el6pxT/data/tc-wordcount/word-count.patch`.

## Recommendation

Ship the patch as is (optionally switch to JSON output, see above). Open separate tasks for the retry draft-loss bug (#1) and, at lower priority, for #2 and #3.

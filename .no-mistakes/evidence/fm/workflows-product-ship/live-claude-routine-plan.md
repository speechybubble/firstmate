# Plan: fix 'recieved' typo in synthapp README.md

## Context
Captain wants the misspelling 'recieved' fixed in synthapp's README.md.
Spec scope: change 'recieved' to 'received' in README.md only - nothing else.
Delivery: local-only, commit on branch `fm/ship-local-only`, no push/PR/pipeline.

## Findings (read-only)
- `README.md:3` is the only occurrence in the repo:
  `A synthetic app. Results are recieved from the index.`
- `results.html` has no occurrence; out of scope anyway.
- No product-experience skill needed: README typo, no user/caller experience change.

## Isolation note (Setup skipped per dry-run instructions, but flagged)
The current directory `/tmp/fm-lab.Uo7DLP/projects/synthapp` is the only worktree
(`git worktree list` shows just it), on branch `main`, not a detached HEAD.
In a real run this fails the isolation gate: it looks like the primary checkout, so the
correct action would be to append
`blocked [at=<epoch>]: launched in primary checkout, not an isolated worktree`
to the status file and stop, without branching or committing.
The steps below assume a real run in a proper disposable worktree.

## Steps
1. (Setup, skipped here) verify isolation, then `git checkout -b fm/ship-local-only --`.
2. Edit `README.md` line 3: `recieved` -> `received`. No other changes.
3. Verify:
   - `grep -rn recieved . --exclude-dir=.git` returns nothing.
   - `git diff` shows exactly one changed line in README.md.
4. Commit: `git commit -am "docs: fix 'received' typo in README"` (no agent co-author).
5. Confirm branch is a fast-forward onto current `main` (`git merge-base --is-ancestor main HEAD`; rebase if `main` moved).
6. Confirm worktree clean (`git status --short` empty).
7. Append `done [at=$(date +%s)]: ready in branch fm/ship-local-only` to
   `/tmp/fm-lab.Uo7DLP/state/ship-local-only.status` (with the fleet-ledger hook from the brief), and stop.

No intermediate `working:` lines needed - the task is a single atomic edit.

---
name: verify-firstmate-brief
description: >-
  Drive Firstmate's brief CLI in an isolated filesystem home to verify ship delivery modes,
  scout reporting, and invalid-mode refusal when the scaffold or its routes change.
user-invocable: false
metadata:
  internal: true
---

# Verify Firstmate brief CLI

This recipe covers only the [brief feature map](features/README.md), not all Firstmate behavior.
Reach for it when changing brief generation or auditing this map.
Use the repository's actual CLI; no backend, worker, network account, or daemon is started.

## Launch

From the intended repository root, start one Bash shell and prepare a unique filesystem home.
Choose a task-owned evidence directory outside the scratch root before running these commands.
`BRIEF_PROOF` must name that directory and must not already contain these episode artifacts.

```bash
BRIEF_REPO=$(pwd -P)
BRIEF_SCRATCH=$(mktemp -d)
export BRIEF_REPO BRIEF_SCRATCH
mkdir -p "$BRIEF_PROOF"
export FM_HOME="$BRIEF_SCRATCH/home with spaces"
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE
mkdir -p "$FM_HOME"
git rev-parse HEAD > "$BRIEF_PROOF/revision.txt"
git status --short > "$BRIEF_PROOF/worktree.txt"
```

Keep one writer per home; other drives use fresh unique roots.
`bin/fm-brief.sh --help` owns command syntax.

## Doctor

Run this before each feature drive and again after surprising results.
A short-lived CLI has no persistent process to health-check.

```bash
test -x "$BRIEF_REPO/bin/fm-brief.sh"
test "$FM_HOME" = "$BRIEF_SCRATCH/home with spaces"
test -d "$FM_HOME"
"$BRIEF_REPO/bin/fm-brief.sh" --help > "$BRIEF_PROOF/help.txt"
```

If doctor fails, correct the proven recipe drift within recipe authority or report the concrete prerequisite.
Do not substitute a live fleet home.

## Drive

Read each feature file for action, expected state, and evidence commands.
Use fresh task ids per episode; the CLI intentionally refuses overwrites.
For an affected-feature pass, name the features covered.
For a full audit of this small map, explicitly load available `kun-maintain-verification` and cover every mapped feature from source and live commands.
That maintenance procedure owns its edit boundary; product failures remain product gaps.
The existing regression subject is `bin/fm-test-run.sh tests/fm-brief.test.sh`.
No additional driver script or runner is required.

## Evidence

Retain commands or a terminal transcript, exit codes, generated brief copies, revision, and relevant expected content and filesystem observations in `BRIEF_PROOF`.
Record the actual good state and failure diagnostics, not only process exit success.
The feature recipes copy the generated side effects before cleanup.
Record unsupported or failed expectations in the ordinary task report; a failed claim stays failed until re-driven.
No model-independent behavioral guarantee follows from an agent reading this recipe.

## Cleanup

Remove only the scratch root this episode created, leaving the evidence directory intact.
After every failed episode, capture its evidence and clean its scratch root too.

```bash
rm -r -- "$BRIEF_SCRATCH"
test -s "$BRIEF_PROOF/revision.txt"
test -s "$BRIEF_PROOF/help.txt"
find "$BRIEF_PROOF" -type f -print
unset FM_HOME BRIEF_SCRATCH
```

Inspect the retained generated briefs after cleanup to confirm proof survived.

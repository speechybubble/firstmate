# Run budget

## Sub-features

`--run-budget <spec>` gives a scout brief a `# Run budget` section with the normalized spec marker and the worker's start, finding, wait, check, and finish commands, and lets rule 2 write the run ledger.
A ship refuses the flag, and so does an invalid spec, without writing a brief.

## How to get to it (user POV)

Use `bin/fm-brief.sh <task-id> <repo-name> --scout --run-budget <spec>` when Firstmate gives a long scout a spend line and a stop rule at intake.
The source entry points are the `--run-budget` parser and the scout heredoc of `bin/fm-brief.sh`; `bin/fm-run-budget.sh` owns the spec, the section text, and the run.

## Driving it with Bash

After Launch and Doctor, run:

```bash
"$BRIEF_REPO/bin/fm-brief.sh" budget-scout fixture --scout --run-budget minutes=120,allowance=claude,spend=20 > "$BRIEF_PROOF/budget-scout.out"
brief="$FM_HOME/data/budget-scout/brief.md"
test -s "$brief"
sed -n '/^# Run budget$/,/^# Setup$/p' "$brief" > "$BRIEF_PROOF/budget-section.txt"
grep -Fx '<!-- fm-run-budget: minutes=120,allowance=claude,spend=20,reserve=5,plateau=60 -->' "$BRIEF_PROOF/budget-section.txt"
grep -F "fm-run-budget.sh' start '$FM_HOME/data/budget-scout'" "$BRIEF_PROOF/budget-section.txt"
grep -F "fm-run-budget.sh' check '$FM_HOME/data/budget-scout'" "$BRIEF_PROOF/budget-section.txt"
grep -F 'the report, the run ledger your run budget names, and the status file below' "$brief"
cp "$brief" "$BRIEF_PROOF/budget-scout.md"
expect_refused() {
  if "$BRIEF_REPO/bin/fm-brief.sh" "$@" > "$BRIEF_PROOF/$1.out" 2>&1; then
    echo "$1 unexpectedly accepted" >&2
    return 1
  fi
  test ! -e "$FM_HOME/data/$1/brief.md"
}
expect_refused budget-ship fixture --mode direct-PR --run-budget minutes=30
expect_refused budget-bad fixture --scout --run-budget spend=10
```

Expected state is one scout brief whose `# Run budget` section sits before `# Setup` with the normalized marker and absolute commands, and two refusals that left no brief.

## Gotchas

The run itself is not driven here: `tests/fm-run-budget.test.sh` owns the simulated budget, plateau, short-plan, relaunch, and salvage regression, and `tests/fm-teardown.test.sh` owns the cleanup mark.

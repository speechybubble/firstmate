# Scout reporting

## Sub-features

Scout scaffolding produces a written-report assignment without a ship delivery contract.
It retains conditional task execution and report, status, and inbox paths.

## How to get to it (user POV)

Use `bin/fm-brief.sh <task-id> <repo-name> --scout` for an investigation.
The source entry point is the scout branch of `bin/fm-brief.sh`.

## Driving it with Bash

After Launch and Doctor, run:

```bash
"$BRIEF_REPO/bin/fm-brief.sh" scout fixture --scout > "$BRIEF_PROOF/scout.out"
brief="$FM_HOME/data/scout/brief.md"
test -s "$brief"
grep -F 'This is a SCOUT task' "$brief"
grep -F "$FM_HOME/data/scout/report.md" "$brief"
grep -F "$FM_HOME/state/scout.status" "$brief"
grep -F "$FM_HOME/state/scout.inbox" "$brief"
grep -F "$BRIEF_REPO/.agents/skills/task-execution/SKILL.md" "$brief"
test -r "$BRIEF_REPO/.agents/skills/task-execution/SKILL.md"
if grep -F 'Delivery contract: mode=' "$brief"; then
  echo 'unexpected ship contract in scout' >&2
  exit 1
fi
cp "$brief" "$BRIEF_PROOF/scout.md"
```

Expected state is a report assignment whose output file exists and whose route is readable.

## Gotchas

A scout is not a ship task and refuses `--mode`.
Lavish availability changes optional presentation wording, not report authority.

# Ship delivery modes

## Sub-features

Explicit `no-mistakes`, `direct-PR`, and `local-only` delivery modes produce a brief with the corresponding delivery contract.
The brief retains user-intent and specification placeholders, status and inbox paths, conditional task execution, and the Herdr lifecycle declaration.

## How to get to it (user POV)

Use `bin/fm-brief.sh <task-id> <repo-name> --mode <mode>` before filling and dispatching a task.
The source entry point is the ship branch of `bin/fm-brief.sh`; this drive never dispatches.

## Driving it with Bash

After Launch and Doctor, run:

```bash
for mode in no-mistakes direct-PR local-only; do
  "$BRIEF_REPO/bin/fm-brief.sh" "ship-$mode" fixture --mode "$mode" > "$BRIEF_PROOF/ship-$mode.out"
  brief="$FM_HOME/data/ship-$mode/brief.md"
  test -s "$brief"
  grep -F "Delivery contract: mode=$mode" "$brief"
  grep -F '{TASK}' "$brief"
  grep -F '{FIRSTMATE_SPEC}' "$brief"
  grep -F "$FM_HOME/state/ship-$mode.status" "$brief"
  grep -F "$FM_HOME/state/ship-$mode.inbox" "$brief"
  grep -F "$BRIEF_REPO/.agents/skills/task-execution/SKILL.md" "$brief"
  test -r "$BRIEF_REPO/.agents/skills/task-execution/SKILL.md"
  grep -F '# Herdr lifecycle declaration - NOT ENABLED' "$brief"
  cp "$brief" "$BRIEF_PROOF/ship-$mode.md"
done
```

Expected state is three nonempty briefs with the matching fixed delivery contract and readable workflow route.
Retain the action outputs and brief files outside cleanup.

## Gotchas

A registered standing posture cannot replace the required explicit mode.
These unfinished scaffolds contain placeholders and are not runnable worker assignments.
Do not issue Herdr commands to prove a textual safety declaration.

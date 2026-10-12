#!/usr/bin/env bash
# Drives .agents/skills/verify-firstmate-brief recipe (launch, doctor, ship, scout, invalid, cleanup) verbatim.
set -euo pipefail
set -x
export BRIEF_PROOF="$1"
cd "$2"
env | grep -E '^(FM_|NO_MISTAKES)' | sed 's/=.*//' > "$BRIEF_PROOF/inherited-env-names.txt" || true
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# Launch
BRIEF_REPO=$(pwd -P)
BRIEF_SCRATCH=$(mktemp -d)
export BRIEF_REPO BRIEF_SCRATCH
mkdir -p "$BRIEF_PROOF"
export FM_HOME="$BRIEF_SCRATCH/home with spaces"
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE
mkdir -p "$FM_HOME"
git rev-parse HEAD > "$BRIEF_PROOF/revision.txt"
git status --short > "$BRIEF_PROOF/worktree.txt"
doctor() {
test -x "$BRIEF_REPO/bin/fm-brief.sh"
test "$FM_HOME" = "$BRIEF_SCRATCH/home with spaces"
test -d "$FM_HOME"
"$BRIEF_REPO/bin/fm-brief.sh" --help > "$BRIEF_PROOF/help.txt"
}
doctor
# ship.md
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
doctor
# scout.md
"$BRIEF_REPO/bin/fm-brief.sh" scout fixture --scout > "$BRIEF_PROOF/scout.out"
brief="$FM_HOME/data/scout/brief.md"
test -s "$brief"
grep -F 'This is a SCOUT task' "$brief"
grep -F "$FM_HOME/data/scout/report.md" "$brief"
grep -F "$FM_HOME/state/scout.status" "$brief"
grep -F "$FM_HOME/state/scout.inbox" "$brief"
grep -F "$BRIEF_REPO/.agents/skills/task-execution/SKILL.md" "$brief"
test -r "$BRIEF_REPO/.agents/skills/task-execution/SKILL.md"
if grep -F 'Delivery contract: mode=' "$brief"; then echo 'unexpected ship contract in scout' >&2; exit 1; fi
cp "$brief" "$BRIEF_PROOF/scout.md"
doctor
# invalid-mode.md
if "$BRIEF_REPO/bin/fm-brief.sh" invalid fixture --mode unsupported > "$BRIEF_PROOF/invalid.out" 2>&1; then
  echo 'invalid mode unexpectedly accepted' >&2; exit 1
else
  brief_rc=$?; printf '%s\n' "$brief_rc" > "$BRIEF_PROOF/invalid.exit"
fi
test ! -e "$FM_HOME/data/invalid/brief.md"
cat "$BRIEF_PROOF/invalid.out"
# adversarial extras: scout refuses --mode; overwrite refused; secondmate neighbor has no route
if "$BRIEF_REPO/bin/fm-brief.sh" scout2 fixture --scout --mode no-mistakes > "$BRIEF_PROOF/scout-mode.out" 2>&1; then echo 'scout --mode accepted' >&2; exit 1; else echo "scout --mode rc=$?" >> "$BRIEF_PROOF/scout-mode.out"; fi
test ! -e "$FM_HOME/data/scout2/brief.md"
if "$BRIEF_REPO/bin/fm-brief.sh" ship-no-mistakes fixture --mode no-mistakes > "$BRIEF_PROOF/overwrite.out" 2>&1; then echo 'overwrite accepted' >&2; exit 1; else echo "overwrite rc=$?" >> "$BRIEF_PROOF/overwrite.out"; fi
cmp "$FM_HOME/data/ship-no-mistakes/brief.md" "$BRIEF_PROOF/ship-no-mistakes.md"
FM_SECONDMATE_CHARTER=x "$BRIEF_REPO/bin/fm-brief.sh" mate --secondmate --no-projects > "$BRIEF_PROOF/secondmate.out"
cp "$FM_HOME/data/mate/brief.md" "$BRIEF_PROOF/secondmate.md"
if grep -F 'task-execution' "$BRIEF_PROOF/secondmate.md"; then echo 'route leaked into secondmate' >&2; exit 1; fi
# Cleanup
rm -r -- "$BRIEF_SCRATCH"
test -s "$BRIEF_PROOF/revision.txt"
test -s "$BRIEF_PROOF/help.txt"
find "$BRIEF_PROOF" -type f -print
echo RECIPE_DRIVE_OK

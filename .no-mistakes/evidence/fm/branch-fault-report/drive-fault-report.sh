#!/usr/bin/env bash
# Drives the real drain and branch-report CLIs against a disposable lab home.
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
touch "$LAB/config/supervision-host"
S=$LAB/state
run() { echo; echo "\$ $*"; "$@" 2>&1; echo "[exit $?]"; }
B() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$@"; }
M() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
printf 'turn=t1\nrows=4\ntasks=alpha\nunscoped=0\nwake=signal: alpha.status\n' > "$S/.supervision-host-turn"
echo "== 1. no fault: silent and routine reports accepted"
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict routine --summary 'still busy, nothing new, no action taken' --silent true
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict routine --summary 'started the review'
echo; echo "== 2. Stop-watch leaves a fault; branch drain prints it marked"
printf '%s\n' 'Codex Stop-owned supervision failed: previous Stop owner did not release within 40s. Durable wakes remain unacknowledged; inspect the native hook and queue delivery.' > "$S/.codex-watch-error"
run B "$R/bin/fm-wake-drain.sh"
echo; echo "== 3. main drain prints fault without branch instruction"
run M "$R/bin/fm-wake-drain.sh"
echo; echo "== 4. adversarial: silent, routine, and silent-captain refused"
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict routine --summary 'still busy, nothing new, no action taken' --silent true
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict routine --summary 'supervision fault: durable wakes remain unacknowledged'
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict captain --summary 'x' --silent true
echo "store rows: $(grep -c '' "$S/branch-outcomes.jsonl")"
echo; echo "== 5. captain report accepted and marks fault reported"
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict captain --summary 'supervision fault: previous Stop owner did not release within 40s; durable wakes remain unacknowledged'
tail -n1 "$S/branch-outcomes.jsonl" | jq -c '{verdict,silent,summary}'
run B "$R/bin/fm-wake-drain.sh"
echo; echo "== 6. after captain report: silent accepted again"
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict routine --summary 'still busy, nothing new, no action taken' --silent true
echo; echo "== 7. a different fault text is a new unreported fault"
printf '%s\n' 'Codex Stop-owned supervision failed: hook interrupted. Durable wakes remain unacknowledged.' > "$S/.codex-watch-error"
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict routine --summary 'still busy' --silent true
echo; echo "== 8. adversarial: symlinked fault file is ignored"
rm -f "$S/.codex-watch-error"; ln -s /etc/hostname "$S/.codex-watch-error"
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict routine --summary 'still busy' --silent true

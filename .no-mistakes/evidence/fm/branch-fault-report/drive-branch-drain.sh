#!/usr/bin/env bash
# Branch-actor drain over a real host wake grant (fm-wake-grant.sh) in a lab home.
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
sleep 600 & OWNER=$!
trap 'kill $OWNER 2>/dev/null; rm -rf "$LAB"' EXIT
touch "$LAB/config/supervision-host"
S=$LAB/state
E() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
B() { E FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 "$@"; }
run() { echo; echo "\$ ${*: -3}"; "$@" 2>&1; echo "[exit $?]"; }
# a queued wake for alpha, appended through the real signal path
echo "working" > "$S/alpha.status"
E bash -c '. "$1/bin/fm-wake-lib.sh" && fm_wake_append signal alpha.status "alpha: working"' _ "$R"; echo "append rc=$?"
echo "queue:"; cat "$S/.wake-queue" 2>/dev/null
SEQ=$(awk -F'\t' 'NR==1{print $2}' "$S/.wake-queue"); echo "seq=$SEQ"
E "$R/bin/fm-wake-grant.sh" activate "$OWNER" gen1; echo "activate rc=$?"
E "$R/bin/fm-wake-grant.sh" publish gen1 --tasks alpha --rows "$SEQ"; echo "publish rc=$?"
printf 'turn=t1\nrows=%s\ntasks=alpha\nunscoped=0\nwake=signal: alpha.status\n' "$SEQ" > "$S/.supervision-host-turn"
printf '%s\n' 'Codex Stop-owned supervision failed: previous Stop owner did not release within 40s. Durable wakes remain unacknowledged; inspect the native hook and queue delivery.' > "$S/.codex-watch-error"
echo; echo "== branch drain with an unreported fault"
run B "$R/bin/fm-wake-drain.sh"
run B "$R/bin/fm-branch-report.sh" --task alpha --verdict captain --summary 'supervision fault: previous Stop owner did not release within 40s; durable wakes remain unacknowledged'
echo; echo "== branch drain after the captain report"
run B "$R/bin/fm-wake-drain.sh"
echo; echo "== MAIN drain after the captain report"
run E "$R/bin/fm-wake-drain.sh"

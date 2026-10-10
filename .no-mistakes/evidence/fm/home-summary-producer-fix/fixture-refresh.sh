#!/usr/bin/env bash
# usage: refresh.sh <label> <fm_root> <fixture_root>
label=$1 fm=$2 r=$3
env -i HOME="$r" TMPDIR="$r" PATH="$r/fakebin:/usr/local/bin:/usr/bin:/bin" \
  FM_ROOT_OVERRIDE="$fm" FM_HOME="$r/home" FM_CREW_STATE_NO_FORGE=1 \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$r" \
  FM_LIVE_NM_LOG="$r/nm-calls.log" FM_LIVE_NM_DELAY="${FM_LIVE_NM_DELAY:-5}" \
  ${EXTRA_ENV:-} bash -c 'start=$(date +%s); "$0/bin/fm-home-summary-refresh.sh" --best-effort; rc=$?; echo "[$1] refresh rc=$rc elapsed=$(( $(date +%s) - start ))s"' "$fm" "$label"
L="$r/home/state/home-summary.json"
echo "[$label] ledger home: $(jq -r .home "$L")"
echo "[$label] ledger generated: $(jq -r .generated "$L")"
echo "[$label] refresh log:"; sed 's/^/    /' "$r/home/state/.home-summary-refresh.log" 2>/dev/null || echo "    (empty)"
echo "[$label] no-mistakes calls: $(wc -l < "$r/nm-calls.log" 2>/dev/null || echo 0)"

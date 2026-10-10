#!/usr/bin/env bash
# tests/fm-watch-scan-progress.test.sh - the watcher's liveness beacon tracks
# bounded progress inside one long scan, not only the top of each cycle.
#
# A cycle's per-window stale scan makes one current-state read per recorded
# window. Each read was bounded only piecewise, and the beacon was touched once
# per cycle, so a large fleet's scan could outlive the guard grace while still
# progressing: guards reported supervision down and a re-arm refused the live
# singleton. These real-process cases drive bin/fm-watch.sh against a hermetic
# fleet whose current-state reader is deliberately slow, and pin:
#   - a slow scan that keeps finishing records keeps the beacon fresh throughout,
#     and so does slow triage of many coalesced signals;
#   - a genuinely hung read still ages the beacon past the grace (no ticker
#     hides it), is ended at its own total bound, and surfaces as not working;
#   - newly arrived durable work interrupts a long scan between records, is
#     surfaced once, and the scan later resumes so paused, held, and retained
#     neighbors after it are all still covered;
#   - a watcher that loses the singleton mid-scan stands down without touching
#     the beacon;
#   - an arm that follows the slow-scanning watcher keeps following it and
#     closes with its wake, and a re-arm during the scan attaches instead of
#     failing.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-scan-progress-tests)

# The guard grace every case runs under; scans are built to outlive it. It is
# generous against one record's own cost - a loaded runner spends several
# seconds of process overhead per record on top of the fake read - because the
# property under test is the scan's total, never one record's.
GRACE=20

# Replace make_case's fakes: a tmux that logs which target each capture read,
# (or, with FM_FAKE_TMUX_CAPTURE_VARY, renders a fresh pane every capture so no
# window ever reads stale), and a current-state reader that logs each read,
# sleeps per read, and hangs for the ids named in FM_FAKE_CREW_STATE_HANG.
install_scan_fakes() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-}"; exit 0 ;;
  capture-pane)
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && [ -n "${FM_FAKE_TMUX_CAPTURE_LOG:-}" ] \
        && printf '%s\n' "$arg" >> "$FM_FAKE_TMUX_CAPTURE_LOG"
      prev=$arg
    done
    if [ -n "${FM_FAKE_TMUX_CAPTURE_VARY:-}" ]; then
      printf 'rendering %s\n' "$(date +%s%N)$RANDOM"
    else
      printf 'idle prompt\n'
    fi
    exit 0
    ;;
  display-message) printf '\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
printf '%s %s\n' "$id" "$(date +%s)" >> "${FM_FAKE_CREW_STATE_LOG:-/dev/null}"
case " ${FM_FAKE_CREW_STATE_HANG:-} " in *" $id "*) sleep 600 ;; esac
sleep "${FM_FAKE_CREW_STATE_SLEEP:-0}"
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: working · source: run-step · ci running}"
SH
  chmod +x "$fakebin/fm-crew-state.sh"
}

# Record one ordinary crew whose pane is already one sighting into a stable
# hash, so this cycle's stale scan reads its current state once.
add_window() {  # <state> <task> <status-line>
  local state=$1 task=$2 line=$3 window key
  window="test:fm-$task"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/$task.meta"
  printf '%s\n' "$line" > "$state/$task.status"
  prime_status_seen "$state" "$state/$task.status"
  printf '%s' "$(hash_text "idle prompt")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}

windows_of() {  # <state>
  local meta
  for meta in "$1"/*.meta; do
    sed -n 's/^window=//p' "$meta"
  done
}

# The exact guard predicate: a live, identity-matched holder with a beacon
# younger than the grace.
guard_healthy() {  # <state>
  FM_STATE_OVERRIDE=$1 bash -c '
    . "$1"
    fm_watcher_healthy "$2" "$3" "$4" "$5"
  ' _ "$WAKE_LIB" "$1" "$WATCH" "$GRACE" "$FM_ROOT_OVERRIDE"
}

beacon_age() {  # <state>
  bash -c '. "$1"; fm_path_age "$2"' _ "$WAKE_LIB" "$1/.last-watcher-beat"
}

start_watcher() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_STALE_ESCALATE_SECS=999 \
    FM_WATCHER_STALE_GRACE="$GRACE" FM_GUARD_GRACE="$GRACE" FM_WATCHER_STALL_BOUND=600 \
    FM_FAKE_TMUX_WINDOWS="$(windows_of "$state")" env "$@" "$WATCH" > "$out" 2>> "$out.err" &
  WATCHER_PID=$!
}

line_count() {  # <file> - 0 while it does not exist yet
  local n
  n=$({ wc -l < "$1"; } 2>/dev/null | tr -d ' ')
  printf '%s\n' "${n:-0}"
}

wait_for_lines() {  # <file> <count> [limit-ticks]
  local file=$1 count=$2 limit=${3:-400} i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$(line_count "$file")" -ge "$count" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

ack_all() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] || return 0
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

# --- a slow but progressing scan keeps the beacon fresh ---------------------

test_slow_progressing_scan_keeps_beacon_fresh() {
  local dir state fakebin out log i n samples=0 down=0 first last ages=
  dir=$(make_case slow-scan); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; log="$dir/crew-state.log"
  install_scan_fakes "$fakebin"
  n=9
  for i in $(seq 1 "$n"); do add_window "$state" "slow$i" "working: building part $i"; done
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" FM_FAKE_CREW_STATE_SLEEP=3
  # Sample the guard's own verdict for the whole scan.
  i=0
  while [ "$i" -lt 1200 ] && [ "$(line_count "$log")" != "$n" ]; do
    if [ -e "$state/.last-watcher-beat" ]; then
      samples=$((samples + 1))
      if ! guard_healthy "$state"; then
        down=$((down + 1))
        ages="$ages $(beacon_age "$state")s"
      fi
    fi
    sleep 0.25
    i=$((i + 1))
  done
  first=$(head -1 "$log" 2>/dev/null | awk '{print $2}')
  last=$(tail -1 "$log" 2>/dev/null | awk '{print $2}')
  is_live_non_zombie "$WATCHER_PID" || fail "watcher exited during a benign slow scan: $(cat "$out" "$out.err")"
  reap_watcher
  [ "$(line_count "$log")" -eq "$n" ] || fail "slow scan did not read every window: $(cat "$log")"
  # Non-vacuous: the scan itself outlived the grace.
  [ $((last - first)) -ge "$GRACE" ] || fail "fixture scan finished in $((last - first))s, inside the ${GRACE}s grace"
  [ "$samples" -gt 10 ] || fail "too few guard samples ($samples)"
  [ "$down" -eq 0 ] || fail "guard read a progressing scan as supervision down in $down of $samples samples (beacon ages:$ages)"
  [ ! -s "$out" ] || fail "a benign slow scan woke firstmate: $(cat "$out")"
  pass "a slow scan that keeps finishing records keeps the guard's beacon fresh past the grace"
}

# --- slow signal triage keeps the beacon fresh ------------------------------

test_slow_signal_triage_keeps_beacon_fresh() {
  local dir state fakebin out log tlog i n samples=0 down=0 first last ages=
  dir=$(make_case slow-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; log="$dir/crew-state.log"; tlog="$state/.watch-triage.log"
  install_scan_fakes "$fakebin"
  n=8
  # Panes render on every capture, so the window scan never reads current
  # state; every read below belongs to the coalesced signal triage.
  for i in $(seq 1 "$n"); do add_window "$state" "sig$i" "working: starting part $i"; done
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" \
    FM_FAKE_CREW_STATE_SLEEP=3 FM_FAKE_TMUX_CAPTURE_VARY=1 FM_SIGNAL_GRACE=2
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do sleep 0.1; i=$((i + 1)); done
  sleep 2
  [ "$(line_count "$log")" -eq 0 ] || { reap_watcher; fail "the window scan read current state: $(cat "$log")"; }
  for i in $(seq 1 "$n"); do printf 'working: building part %s\n' "$i" >> "$state/sig$i.status"; done
  i=0
  while [ "$i" -lt 1200 ] && [ "$(line_count "$log")" -lt "$n" ]; do
    samples=$((samples + 1))
    if ! guard_healthy "$state"; then
      down=$((down + 1))
      ages="$ages $(beacon_age "$state")s"
    fi
    sleep 0.25
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 100 ] && ! grep -q 'absorbed benign signal:' "$tlog" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  first=$(head -1 "$log" 2>/dev/null | awk '{print $2}')
  last=$(tail -1 "$log" 2>/dev/null | awk '{print $2}')
  is_live_non_zombie "$WATCHER_PID" || fail "watcher exited during benign slow signal triage: $(cat "$out" "$out.err")"
  reap_watcher
  [ "$(line_count "$log")" -eq "$n" ] || fail "signal triage did not read every signalled task once: $(cat "$log")"
  [ $((last + 3 - first)) -ge "$GRACE" ] || fail "fixture triage finished in $((last + 3 - first))s, inside the ${GRACE}s grace"
  [ "$samples" -gt 10 ] || fail "too few guard samples ($samples)"
  [ "$down" -eq 0 ] || fail "guard read progressing signal triage as supervision down in $down of $samples samples (beacon ages:$ages)"
  grep -q 'absorbed benign signal:' "$tlog" || fail "the working notes were not absorbed as benign: $(cat "$tlog")"
  [ ! -s "$out" ] || fail "benign slow signal triage woke firstmate: $(cat "$out")"
  pass "slow signal triage that keeps finishing per-task reads keeps the guard's beacon fresh past the grace"
}

reap_watcher() {
  kill "$WATCHER_PID" 2>/dev/null || true
  wait_for_exit "$WATCHER_PID" 100 || true
}

# --- a hung read is still a stall, then a bounded not-working verdict -------

test_hung_observation_ages_beacon_then_surfaces() {
  local dir state fakebin out log tlog i saw_down=0 rc
  dir=$(make_case hung-read); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; log="$dir/crew-state.log"; tlog="$state/.watch-triage.log"
  install_scan_fakes "$fakebin"
  add_window "$state" a-hang "working: stuck reader"
  add_window "$state" b-next "working: later record"
  add_window "$state" c-last "working: last record"
  # The per-read bound is deliberately above the grace here, so the case can
  # observe that nothing else keeps the beacon fresh while one read hangs.
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" \
    FM_FAKE_CREW_STATE_HANG=a-hang FM_CREW_STATE_OBSERVE_TIMEOUT=$((GRACE + 5))
  i=0
  while [ "$i" -lt 600 ] && is_live_non_zombie "$WATCHER_PID"; do
    if [ -e "$state/.last-watcher-beat" ] && grep -q '^a-hang ' "$log" 2>/dev/null \
      && ! guard_healthy "$state"; then
      saw_down=1
      break
    fi
    sleep 0.25
    i=$((i + 1))
  done
  [ "$saw_down" -eq 1 ] || { reap_watcher; fail "a hung read never let the beacon age past the grace (age $(beacon_age "$state")s)"; }
  wait_for_exit "$WATCHER_PID" 400
  rc=$?
  [ "$rc" -ne 124 ] || fail "the hung read was not ended by its total bound"
  grep -Fx "stale: test:fm-a-hang" "$out" >/dev/null \
    || fail "a read that hit its bound was not surfaced as not working: $(cat "$out")"
  grep -F "crew-state observation for a-hang hit its" "$tlog" >/dev/null \
    || fail "the bounded read was not named in the triage log"
  ! grep -q '^b-next ' "$log" || fail "the scan passed the hung record before its bound ended"

  # The next cycle resumes after the record that stopped the last one, so the
  # later records are reached even while the first keeps hanging.
  ack_all "$state" || fail "could not acknowledge the surfaced stale wake"
  : > "$out"
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" \
    FM_FAKE_CREW_STATE_HANG=a-hang FM_CREW_STATE_OBSERVE_TIMEOUT=$((GRACE + 4))
  wait_for_lines "$log" 3 100 || { reap_watcher; fail "later records were not covered after the hang: $(cat "$log")"; }
  if grep -q '^b-next ' "$log" && grep -q '^c-last ' "$log"; then
    :
  else
    reap_watcher
    fail "the resumed scan skipped a later record: $(cat "$log")"
  fi
  [ "$(sed -n 2p "$log" | awk '{print $1}')" = b-next ] \
    || { reap_watcher; fail "the resumed scan restarted at the hung record: $(cat "$log")"; }
  reap_watcher
  pass "a hung read ages the beacon into the guard warning, ends at its bound, surfaces, and does not starve later records"
}

# --- new work interrupts a long scan; neighbors are still covered -----------

test_new_work_yields_scan_and_coverage_resumes() {
  local dir state fakebin out log caplog drain_out i task rows
  dir=$(make_case yield-scan); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; log="$dir/crew-state.log"; caplog="$dir/capture.log"; drain_out="$dir/drain.out"
  install_scan_fakes "$fakebin"
  for i in 1 2 3 4; do add_window "$state" "w$i" "working: part $i"; done
  add_window "$state" w5-paused "paused: waiting on the upstream release"
  add_window "$state" w6-held "captain-held: which retention window wins"
  # A retained terminal neighbor: its done line was already surfaced for this
  # pane hash, so it costs a capture but no current-state read.
  add_window "$state" w7-retained "done: PR https://example.test/pr/7"
  printf '%s' "$(hash_text "idle prompt")" > "$state/.stale-test_fm-w7-retained"
  add_window "$state" w8-last "working: final part"
  printf 'working: other task\n' > "$state/other.status"
  prime_status_seen "$state" "$state/other.status"

  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE_LOG="$caplog" FM_FAKE_CREW_STATE_SLEEP=2 FM_POLL=2
  wait_for_lines "$log" 2 300 || { reap_watcher; fail "scan did not start"; }
  printf 'needs-decision: choose the export format\n' >> "$state/other.status"
  wait_for_exit "$WATCHER_PID" 300 || fail "new durable work was held behind the scan"
  grep -q '^signal:' "$out" || fail "the yielded cycle did not surface the new decision: $(cat "$out")"
  [ "$(line_count "$caplog")" -lt 8 ] \
    || fail "the decision waited for the whole scan instead of the next record boundary"
  grep -F 'window scan yielded to newly arrived work' "$state/.watch-triage.log" >/dev/null \
    || fail "the scan did not record its yield"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  rows=$(grep -c "$(printf '\tsignal\t')" "$drain_out" || true)
  [ "$rows" -eq 1 ] || fail "the decision was queued $rows times, not exactly once: $(cat "$drain_out")"
  ack_all "$state" || fail "could not acknowledge the decision"

  # Re-arm: the acknowledged decision is not delivered again, and the scan
  # resumes until every neighbor, including the ones after the yield, is read.
  : > "$out"
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE_LOG="$caplog" FM_FAKE_CREW_STATE_SLEEP=1 FM_POLL=2
  i=0
  while [ "$i" -lt 900 ]; do
    rows=0
    for task in w1 w2 w3 w4 w5-paused w6-held w7-retained w8-last; do
      grep -qx "test:fm-$task" "$caplog" && rows=$((rows + 1))
    done
    [ "$rows" -eq 8 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$WATCHER_PID" || fail "re-armed watcher exited: $(cat "$out")"
  reap_watcher
  [ "$rows" -eq 8 ] || fail "only $rows of 8 neighbors were covered: $(sort -u "$caplog" | tr '\n' ' ')"
  if grep -q '^w5-paused ' "$log" && grep -q '^w6-held ' "$log"; then
    :
  else
    fail "paused or held neighbor was not reconciled: $(cat "$log")"
  fi
  ! grep -q '^w7-retained ' "$log" || fail "the retained neighbor paid a current-state read"
  [ ! -s "$out" ] || fail "the acknowledged decision was delivered again: $(cat "$out")"
  pass "new work interrupts a long scan once, and paused, held, retained, and later neighbors are still covered"
}

# --- a superseded watcher stands down without vouching for the home ---------

test_owner_change_mid_scan_stands_down() {
  local dir state fakebin out log rival old_epoch rc
  dir=$(make_case owner-change); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; log="$dir/crew-state.log"
  install_scan_fakes "$fakebin"
  for i in 1 2 3 4 5 6; do add_window "$state" "o$i" "working: part $i"; done
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" FM_FAKE_CREW_STATE_SLEEP=1
  wait_for_lines "$log" 1 300 || { reap_watcher; fail "scan did not start"; }
  sleep 300 &
  rival=$!
  printf '%s\n' "$rival" > "$state/.watch.lock/pid"
  # Let a beat that read the old owner before the switch land first.
  sleep 0.5
  old_epoch=$(( $(date +%s) - 100 ))
  set_beacon_mtime "$old_epoch" "$state/.last-watcher-beat"
  wait_for_exit "$WATCHER_PID" 300
  rc=$?
  kill "$rival" 2>/dev/null || true
  wait "$rival" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "superseded watcher did not stand down cleanly (rc=$rc)"
  [ "$(bash -c '. "$1"; fm_path_mtime "$2"' _ "$WAKE_LIB" "$state/.last-watcher-beat")" -eq "$old_epoch" ] \
    || fail "superseded watcher touched the beacon after losing the singleton"
  [ "$(line_count "$log")" -lt 6 ] || fail "superseded watcher kept scanning"
  [ "$(cat "$state/.watch.lock/pid")" = "$rival" ] || fail "superseded watcher disturbed the new owner's lock"
  rm -rf "$state/.watch.lock"
  pass "a watcher that loses the singleton mid-scan stops at the next record without touching the beacon"
}

set_beacon_mtime() {  # <epoch> <file>
  local stamp
  if stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null); then :; else stamp=$(date -d "@$1" +%Y%m%d%H%M.%S); fi
  touch -t "$stamp" "$2"
}

# --- the arm follows a slow-scanning watcher and a re-arm attaches ----------

test_arm_follows_slow_scan_and_rearm_attaches() {
  local dir state fakebin armout rearmout log arm rearm i status
  dir=$(make_case arm-follow); state="$dir/state"; fakebin="$dir/fakebin"
  armout="$dir/arm.out"; rearmout="$dir/rearm.out"; log="$dir/crew-state.log"
  install_scan_fakes "$fakebin"
  for i in 1 2 3 4 5 6 7 8 9 10; do add_window "$state" "a$i" "working: part $i"; done
  printf 'working: other task\n' > "$state/other.status"
  prime_status_seen "$state" "$state/other.status"
  arm_env() {
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_SECONDMATE_LIVENESS_SECS=99999999 FM_STALE_ESCALATE_SECS=999 \
      FM_WATCHER_STALE_GRACE="$GRACE" FM_GUARD_GRACE="$GRACE" FM_WATCHER_STALL_BOUND=600 \
      FM_FAKE_TMUX_WINDOWS="$(windows_of "$state")" FM_FAKE_CREW_STATE_LOG="$log" \
      FM_FAKE_CREW_STATE_SLEEP=3 \
      FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=30 "$@"
  }
  arm_env "$WATCH_ARM" > "$armout" &
  arm=$!
  # Wait until the scan has outlived the grace, then re-arm as the next Stop would.
  i=0
  while [ "$i" -lt 1200 ] && [ "$(line_count "$log")" -lt 8 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(line_count "$log")" -ge 8 ] || { kill "$arm" 2>/dev/null; fail "scan did not progress under the arm: $(cat "$armout")"; }
  [ $(( $(date +%s) - $(head -1 "$log" | awk '{print $2}') )) -ge "$GRACE" ] \
    || { kill "$arm" 2>/dev/null; fail "the re-arm came inside the grace; the case is vacuous"; }
  arm_env "$WATCH_ARM" > "$rearmout" &
  rearm=$!
  i=0
  while [ "$i" -lt 100 ] && ! grep -q 'watcher: attached pid=' "$rearmout" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -q 'watcher: attached pid=' "$rearmout" \
    || { kill "$arm" "$rearm" 2>/dev/null; fail "a re-arm during the slow scan did not attach: $(cat "$rearmout")"; }
  assert_not_contains "$(cat "$armout")" 'watcher: FAILED' "the arm failed its slow-scanning watcher"
  printf 'needs-decision: choose the export format\n' >> "$state/other.status"
  wait_for_exit "$arm" 600
  status=$?
  expect_code 0 "$status" "the arm that owned the slow cycle must close with its wake"
  grep -q '^signal:' "$armout" || fail "the arm did not report the wake: $(cat "$armout")"
  wait_for_exit "$rearm" 400
  status=$?
  expect_code 0 "$status" "the attached re-arm must close with the same wake"
  grep -q '^signal:' "$rearmout" || fail "the attached re-arm did not report the wake: $(cat "$rearmout")"
  assert_not_contains "$(cat "$rearmout")" 'watcher: FAILED' "the attached re-arm failed"
  pass "an arm keeps following a slow-scanning watcher, a re-arm attaches to it, and both close with its wake"
}

test_slow_progressing_scan_keeps_beacon_fresh
test_slow_signal_triage_keeps_beacon_fresh
test_hung_observation_ages_beacon_then_surfaces
test_new_work_yields_scan_and_coverage_resumes
test_owner_change_mid_scan_stands_down
test_arm_follows_slow_scan_and_rearm_attaches

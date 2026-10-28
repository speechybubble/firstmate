#!/usr/bin/env bash
# tests/fm-wake-drain-filtered-pipe.test.sh - a drain read whose stdout feeds a
# same-pipeline reader (grep, head, tail, cut, a process substitution, or the
# shell's own last pipeline stage) refuses before it consumes, stages, or
# acknowledges anything, while every whole-output caller keeps working: a
# $(...) capture (the session-start and harness shape), a file redirect (the
# supervision host shape), and the --decisions and --ack-through invocations
# even when piped. The verdict is a kernel fact (/proc pipe holders), so real
# processes and no harness are the whole proof.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-filtered-pipe-tests)

mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

REFUSAL='wake drain: refused - stdout is piped into'

# Snapshot every state file so a refusal can be shown to have touched nothing.
state_digest() {  # <state>
  (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"; cksum < "$f"
  done)
}

queued_case() {  # <name> -> state dir holding one queued signal and one unread note
  local state
  state="$(make_case "$1")/state"
  printf 'note: captain said ship the REST version\n' > "$state/task1.status"
  append_wake "$state" signal task1 'task1 note'
  printf '%s\n' "$state"
}

# Run <command> through bash with the drain under FM_STATE_OVERRIDE=<state>;
# the command sees the drain path as $1.
run_shape() {  # <state> <err> <command>
  FM_STATE_OVERRIDE="$1" bash -c "$3" _ "$DRAIN" 2> "$2" < /dev/null
}

test_pipeline_readers_are_refused_and_change_nothing() {
  local state err before reader shape out
  if ! [ -d "/proc/$$/fd" ]; then
    pass "filtered drain refusal: skipped, this platform has no /proc pipe holders to inspect"
    return
  fi
  state=$(queued_case refused)
  err="$state/../err"
  before=$(state_digest "$state")
  # Each shape names the reader the refusal must report; the lastpipe shape is
  # the only one whose reader is the drain's own parent shell.
  while IFS='|' read -r reader shape; do
    out=$(run_shape "$state" "$err" "$shape") && fail "a filtered drain exited zero for: $shape"
    assert_contains "$out$(cat "$err")" "$REFUSAL $reader (pid " "a filtered drain did not refuse naming $reader for: $shape"
    case "$out" in
      *'task1 note'*|*WAKE_ACK_REQUIRED*|*'UNREAD STATUS'*)
        fail "a refused drain still wrote drain output for: $shape: $out" ;;
    esac
    assert_equals "$before" "$(state_digest "$state")" "a refused drain changed state for: $shape"
  done <<'SHAPES'
head|"$1" | head -3; exit "${PIPESTATUS[0]}"
grep|"$1" 2>&1 | grep -v nothing-matches-this; exit "${PIPESTATUS[0]}"
cut|"$1" | cut -c1-20; exit "${PIPESTATUS[0]}"
tail|"$1" > >(tail -1); rc=$?; wait; exit "$rc"
bash|set +m; shopt -s lastpipe; "$1" | while IFS= read -r l; do printf "%s\n" "$l"; done; exit "${PIPESTATUS[0]}"
SHAPES
  assert_contains "$(cat "$err")" "run bin/fm-wake-drain.sh unfiltered" "the refusal names the recovery"
  pass "a drain piped into head, grep, cut, a process substitution, or the shell's own last stage refuses and changes nothing"
}

test_refusal_is_one_line() {
  local state err
  if ! [ -d "/proc/$$/fd" ]; then
    pass "filtered drain refusal line: skipped, this platform has no /proc pipe holders to inspect"
    return
  fi
  state=$(queued_case named)
  err="$state/../err"
  # shellcheck disable=SC2016 # the shape runs in its own bash with the drain as $1
  run_shape "$state" "$err" '"$1" | head -1 >/dev/null; exit "${PIPESTATUS[0]}"' \
    && fail "a drain piped into head exited zero"
  [ "$(wc -l < "$err")" -eq 1 ] || fail "the refusal is not one line: $(cat "$err")"
  pass "the refusal is one line"
}

test_whole_output_callers_still_drain_and_acknowledge() {
  local state err out ack
  state=$(queued_case captured)
  err="$state/../err"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2> "$err") \
    || fail "a captured drain failed: $(cat "$err")"
  assert_contains "$out" 'task1 note' "a captured drain printed its wake row"
  assert_contains "$out" 'UNREAD STATUS' "a captured drain printed its once-only section"
  ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' "$err" | tail -1)
  [ -n "$ack" ] || fail "a captured drain asked for no acknowledgement: $(cat "$err")"
  # An acknowledgement is not a read, so a piped one still runs.
  # shellcheck disable=SC2086 # the printed acknowledgement is word-split on purpose
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" $ack 2> "$err" | tail -1) \
    || fail "a piped acknowledgement failed: $(cat "$err")"
  assert_contains "$out" 'acknowledged wakes through' "a piped acknowledgement completed"
  [ ! -s "$state/.wake-queue" ] || fail "the acknowledgement left rows queued: $(cat "$state/.wake-queue")"

  state=$(queued_case redirected)
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$state/../out" 2> "$err" \
    || fail "a drain redirected to a file failed: $(cat "$err")"
  assert_contains "$(cat "$state/../out")" 'task1 note' "a redirected drain printed its wake row"

  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" --decisions 2> "$err" | head -5) \
    || fail "a piped --decisions lookup failed: $(cat "$err")"
  assert_contains "$out" 'OPEN DECISIONS' "a piped --decisions lookup still lists"
  assert_not_contains "$(cat "$err")" "$REFUSAL" "a piped --decisions lookup was refused"
  pass "captured, redirected, piped --decisions, and piped acknowledgement callers behave as before"
}

fm_test_run \
  test_pipeline_readers_are_refused_and_change_nothing \
  test_refusal_is_one_line \
  test_whole_output_callers_still_drain_and_acknowledge

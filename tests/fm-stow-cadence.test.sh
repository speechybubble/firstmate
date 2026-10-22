#!/usr/bin/env bash
# Behavior tests for the two context-loss device libraries and the stow marker:
#   - bin/fm-drain-filter-lib.sh: the per-command classifier and the per-turn
#     transcript scan behind the turn-end guard's "filtered drain read" block
#   - bin/fm-stow-cadence-lib.sh: the per-session compaction counter, the fixed
#     every-second-compaction cadence, the stow-required record, and its
#     live-pid matching
#   - bin/fm-stow-mark.sh: recording a pass for the lock-owning session
# Hermetic over temp dirs and fixture transcripts; no harness is invoked.
set -u
unset FM_HOME FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-drain-filter-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-stow-cadence-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stow-cadence)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

classify() { printf '%s\n' "$1" | fm_drain_filter_classify; }

# --- classifier ---------------------------------------------------------------

test_classifier_verdicts() {
  local out
  # shellcheck disable=SC2016 # the literal $F is the fixture command text, not an expansion
  out=$(classify 'F=/x; timeout 60 $F/bin/fm-wake-drain.sh 2>&1 | tail -40; echo done')
  assert_equals "filtered	tail	timeout 60 \$F/bin/fm-wake-drain.sh 2>&1 | tail -40" "$out" "a drain piped into tail is a filtered read"
  out=$(classify 'bin/fm-wake-drain.sh 2>&1')
  assert_equals unfiltered "$out" "a plain drain read is unfiltered"
  # shellcheck disable=SC2016 # the literal $F is the fixture command text, not an expansion
  out=$(classify '$F/bin/fm-wake-drain.sh --ack-through 2330 --recovery-generation 1.2.x 2>&1 | tail -5')
  assert_equals "" "$out" "an acknowledgement is not a read even when filtered"
  out=$(classify 'bin/fm-wake-drain.sh --decisions | head -3')
  assert_equals "" "$out" "the decisions listing is not a read"
  out=$(classify "$(printf 'FM_HOME=/h bin/fm-wake-drain.sh 2>&1 | \\\n  sed -n 1,40p')")
  assert_contains "$out" "filtered	sed	" "a continuation-line pipe into sed is a filtered read"
  out=$(classify 'bin/fm-wake-drain.sh | tail -30 && bin/fm-wake-drain.sh')
  assert_equals "$(printf 'filtered\ttail\tbin/fm-wake-drain.sh | tail -30\nunfiltered')" "$out" "statements are classified in order"
  out=$(classify 'bin/fm-wake-drain.sh > /tmp/d.txt 2>&1
grep -n DECISION /tmp/d.txt')
  assert_equals "$(printf 'redirect\t/tmp/d.txt\nfiltered\tgrep\tgrep -n DECISION /tmp/d.txt')" "$out" "a redirected read that a later filter reads is filtered"
  out=$(classify 'bin/fm-wake-drain.sh 2>&1 | tee /tmp/x.log
head -50 /tmp/x.log')
  assert_equals "$(printf 'redirect\t/tmp/x.log\nfiltered\thead\thead -50 /tmp/x.log')" "$out" "a tee copy that a later filter reads is filtered"
  out=$(classify 'bin/fm-wake-drain.sh > /tmp/d.txt; cat /tmp/d.txt')
  assert_equals "$(printf 'redirect\t/tmp/d.txt\nunfiltered')" "$out" "a redirected read that cat prints whole is an unfiltered read"
  out=$(FM_DRAIN_FILTER_PENDING=$'/tmp/earlier.txt\n' classify 'cut -c1-80 /tmp/earlier.txt')
  assert_equals "filtered	cut	cut -c1-80 /tmp/earlier.txt" "$out" "a file an earlier command redirected into is tracked across commands"
  out=$(classify 'ls state | grep status')
  assert_equals "" "$out" "a filter that never touches the drain prints nothing"
  out=$(classify 'grep -rn fm-wake-drain.sh docs | head -20')
  assert_equals "" "$out" "naming the drain script as a grep argument is not a read"
  out=$(classify 'git diff -- bin/fm-wake-drain.sh | head')
  assert_equals "" "$out" "a git diff of the drain script is not a read"
  out=$(classify 'cat bin/fm-wake-drain.sh | sed -n 1,40p')
  assert_equals "" "$out" "cat of the drain source piped into sed is not a read"
  out=$(classify 'timeout 60 bash /r/bin/fm-wake-drain.sh 2>&1 | tail -3')
  assert_contains "$out" "filtered	tail	" "a drain run through timeout and bash is still a read"
  out=$(classify 'bin/fm-wake-drain.sh > /tmp/d.txt
cat /tmp/d.txt
grep OPEN /tmp/d.txt')
  assert_equals "$(printf 'redirect\t/tmp/d.txt\nunfiltered')" "$out" "a redirected read that cat prints whole is cleared before a later grep"
  pass "fm_drain_filter_classify: verdicts for piped, redirected, acknowledged, and unrelated commands"
}

# --- transcript scan ------------------------------------------------------------

# Fixture transcript lines in Claude's JSONL shape.
user_turn() {  # <uuid> <text>
  printf '{"type":"user","uuid":"%s","message":{"role":"user","content":"%s"}}\n' "$1" "$2"
}
user_tool_result() {  # <uuid>
  printf '{"type":"user","uuid":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}\n' "$1"
}
compact_summary() {  # <uuid>
  printf '{"type":"user","uuid":"%s","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}\n' "$1"
}
bash_call() {  # <uuid> <command> [sidechain]
  jq -cn --arg uuid "$1" --arg cmd "$2" --argjson side "${3:-false}" \
    '{type:"assistant",uuid:$uuid,isSidechain:$side,message:{role:"assistant",content:[{type:"tool_use",id:"t",name:"Bash",input:{command:$cmd}}]}}'
}
text_reply() {  # <uuid>
  printf '{"type":"assistant","uuid":"%s","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}\n' "$1"
}

test_scan_blocks_filtered_read_in_current_turn() {
  local t="$TMP_ROOT/scan-filtered.jsonl"
  {
    user_turn u1 "first ask"
    bash_call a1 'bin/fm-wake-drain.sh'
    user_tool_result r1
    text_reply a2
    user_turn u2 "second ask"
    bash_call a3 'FM_HOME=/h /r/bin/fm-wake-drain.sh 2>&1 | tail -40'
    user_tool_result r2
  } > "$t"
  fm_drain_filter_scan "$t" || fail "a filtered read in the current turn must be detected"
  assert_equals u2 "$FM_DRAIN_FILTER_TURN" "the turn identity is the opening user entry of the current turn"
  assert_equals tail "$FM_DRAIN_FILTER_NAME" "the filter is named"
  assert_contains "$FM_DRAIN_FILTER_COMMAND" "fm-wake-drain.sh 2>&1 | tail -40" "the offending statement is reported"
  pass "fm_drain_filter_scan: a filtered read in the current turn is detected with its turn and filter"
}

test_scan_clears_on_later_unfiltered_read() {
  local t="$TMP_ROOT/scan-cleared.jsonl"
  {
    user_turn u1 "ask"
    bash_call a1 'bin/fm-wake-drain.sh | head -20'
    user_tool_result r1
    bash_call a2 'bin/fm-wake-drain.sh'
    user_tool_result r2
  } > "$t"
  if fm_drain_filter_scan "$t"; then
    fail "a later unfiltered read must clear the filtered one"
  fi
  pass "fm_drain_filter_scan: a later unfiltered read clears the turn"
}

test_scan_ignores_earlier_turn_and_acknowledgements() {
  local t="$TMP_ROOT/scan-earlier.jsonl"
  {
    user_turn u1 "ask"
    bash_call a1 'bin/fm-wake-drain.sh | grep DECISION'
    user_tool_result r1
    user_turn u2 "next ask"
    bash_call a2 'bin/fm-wake-drain.sh --ack-through 12 --recovery-generation 1.2.x | tail -3'
    user_tool_result r2
  } > "$t"
  if fm_drain_filter_scan "$t"; then
    fail "an earlier turn's filtered read and this turn's acknowledgement must not block"
  fi
  pass "fm_drain_filter_scan: an earlier turn's filtered read is not charged to this turn"
}

test_scan_turn_survives_compaction_summary() {
  local t="$TMP_ROOT/scan-compact.jsonl"
  {
    user_turn u1 "ask"
    bash_call a1 'bin/fm-wake-drain.sh 2>&1 | cut -c1-120'
    user_tool_result r1
    compact_summary c1
    bash_call a2 'ls state'
    user_tool_result r2
  } > "$t"
  fm_drain_filter_scan "$t" || fail "a compaction summary continues the turn, so the filtered read before it still counts"
  assert_equals u1 "$FM_DRAIN_FILTER_TURN" "the turn identity is unchanged by the compaction summary"
  pass "fm_drain_filter_scan: a compaction summary does not start a new turn"
}

test_scan_ignores_sidechain_and_tracks_redirects_across_commands() {
  local t="$TMP_ROOT/scan-side.jsonl"
  {
    user_turn u1 "ask"
    bash_call s1 'bin/fm-wake-drain.sh | tail -5' true
    user_tool_result r1
  } > "$t"
  if fm_drain_filter_scan "$t"; then
    fail "a subagent's filtered read must not be charged to the primary turn"
  fi
  {
    user_turn u1 "ask"
    bash_call a1 'bin/fm-wake-drain.sh > /tmp/drain.out 2>&1'
    user_tool_result r1
    bash_call a2 'grep -c OPEN /tmp/drain.out'
    user_tool_result r2
  } > "$t"
  fm_drain_filter_scan "$t" || fail "a redirected read filtered by a later command must be detected"
  assert_equals grep "$FM_DRAIN_FILTER_NAME" "the later filter is named"
  pass "fm_drain_filter_scan: sidechain reads are ignored and redirect-then-filter spans commands"
}

test_scan_never_blocks_on_unreadable_input() {
  local t="$TMP_ROOT/scan-garbage.jsonl"
  if fm_drain_filter_scan "$TMP_ROOT/does-not-exist.jsonl"; then
    fail "an absent transcript must never block"
  fi
  printf 'not json\n{"type":"assistant"\n' > "$t"
  if fm_drain_filter_scan "$t"; then
    fail "an unparseable transcript must never block"
  fi
  {
    user_turn u1 "ask"
    bash_call a1 'bin/fm-wake-drain.sh | sed -n 1,5p'
    user_tool_result r1
  } > "$t"
  if PATH="$TMP_ROOT/empty-path" fm_drain_filter_scan "$t"; then
    fail "a missing jq must never block"
  fi
  pass "fm_drain_filter_scan: absent, unparseable, and jq-less inputs never block"
}

test_scan_window_without_turn_boundary_still_counts() {
  local t="$TMP_ROOT/scan-window.jsonl"
  {
    user_turn u1 "ask"
    bash_call a1 'bin/fm-wake-drain.sh | head -3'
    user_tool_result r1
  } > "$t"
  fm_drain_filter_scan "$t" 2 || fail "a window holding only part of the turn still counts its filtered read"
  assert_equals "window:a1" "$FM_DRAIN_FILTER_TURN" "the turn identity falls back to the window's first entry"
  pass "fm_drain_filter_scan: a bounded window without a turn boundary is still one turn"
}

# --- cadence ----------------------------------------------------------------

new_home() {  # <name> -> echoes the home; its state dir is state/
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_cadence_default_every_two_and_mark_resets() {
  local home state
  home=$(new_home cadence-default); state="$home/state"
  if fm_stow_cadence_record_compaction "$state" "$$" sess-1; then
    fail "the first compaction must not require a pass"
  fi
  assert_equals 1 "$FM_STOW_CADENCE_COUNT" "first compaction counted"
  assert_equals 0 "$FM_STOW_CADENCE_DUE" "nothing due after one compaction"
  [ ! -e "$state/.stow-required" ] || fail "no stow-required record after one compaction"
  fm_stow_cadence_record_compaction "$state" "$$" sess-1 || fail "the second compaction must require a pass"
  assert_equals 2 "$FM_STOW_CADENCE_EVERY" "the cadence is the captain's fixed 2"
  [ -f "$state/.stow-required" ] || fail "the second compaction must write the stow-required record"
  fm_stow_cadence_required "$state" "$$" sess-1 || fail "the record must match the live session"
  assert_equals 2 "$FM_STOW_CADENCE_REQUIRED_COUNT" "the record names the compaction that made the pass due"
  if fm_stow_cadence_record_compaction "$state" "$$" sess-1; then
    fail "a third compaction with the pass still owed must not write a second record"
  fi
  assert_equals 1 "$FM_STOW_CADENCE_DUE" "the pass stays due until marked"
  fm_stow_cadence_mark "$state" "$$" sess-1 || fail "mark must succeed"
  [ ! -e "$state/.stow-required" ] || fail "mark must remove the stow-required record"
  [ -f "$state/.stow-pass" ] || fail "mark must write the stow-pass marker"
  if fm_stow_cadence_required "$state" "$$" sess-1; then
    fail "nothing is required after the mark"
  fi
  if fm_stow_cadence_record_compaction "$state" "$$" sess-1; then
    fail "the first compaction after a mark must not require a pass"
  fi
  assert_equals 1 "$FM_STOW_CADENCE_SINCE" "the cadence counts from the last pass"
  fm_stow_cadence_record_compaction "$state" "$$" sess-1 || fail "the second compaction after a mark must require a pass again"
  pass "fm_stow_cadence: every second compaction since the last pass requires one, the number is fixed, and the mark resets the cadence"
}

test_cadence_session_identity() {
  local home state dead
  home=$(new_home cadence-identity); state="$home/state"
  fm_stow_cadence_record_compaction "$state" "$$" sess-a >/dev/null
  fm_stow_cadence_record_compaction "$state" "$$" sess-a || fail "second compaction must require"
  fm_stow_cadence_required "$state" "$$" || fail "the record matches the live pid"
  fm_stow_cadence_record_compaction "$state" "$$" sess-after-clear
  fm_stow_cadence_required "$state" "$$" || fail "a /clear that keeps the pid under a new session id still owes the pass"
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
  printf 'pid=%s\nsession=\ncount=2\nat=1\n' "$dead" > "$state/.stow-required"
  if fm_stow_cadence_required "$state" "$dead"; then
    fail "a record for a dead pid must not block"
  fi
  if fm_stow_cadence_record_compaction "$state" "$((dead + 1))"; then
    fail "a new pid starts its own count at one"
  fi
  assert_equals 1 "$FM_STOW_CADENCE_COUNT" "a different pid resets the counter"
  [ ! -e "$state/.stow-required" ] || fail "a stale record for another pid is dropped by the new session's first compaction"
  pass "fm_stow_cadence_required: matches the live recorded pid only, across a session id change"
}

test_stow_mark_script() {
  local home state out status
  home=$(new_home mark); state="$home/state"
  out=$(FM_HOME="$home" bash "$ROOT/bin/fm-stow-mark.sh" 2>&1); status=$?
  expect_code 1 "$status" "mark without a session lock must fail"
  assert_contains "$out" "holds no session pid" "mark names the missing lock"
  printf '%s\n' "$$" > "$state/.lock"
  printf 'sess-m\n' > "$state/.lock-session"
  printf 'pid=%s\nsession=sess-m\ncount=2\nat=1\n' "$$" > "$state/.stow-required"
  out=$(FM_HOME="$home" bash "$ROOT/bin/fm-stow-mark.sh" 2>&1); status=$?
  expect_code 0 "$status" "mark with a session lock succeeds"
  assert_contains "$out" "stow pass recorded for session pid $$" "mark reports the session it recorded"
  [ ! -e "$state/.stow-required" ] || fail "mark must release the stow-required record"
  assert_contains "$(cat "$state/.stow-pass")" "session=sess-m" "the marker records the lock session"
  out=$(FM_HOME="$home" bash "$ROOT/bin/fm-stow-mark.sh" --help 2>&1); status=$?
  expect_code 0 "$status" "--help exits 0"
  assert_contains "$out" "Usage: fm-stow-mark.sh" "--help prints the header"
  pass "fm-stow-mark.sh: records the pass for the lock-owning session and refuses without one"
}

test_classifier_verdicts
test_scan_blocks_filtered_read_in_current_turn
test_scan_clears_on_later_unfiltered_read
test_scan_ignores_earlier_turn_and_acknowledgements
test_scan_turn_survives_compaction_summary
test_scan_ignores_sidechain_and_tracks_redirects_across_commands
test_scan_never_blocks_on_unreadable_input
test_scan_window_without_turn_boundary_still_counts
test_cadence_default_every_two_and_mark_resets
test_cadence_session_identity
test_stow_mark_script

echo "# fm-stow-cadence.test.sh: all assertions passed"

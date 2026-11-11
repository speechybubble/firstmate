#!/usr/bin/env bash
# Behavior tests for bin/fm-fresh-read.sh and the three places it hooks in:
# the scout brief's step, the wake drain's line under a scout done, and the
# setting.
#
# The regression this guards: reports that reached the captain resting on
# numbers, tiers and dates nobody traced to the captain's words, because the
# check that would have caught them depended on someone remembering to run it.
# Every test drives the script's public commands in an isolated home with a
# stub `claude` first on PATH, so no test calls a real model; the stub records
# its arguments, working directory and prompt, and answers from a fixture.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

unset FM_HOME FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

TMP_ROOT=$(fm_test_tmproot fm-fresh-read)
FR="$ROOT/bin/fm-fresh-read.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
# Stub reader: FRESH_STUB_MODE picks the behavior; FRESH_STUB_DIR receives what
# the reader was started with.
printf '%s\n' "$@" > "$FRESH_STUB_DIR/argv"
pwd > "$FRESH_STUB_DIR/cwd"
ls -A > "$FRESH_STUB_DIR/cwd-files"
cat > "$FRESH_STUB_DIR/prompt"
case "${FRESH_STUB_MODE:-answer}" in
  fail) echo "stub: credentials expired" >&2; exit 3 ;;
  hang) sleep 30; exit 0 ;;
  error) printf '{"type":"result","is_error":true,"result":"overloaded"}\n' ;;
  garbage) printf 'not json at all\n' ;;
  answer) jq -n --rawfile r "$FRESH_STUB_ANSWER" '{type:"result",is_error:false,result:$r}' ;;
esac
SH
chmod +x "$FAKEBIN/claude"
PATH="$FAKEBIN:$PATH"
export PATH

# assert_match <basic-regex> <file> <msg>: a whole-line shape must match in <file>.
assert_match() {
  grep -- "$1" "$2" >/dev/null || fail "$3"
}

# new_task <name>: an isolated home with one scout task holding a filled brief
# and a report; sets TASK to the task folder and FRESH_STUB_DIR for the stub.
new_task() {
  local home="$TMP_ROOT/$1-home" dir
  dir="$home/data/$1"
  mkdir -p "$dir" "$home/config" "$home/state" "$TMP_ROOT/$1-stub"
  export FRESH_STUB_DIR="$TMP_ROOT/$1-stub"
  cat > "$dir/brief.md" <<'EOF'
You are a crewmate.

# Task
<!-- fm-brief: task-slots v4 -->
## Captain's intent
"find me ten prospects a week, the cole pricing is right"

## Confirmed intent
Reading: a weekly list of ten prospects at the agreed pricing.
captain confirmed: yes do that
end state: a list exists each week
delegation: built with defaults

## Firstmate spec
BUILD-ONLY-INSTRUCTION that is not the captain's.

## Checks
routine: no checks - fixture

# Setup
Not part of the task.
EOF
  printf 'Summary.\nWe plan 290 prospects a month.\nLaunch is 18 December.\n' > "$dir/report.md"
  TASK=$dir
}

# answer <a-items> <b-items> <c-items>: write the stub's fixture answer.
answer() {
  local file="$TMP_ROOT/answer.$RANDOM" letter count i
  : > "$file"
  for letter in A B C; do
    count=$1
    shift
    printf '## %s\n' "$letter" >> "$file"
    if [ "$count" -eq 0 ]; then
      printf 'none\n' >> "$file"
    else
      for i in $(seq 1 "$count"); do
        printf '%s. lines 2: finding %s%s quoting "290 prospects a month"\n' "$i" "$letter" "$i" >> "$file"
      done
    fi
  done
  export FRESH_STUB_ANSWER="$file"
}

test_reader_is_fresh_and_sees_only_the_report_and_the_captains_words() {
  local dir out rc
  new_task fresh
  dir=$TASK
  answer 2 1 1
  out=$(FRESH_STUB_MODE=answer "$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "run"
  assert_contains "$out" "fresh read: 2 untraced, 1 unowned date, 1 question for the captain - $dir/fresh-read.md" \
    "run must print the counts and the list's path"
  assert_equals "" "$(cat "$FRESH_STUB_DIR/cwd-files")" "the reader must start in an empty directory"
  assert_not_equals "$(pwd -P)" "$(cat "$FRESH_STUB_DIR/cwd")" "the reader must not start in the caller's directory"
  assert_match '^claude-opus-5-5$' "$FRESH_STUB_DIR/argv" "the reader must run on Opus 5.5 by default"
  assert_match '^high$' "$FRESH_STUB_DIR/argv" "the reader must run at high effort by default"
  assert_equals "--tools" "$(grep -B1 -x '' "$FRESH_STUB_DIR/argv" | head -1)" "the reader must be given no tools"
  for flag in --strict-mcp-config --no-session-persistence '{"disableAllHooks":true}' '{"mcpServers":{}}'; do
    grep -Fxq -- "$flag" "$FRESH_STUB_DIR/argv" || fail "the reader must be started with $flag"
  done
  assert_grep 'find me ten prospects a week, the cole pricing is right' "$FRESH_STUB_DIR/prompt" \
    "the reader must see the captain's intent"
  assert_grep 'captain confirmed: yes do that' "$FRESH_STUB_DIR/prompt" "the reader must see the confirmed intent"
  assert_match '^   2| We plan 290 prospects a month\.$' "$FRESH_STUB_DIR/prompt" "the reader must see the line-numbered report"
  assert_no_grep 'BUILD-ONLY-INSTRUCTION' "$FRESH_STUB_DIR/prompt" "Firstmate's spec is not the captain's words"
  assert_no_grep 'Not part of the task' "$FRESH_STUB_DIR/prompt" "the rest of the brief must not reach the reader"
  assert_grep 'at most seven items in each' "$FRESH_STUB_DIR/prompt" "the reader must be given the narrowing"
  assert_grep '(6) list the questions the author should have put to the captain' "$FRESH_STUB_DIR/prompt" \
    "the reader must be given the six-point standard"
  pass "fresh read: the reader starts fresh with no tools and sees only the report and the captain's words"
}

test_list_shape_caps_each_list_at_seven_and_records_the_run() {
  local dir out
  new_task shape
  dir=$TASK
  answer 9 0 3
  out=$("$FR" run "$dir") || fail "run failed"
  assert_equals "<!-- fm-fresh-read: state=ran a=7 b=0 c=3 report=$({ sha256sum "$dir/report.md" 2>/dev/null || shasum -a 256 "$dir/report.md"; } | cut -d' ' -f1) -->" \
    "$(head -1 "$dir/fresh-read.md")" "the list's first line must record the state, counts and the report read"
  assert_equals 7 "$(grep -c '^- a[0-9]*: ' "$dir/fresh-read.md")" "list A must hold at most seven items"
  assert_match '^- a7: lines 2: finding A7 ' "$dir/fresh-read.md" "the seventh item must be kept in the reader's order"
  assert_no_grep 'finding A8' "$dir/fresh-read.md" "an eighth item must be dropped"
  assert_match '^2 more dropped' "$dir/fresh-read.md" "dropped items must be counted in the list"
  assert_match '^None\.$' "$dir/fresh-read.md" "an empty list must say none"
  assert_equals 3 "$(grep -c '^- c[0-9]*: ' "$dir/fresh-read.md")" "list C must hold its three items"
  assert_grep 'no decisions-on-record file' "$dir/fresh-read.md" "the list must say which record of the captain's words it had"
  assert_equals "shape	run	ran	a=7 b=0 c=3" "$(cut -f2-5 "$dir/../fresh-read-ledger.tsv")" "the run must land in the ledger with its counts"
  assert_absent "$dir/fresh-read.raw.md" "a parsed answer leaves no raw copy"
  pass "fresh read: each list holds at most seven items and the run is recorded"
}

test_reader_failure_and_timeout_never_block() {
  local dir out rc start
  new_task failing
  dir=$TASK
  answer 1 1 1
  out=$(FRESH_STUB_MODE=fail "$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "a failing reader"
  assert_contains "$out" "fresh read did not run (the reader exited 3: stub: credentials expired" "the failure must be said plainly"
  assert_grep 'state=not-run' "$dir/fresh-read.md" "a failed reader must leave a list that records it did not run"
  assert_match '^The fresh reader did not run: the reader exited 3' "$dir/fresh-read.md" "the list must say why"
  assert_grep "fm-fresh-read.sh' run '$dir'" "$dir/fresh-read.md" "the list must give the command that runs it"

  printf 'timeout=1\n' > "$dir/../../config/fresh-read"
  start=$(date +%s)
  out=$(FRESH_STUB_MODE=hang "$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "a reader past its time limit"
  [ $(( $(date +%s) - start )) -lt 20 ] || fail "a slow reader must be cut off at its time limit, not waited for"
  assert_contains "$out" "still reading at its 1s time limit" "the timeout must be said plainly"
  assert_grep 'state=not-run' "$dir/fresh-read.md" "a timed-out reader must leave a not-run list"
  rm -f "$dir/../../config/fresh-read"

  out=$(FRESH_STUB_MODE=error "$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "a reader that reports an error"
  assert_contains "$out" "the reader reported an error: overloaded" "a reported error must be said plainly"
  out=$(FRESH_STUB_MODE=garbage "$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "a reader with an unreadable answer"
  assert_contains "$out" "no readable answer" "an unreadable answer must be said plainly"

  printf 'Here are my thoughts in prose, with no lists.\n' > "$TMP_ROOT/prose"
  out=$(FRESH_STUB_ANSWER="$TMP_ROOT/prose" "$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "an answer in another shape"
  assert_contains "$out" "not the three lists asked for" "an answer in another shape must not be passed on as a list"
  assert_grep 'no lists' "$dir/fresh-read.raw.md" "an answer in another shape must be kept for whoever looks"

  # The system tools without claude, so the case can never reach a real reader
  # installed in a system directory.
  out=$(PATH="$(fm_test_base_path_sans "/usr/bin:/bin" claude)" "$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "a machine without the reader"
  assert_contains "$out" "not on this machine's PATH" "a missing reader must be said plainly"

  rm -f "$dir/report.md"
  out=$("$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "a task with no report"
  assert_contains "$out" "no report at" "a missing report must be said plainly"
  assert_equals 7 "$(awk -F'\t' '$3 == "run" && $4 == "not-run"' "$dir/../fresh-read-ledger.tsv" | wc -l | tr -d ' ')" \
    "every run that did not read must land in the ledger"
  pass "fresh read: a failed, slow, missing or malformed reader exits 0 and says so in the list"
}

test_words_include_named_decisions_and_name_a_missing_one() {
  local dir out rc home
  new_task words
  dir=$TASK
  home="$dir/../.."
  printf 'Decided 3 Nov: prices are the same number in AUD and USD.\n' > "$home/data/decisions.md"
  printf '# the record the back-test lacked\ndecisions=data/decisions.md\ndecisions=%s\n' "$TMP_ROOT/absent.md" > "$home/config/fresh-read"
  out=$("$FR" words "$dir"); rc=$?
  expect_code 0 "$rc" "words"
  assert_contains "$out" "find me ten prospects a week" "words must carry the captain's intent"
  assert_contains "$out" "captain confirmed: yes do that" "words must carry the confirmed intent"
  assert_contains "$out" "same number in AUD and USD" "words must carry a named decisions-on-record file"
  assert_contains "$out" "($TMP_ROOT/absent.md): this file could not be read" "a missing decisions file must be named, not skipped"
  assert_not_contains "$out" "BUILD-ONLY-INSTRUCTION" "words must leave out Firstmate's spec"
  answer 1 0 0
  "$FR" run "$dir" >/dev/null || fail "run with decisions files failed"
  assert_grep 'same number in AUD and USD' "$FRESH_STUB_DIR/prompt" "the reader must be given the decisions on record"
  assert_match '^- decisions on record: data/decisions.md$' "$dir/fresh-read.md" "the list must name the decisions file it had"
  assert_grep 'absent.md (MISSING' "$dir/fresh-read.md" "the list must say a decisions file was missing"

  awk '!/^## (Captain|Confirmed)/' "$dir/brief.md" | sed "s/^\"find me.*//; s/^Reading:.*//; s/^captain confirmed.*//" > "$dir/brief.tmp"
  printf '# Task\n## Firstmate spec\nonly a spec\n' > "$dir/brief.md"
  out=$("$FR" words "$dir" 2>&1); rc=$?
  expect_code 1 "$rc" "words for a brief without the captain's words"
  out=$("$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "run for a brief without the captain's words"
  assert_contains "$out" "has no Captain's intent or Confirmed intent" "a brief without the captain's words must not be read against nothing"
  pass "fresh read: the captain's words are the brief's two subsections plus each named decisions file"
}

test_setting_changes_model_and_switches_the_step_off_in_one_line() {
  local dir out rc home
  new_task setting
  dir=$TASK
  home="$dir/../.."
  answer 1 1 1
  printf 'model=claude-sonnet-5-5\neffort=medium\n' > "$home/config/fresh-read"
  "$FR" run "$dir" >/dev/null || fail "run with a model setting failed"
  assert_match '^claude-sonnet-5-5$' "$FRESH_STUB_DIR/argv" "the setting must choose the reader's model"
  assert_match '^medium$' "$FRESH_STUB_DIR/argv" "the setting must choose the reader's effort"
  assert_contains "$("$FR" pointer "$dir")" "fresh read: 1 untraced" "pointer must name a list that exists"

  rm -f "$dir/fresh-read.md" "$FRESH_STUB_DIR/argv"
  printf 'off\n' > "$home/config/fresh-read"
  out=$("$FR" run "$dir"); rc=$?
  expect_code 0 "$rc" "run while switched off"
  assert_contains "$out" "switched off" "run must say the step is off"
  assert_absent "$FRESH_STUB_DIR/argv" "a switched-off step must not start a reader"
  assert_absent "$dir/fresh-read.md" "a switched-off step must write no list"
  assert_equals "" "$("$FR" pointer "$dir")" "a switched-off step must announce nothing"
  assert_equals "" "$("$FR" token "$dir")" "a switched-off step must add no token"
  assert_equals "" "$("$FR" render "$dir")" "a switched-off step must add nothing to a brief"
  pass "fresh read: one setting line picks the model or switches the step off"
}

test_primary_setting_reaches_a_secondmate_home() {
  local primary="$TMP_ROOT/inherit-primary" mate="$TMP_ROOT/inherit-mate"
  mkdir -p "$primary/config" "$mate/config" "$mate/data"
  printf 'off\n' > "$primary/config/fresh-read"
  bash -c '. "$1"; propagate_inheritable_config "$2" "$3"' _ "$ROOT/bin/fm-config-inherit-lib.sh" \
    "$primary/config" "$mate/config" >/dev/null 2>&1 || fail "config propagation to the secondmate home failed"
  assert_equals off "$(cat "$mate/config/fresh-read" 2>/dev/null)" "the primary's fresh-read setting must reach the secondmate home"
  FM_HOME="$mate" "$ROOT/bin/fm-brief.sh" mate-scout some-proj --scout >/dev/null 2>&1 || fail "scout scaffold in the secondmate home failed"
  assert_no_grep 'fm-fresh-read.sh' "$mate/data/mate-scout/brief.md" "a primary that switched the step off switches it off in a secondmate home"
  rm -f "$primary/config/fresh-read"
  bash -c '. "$1"; propagate_inheritable_config "$2" "$3"' _ "$ROOT/bin/fm-config-inherit-lib.sh" \
    "$primary/config" "$mate/config" >/dev/null 2>&1 || fail "config propagation of the removed setting failed"
  FM_HOME="$mate" "$ROOT/bin/fm-brief.sh" mate-scout-on some-proj --scout >/dev/null 2>&1 || fail "second scout scaffold in the secondmate home failed"
  assert_grep "fm-fresh-read.sh' run '$mate/data/mate-scout-on'" "$mate/data/mate-scout-on/brief.md" \
    "a secondmate home with no setting carries the step through the same scaffold"
  pass "fresh read: the primary's setting reaches a secondmate home, where the same scaffold carries the step"
}

test_scout_brief_carries_the_step_and_its_command_runs() {
  local home="$TMP_ROOT/brief-home" dir out line
  mkdir -p "$home/data" "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-scout some-proj --scout >/dev/null 2>&1 || fail "scout scaffold failed"
  dir="$home/data/brief-scout"
  assert_grep "fm-fresh-read.sh' run '$dir'" "$dir/brief.md" "every scout brief must carry the fresh-read command"
  assert_grep 'It always exits 0 and never holds your done line' "$dir/brief.md" "the brief must say the step is advisory"
  line=$(grep -n "fm-fresh-read.sh' run" "$dir/brief.md" | cut -d: -f1)
  [ "$line" -lt "$(grep -n 'When the report is complete, append' "$dir/brief.md" | cut -d: -f1)" ] \
    || fail "the fresh-read step must come before the done line"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-ship some-proj --mode no-mistakes >/dev/null 2>&1 || fail "ship scaffold failed"
  assert_no_grep 'fm-fresh-read.sh' "$home/data/brief-ship/brief.md" "a ship brief must not carry the fresh-read step"
  printf 'off\n' > "$home/config/fresh-read"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-off some-proj --scout >/dev/null 2>&1 || fail "scout scaffold with the step off failed"
  assert_no_grep 'fm-fresh-read.sh' "$home/data/brief-off/brief.md" "a home that switched the step off scaffolds no step"
  rm -f "$home/config/fresh-read"

  # The scaffold's own slots, filled as Firstmate would, then the command the
  # worker is told to run, exactly as the brief prints it.
  sed -i.bak "s/{TASK}/\"count the prospects\"/; s/{CONFIRMED_INTENT}/Reading: count them.\\ncaptain confirmed: yes/" "$dir/brief.md"
  printf 'There are 290.\n' > "$dir/report.md"
  mkdir -p "$TMP_ROOT/brief-stub"
  export FRESH_STUB_DIR="$TMP_ROOT/brief-stub"
  answer 1 0 0
  out=$(bash -c "$(sed -n "s/^Then, with the report final, run \`\\(.*\\)\` once and wait.*/\\1/p" "$dir/brief.md")") \
    || fail "the brief's fresh-read command failed: $out"
  assert_contains "$out" "fresh read: 1 untraced" "the brief's command must produce the list"
  assert_grep 'count the prospects' "$FRESH_STUB_DIR/prompt" "the brief's own Captain's intent slot must reach the reader"
  pass "fresh read: every scout brief carries the step before its done line and its command runs"
}

test_drain_points_at_the_list_under_a_scout_done() {
  local case_dir state home dir out
  case_dir=$(make_case drain)
  home="$case_dir"
  state="$home/state"
  dir="$home/data/probe"
  mkdir -p "$dir" "$home/config"
  : > "$home/config/supervision-host-off"
  new_task drainsrc
  cp "$TASK/brief.md" "$dir/brief.md"
  printf 'A report.\n' > "$dir/report.md"
  fm_write_meta "$state/probe.meta" 'kind=scout' "worktree=$home/wt"
  fm_write_meta "$state/shipper.meta" 'kind=ship' "worktree=$home/wt"
  mkdir -p "$home/data/shipper"
  printf 'A ship that happens to hold a report.\n' > "$home/data/shipper/report.md"
  out="$case_dir/drain.out"
  run_drain() {
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$DRAIN" > "$out" 2>/dev/null \
      || fail "drain failed: $(cat "$out")"
  }

  # The scout reported done without a list: the announcement says so.
  printf 'done: findings are in the report\n' > "$state/probe.status"
  printf 'done: PR opened\n' > "$state/shipper.status"
  append_wake "$state" signal probe.status "signal: $state/probe.status" || fail "wake append failed"
  append_wake "$state" signal shipper.status "signal: $state/shipper.status" || fail "wake append failed"
  run_drain
  assert_grep 'probe.status: done: findings are in the report' "$out" "the drain must still present the done line"
  assert_match '^wake annotation: probe.status: fresh read did not run (no list beside the report); to run it: ' "$out" \
    "a scout done with no list must say the reader did not run"
  assert_no_grep 'shipper.status: fresh read' "$out" "a ship's done line must carry no fresh-read line"

  # With the list in place, the next done line points at it with its counts.
  export FRESH_STUB_DIR="$TMP_ROOT/drain-stub"
  mkdir -p "$FRESH_STUB_DIR"
  answer 3 1 2
  FM_CONFIG_OVERRIDE="$home/config" "$FR" run "$dir" >/dev/null || fail "run failed"
  printf 'done: findings are in the report, second pass\n' >> "$state/probe.status"
  append_wake "$state" signal probe.status "signal: $state/probe.status" || fail "wake append failed"
  run_drain
  assert_match "^wake annotation: probe.status: fresh read: 3 untraced, 1 unowned date, 2 questions for the captain - $dir/fresh-read.md\$" "$out" \
    "a scout done must point at the list with its counts"

  # A report edited after the read, and a list file that is not a list, never
  # break the drain.
  printf 'An edit.\n' >> "$dir/report.md"
  printf 'done: third\n' >> "$state/probe.status"
  append_wake "$state" signal probe.status "signal: $state/probe.status" || fail "wake append failed"
  run_drain
  assert_grep 'fresh-read.md (the report changed after it was read)' "$out" "a report edited after the read must be flagged"
  printf 'garbage\n' > "$dir/fresh-read.md"
  printf 'done: fourth\n' >> "$state/probe.status"
  append_wake "$state" signal probe.status "signal: $state/probe.status" || fail "wake append failed"
  run_drain
  assert_grep 'probe.status: done: fourth' "$out" "a broken list file must not hide the done line"
  assert_grep 'probe.status: fresh read did not run (no list beside the report)' "$out" "a broken list file reads as no list"
  pass "fresh read: the drain points at the list under a scout's done line and says when the reader did not run"
}

test_marks_and_tally_give_the_measure_that_retires_the_step() {
  local dir other out rc home i
  new_task tally
  dir=$TASK
  home=$(cd "$dir/../.." && pwd)
  answer 4 1 2
  "$FR" run "$dir" >/dev/null || fail "run failed"
  "$FR" mark "$dir" a1 acted "the tier was the author's" >/dev/null || fail "mark acted failed"
  "$FR" mark "$dir" a2 acted >/dev/null || fail "mark failed"
  "$FR" mark "$dir" a2 ignored "on reflection" >/dev/null || fail "re-mark failed"
  "$FR" mark "$dir" c2 acted >/dev/null || fail "mark failed"
  out=$("$FR" mark "$dir" a5 acted 2>&1); rc=$?
  expect_code 2 "$rc" "marking an item the list does not hold"
  out=$("$FR" mark "$dir" b1 maybe 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown verdict"
  other="$home/data/unread"
  mkdir -p "$other"
  cp "$dir/brief.md" "$other/brief.md"
  "$FR" run "$other" >/dev/null || fail "run without a report failed"
  out=$("$FR" tally "$home")
  assert_contains "$out" "fresh read: 1 of the first 10 reports read (the reader did not run on 1 more)" "tally must count reports read and not read"
  assert_contains "$out" "items: 7 flagged, 2 acted on, 1 ignored, 4 unmarked" "tally must count the latest mark of each item"
  assert_contains "$out" "acted-on share: 29% of flagged items" "tally must give the acted-on share"
  assert_contains "$out" "decision: due after report 10" "tally must say the decision is not due yet"
  assert_contains "$out" "tally	$home	a=4 b=1 c=2	acted=2 ignored=1 unmarked=4" "tally must list each report"

  # A second run of the reader starts that task's marks afresh.
  answer 1 0 0
  "$FR" run "$dir" >/dev/null || fail "second run failed"
  out=$("$FR" tally "$home")
  assert_contains "$out" "items: 1 flagged, 0 acted on, 0 ignored, 1 unmarked" "a later run must replace the task's counts and marks"

  # The tenth report makes the decision due, and an eleventh is not counted.
  for i in 2 3 4 5 6 7 8 9 10 11; do
    printf '2026-11-%02dT00:00:00Z\tr%s\trun\tran\ta=1 b=0 c=0\tmodel=m\n' "$((i + 11))" "$i" >> "$home/data/fresh-read-ledger.tsv"
    printf '2026-11-%02dT00:00:01Z\tr%s\tmark\ta1\tacted\t\n' "$((i + 11))" "$i" >> "$home/data/fresh-read-ledger.tsv"
  done
  out=$("$FR" tally "$home")
  assert_contains "$out" "fresh read: 10 of the first 10 reports read" "tally must stop at the first ten reports"
  assert_contains "$out" "items: 10 flagged, 9 acted on, 0 ignored, 1 unmarked" "the eleventh report must not be counted"
  assert_contains "$out" "decision: ten reports are in" "tally must say the decision is due"
  assert_not_contains "$out" "r11	" "the eleventh report must not be listed"
  pass "fresh read: marks and tally give the acted-on share over the first ten reports"
}

fm_test_run \
  test_reader_is_fresh_and_sees_only_the_report_and_the_captains_words \
  test_list_shape_caps_each_list_at_seven_and_records_the_run \
  test_reader_failure_and_timeout_never_block \
  test_words_include_named_decisions_and_name_a_missing_one \
  test_setting_changes_model_and_switches_the_step_off_in_one_line \
  test_primary_setting_reaches_a_secondmate_home \
  test_scout_brief_carries_the_step_and_its_command_runs \
  test_drain_points_at_the_list_under_a_scout_done \
  test_marks_and_tally_give_the_measure_that_retires_the_step

#!/usr/bin/env bash
# Behavior tests for bin/fm-run-budget.sh and the --run-budget scout scaffold.
#
# The regression this guards: nightly long scouts that ran until the allowance
# was gone and left no report. Every test drives a scaffolded budgeted scout in
# an isolated home through the script's public subcommands, with a stub
# quota-axi that serves a fixture reading and FM_RUN_BUDGET_NOW as the clock,
# and asserts on the report, the ledger, and the verdicts a worker would read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE

TMP_ROOT=$(fm_test_tmproot fm-run-budget)
RB="$ROOT/bin/fm-run-budget.sh"
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ -f "$QUOTA_FIXTURE" ] || exit 1
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/quota-axi"
PATH="$FAKEBIN:$PATH"
export PATH
T0=1793700000

# reading <percent-remaining> [<runway-seconds>] [<stale>]
reading() {
  printf '{"schemaVersion":5,"providers":[{"provider":"claude","state":{"stale":%s},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":%s,"runway":{"usableRunwaySeconds":%s}}]}}]}\n' \
    "${3:-false}" "$1" "${2:-9999999}" > "$QUOTA_FIXTURE"
}

# scaffold <name> <spec>: a budgeted scout brief in its own home; prints its task folder.
scaffold() {
  local home="$TMP_ROOT/$1-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$1" some-proj --scout --run-budget "$2" >/dev/null 2>&1 \
    || fail "$1: scaffold with --run-budget $2 failed"
  printf '%s\n' "$home/data/$1"
}

at() {  # <offset-seconds> <subcommand> <args...>
  local offset=$1
  shift
  FM_RUN_BUDGET_NOW=$((T0 + offset)) "$RB" "$@"
}

test_scaffold_renders_section_and_refuses_misuse() {
  local dir brief out rc home="$TMP_ROOT/misuse-home"
  export QUOTA_FIXTURE="$TMP_ROOT/none.json"
  dir=$(scaffold render-check minutes=90,allowance=claude,spend=10)
  brief="$dir/brief.md"
  assert_grep '# Run budget' "$brief" "the budgeted scout brief must carry a Run budget section"
  assert_grep '<!-- fm-run-budget: minutes=90,allowance=claude,spend=10,reserve=5,plateau=60 -->' "$brief" \
    "the section must carry the normalized spec with its defaults"
  assert_grep "fm-run-budget.sh' start '$dir'" "$brief" "the section must give the absolute start command"
  assert_grep 'the report, the run ledger your run budget names, and the status file below' "$brief" \
    "rule 2 must let the worker write the run ledger"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" plain some-proj --scout 2>&1) || fail "plain scout scaffold failed: $out"
  assert_no_grep '# Run budget' "$home/data/plain/brief.md" "a scout without --run-budget must carry no budget section"
  for bad in "spend=10" "minutes=0" "minutes=30,colour=red" "plateau=30" "minutes=30,reserve=5"; do
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "bad-$RANDOM" some-proj --scout --run-budget "$bad" 2>&1); rc=$?
    expect_code 1 "$rc" "invalid spec '$bad'"
    assert_contains "$out" "run budget" "invalid spec '$bad' must name the run budget problem"
  done
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-budget some-proj --mode no-mistakes --run-budget minutes=30 2>&1); rc=$?
  expect_code 1 "$rc" "a ship brief must refuse --run-budget"
  assert_absent "$home/data/ship-budget/brief.md" "a refused ship scaffold must write no brief"
  pass "run budget: scaffold renders the section and refuses invalid or misplaced budgets"
}

test_budget_exhaustion_leaves_a_marked_partial_report() {
  local dir out rc
  export QUOTA_FIXTURE="$TMP_ROOT/exhaust.json"
  dir=$(scaffold exhaust minutes=120,allowance=claude,spend=20)
  reading 60
  out=$(at 0 start "$dir"); rc=$?
  expect_code 0 "$rc" "start"
  assert_contains "$out" "plan: full" "a budget that fits must plan a full pass"
  assert_present "$dir/report.md" "start must write the report's first checkpoint"
  assert_grep '<!-- fm-run-budget: run-status=in-progress -->' "$dir/report.md" "the checkpoint must be marked in progress"
  at 600 finding "$dir" "drain output was filtered three times" >/dev/null || fail "finding"
  reading 50
  out=$(at 1200 check "$dir"); rc=$?
  expect_code 0 "$rc" "check under budget"
  assert_contains "$out" "continue:" "a check under budget must continue"
  reading 42
  out=$(at 1800 check "$dir"); rc=$?
  expect_code 0 "$rc" "check near the spend line"
  assert_contains "$out" "wrap-up:" "a check past 85 percent of the spend line must ask for the final write"
  reading 39
  out=$(at 2400 check "$dir"); rc=$?
  expect_code 3 "$rc" "check over the spend line"
  assert_contains "$out" "stop: spend:" "a check over the spend line must stop on spend"
  # The worker dies here, with the allowance gone, and never writes again.
  assert_grep '<!-- fm-run-budget: run-status=stopped-spend -->' "$dir/report.md" \
    "the stop verdict itself must mark the report before the worker writes anything"
  assert_grep 'drain output was filtered three times' "$dir/report.md" \
    "the finding recorded before the stop must survive in the report"
  out=$("$RB" status "$dir")
  assert_equals "exhaust	stopped-spend" "$out" "status must report the stopped run"
  pass "run budget: a run that hits its spend line leaves a marked partial report"
}

test_time_budget_and_finish_note() {
  local dir out rc
  export QUOTA_FIXTURE="$TMP_ROOT/time.json"
  dir=$(scaffold timed minutes=30)
  out=$(at 0 start "$dir"); rc=$?
  expect_code 0 "$rc" "start without an allowance"
  at 300 finding "$dir" "first" >/dev/null
  at 900 finding "$dir" "second" >/dev/null
  out=$(at 1800 check "$dir"); rc=$?
  expect_code 3 "$rc" "check at the time budget"
  assert_contains "$out" "stop: time:" "a check at the time budget must stop on time"
  at 1900 finish "$dir" time "the Trelume sessions were not read" >/dev/null || fail "finish"
  assert_grep 'stopped at its 30-minute time budget' "$dir/report.md" "the status must name the time budget"
  assert_grep 'the Trelume sessions were not read' "$dir/report.md" "the status must carry the finish note"
  out=$(at 2000 check "$dir"); rc=$?
  expect_code 3 "$rc" "a check after the stop"
  pass "run budget: the time budget stops the run and finish records what it missed"
}

test_plateau_skips_declared_waits_and_resets_on_findings() {
  local dir out rc
  export QUOTA_FIXTURE="$TMP_ROOT/plateau.json"
  dir=$(scaffold plateau minutes=600,plateau=60)
  at 0 start "$dir" >/dev/null
  at 1800 finding "$dir" "one" >/dev/null
  at 2400 wait "$dir" "lab analysis pass" >/dev/null
  # Three hours waiting on the run's own job is not work that found nothing.
  out=$(at 13200 check "$dir"); rc=$?
  expect_code 0 "$rc" "check during a declared wait"
  at 13200 resume "$dir" >/dev/null
  out=$(at 14400 check "$dir"); rc=$?
  expect_code 0 "$rc" "check 30 working minutes after the finding"
  assert_contains "$out" "30 of 60 plateau minutes" "the plateau clock must skip the declared wait"
  at 14500 finding "$dir" "two" >/dev/null
  out=$(at 17000 check "$dir"); rc=$?
  expect_code 0 "$rc" "a new finding must restart the plateau clock"
  out=$(at 18100 check "$dir"); rc=$?
  expect_code 3 "$rc" "an hour of work with no new finding"
  assert_contains "$out" "stop: plateau:" "the plateau rule must stop the run"
  assert_grep 'run-status=stopped-plateau' "$dir/report.md" "the report must be marked stopped on the plateau"
  pass "run budget: the plateau rule ignores declared waits and stops an unproductive hour"
}

test_low_headroom_plans_a_short_pass_or_stops_at_start() {
  local dir out rc
  export QUOTA_FIXTURE="$TMP_ROOT/short.json"
  dir=$(scaffold short minutes=480,allowance=claude,spend=25)
  reading 17 3600
  out=$(at 0 start "$dir"); rc=$?
  expect_code 0 "$rc" "start with little headroom"
  assert_contains "$out" "plan: short" "headroom under the spend line must plan a short pass"
  assert_contains "$out" "spend line: 12 points" "the spend line must shrink to the headroom above the reserve"
  assert_contains "$out" "time budget: 60 minutes" "the time budget must shrink to the projected runway"
  dir=$(scaffold empty minutes=480,allowance=claude,spend=25)
  reading 4
  out=$(at 0 start "$dir"); rc=$?
  expect_code 3 "$rc" "start at the reserve"
  assert_contains "$out" "stop: reserve:" "a run that starts at the reserve must stop at once"
  assert_grep 'run-status=stopped-reserve' "$dir/report.md" "a run stopped at start must still leave a marked report"
  dir=$(scaffold unknown minutes=480,allowance=claude,spend=25)
  reading 90 9999999 true
  out=$(at 0 start "$dir"); rc=$?
  expect_code 0 "$rc" "start with a stale reading"
  assert_contains "$out" "headroom unknown (the reading is stale)" "a stale reading must be disclosed, not trusted"
  out=$(at 600 check "$dir"); rc=$?
  expect_code 0 "$rc" "check with a stale reading"
  assert_contains "$out" "claude allowance unknown" "a check must disclose an unreadable allowance and carry on"
  pass "run budget: low headroom plans a short pass, no headroom stops at once, unknown headroom is disclosed"
}

test_relaunch_keeps_the_clock_and_salvage_marks_a_dead_run() {
  local dir out rc
  export QUOTA_FIXTURE="$TMP_ROOT/salvage.json"
  dir=$(scaffold salvage minutes=120)
  at 0 start "$dir" >/dev/null
  at 600 finding "$dir" "kept across the relaunch" >/dev/null
  out=$(at 3000 start "$dir"); rc=$?
  expect_code 0 "$rc" "start after a relaunch"
  assert_contains "$out" "restart:" "a second start must be a restart"
  out=$(at 7300 check "$dir"); rc=$?
  expect_code 3 "$rc" "the time budget must count from the first start"
  dir=$(scaffold dead minutes=600)
  at 0 start "$dir" >/dev/null
  at 900 finding "$dir" "found before the allowance ran out" >/dev/null
  # The worker overwrites the report body and then dies without finishing.
  printf '# My report\n\nHalf written.\n' > "$dir/report.md"
  out=$(at 9000 salvage "$dir" "the worker died"); rc=$?
  expect_code 0 "$rc" "salvage"
  assert_grep 'run-status=ended-unfinished' "$dir/report.md" "salvage must mark the report ended without finishing"
  assert_grep 'Half written.' "$dir/report.md" "salvage must keep the worker's report body"
  rm -f "$dir/report.md"
  out=$(at 9100 salvage "$dir"); rc=$?
  expect_code 0 "$rc" "salvage with no report"
  assert_grep 'found before the allowance ran out' "$dir/report.md" "salvage must rebuild the run log from the ledger"
  out=$(at 9200 salvage "$dir")
  assert_contains "$out" "left alone" "salvage must be idempotent"
  mkdir -p "$TMP_ROOT/never/data/never-ran"
  out=$("$RB" salvage "$TMP_ROOT/never/data/never-ran" "not launched: project capacity full")
  assert_grep 'run-status=not-started' "$TMP_ROOT/never/data/never-ran/report.md" \
    "a run that never started must still get a report saying so"
  assert_grep 'project capacity full' "$TMP_ROOT/never/data/never-ran/report.md" "the not-started report must say why"
  dir=$(scaffold late minutes=60)
  "$RB" salvage "$dir" "not launched: project capacity full" >/dev/null
  at 0 start "$dir" >/dev/null || fail "start after a not-started salvage"
  assert_grep 'run-status=in-progress' "$dir/report.md" "a run dispatched after a not-started record must be in progress"
  assert_equals 1 "$(grep -c 'fm-run-budget: run-status=' "$dir/report.md")" "the report must carry exactly one status line"
  pass "run budget: a relaunch keeps the clock and salvage marks a dead or never-started run"
}

fm_test_run \
  test_scaffold_renders_section_and_refuses_misuse \
  test_budget_exhaustion_leaves_a_marked_partial_report \
  test_time_budget_and_finish_note \
  test_plateau_skips_declared_waits_and_resets_on_findings \
  test_low_headroom_plans_a_short_pass_or_stops_at_start \
  test_relaunch_keeps_the_clock_and_salvage_marks_a_dead_run

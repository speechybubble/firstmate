#!/usr/bin/env bash
# Behavior tests for bin/fm-check-results.sh: the two daily check-result lines
# the nightly Backpass reports, computed from the home's skill-fire log and its
# backlog's Done rows (live and archived).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required to read the backlog's Done rows)"; exit 0; }

RESULTS="$ROOT/bin/fm-check-results.sh"
TMP_ROOT=$(fm_test_tmproot fm-check-results)
PREFIX='intake checks refuse this done:'

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

# Append one skill-fire line in the log's own column order.
fire() {  # <home> <ts> <task> <rule> <source> <ref>
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" >> "$1/data/skill-fires.tsv"
}

results() {  # <home> [args...]
  local home=$1
  shift
  TZ=UTC FM_HOME="$home" bash "$RESULTS" "$@" 2>&1
}

line_of() {  # <output> <prefix>
  printf '%s\n' "$1" | grep "^$2 "
}

# A home with no checked task and no Done rows prints both lines with zero
# counts and n/a shares, and exits 0: a quiet night is not an error.
test_quiet_night_prints_zero_counts() {
  local home out rc=0
  home=$(new_home quiet)
  out=$(results "$home" --since 2026-11-07T12:00:00Z --until 2026-11-08T12:00:00Z) || rc=$?
  expect_code 0 "$rc" "a home with no skill-fire log"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] || fail "a quiet night did not print exactly two lines: $out"
  assert_contains "$(line_of "$out" 'check refusals')" "0 done claims refused on 0 tasks, 0 confirmed by a later pass on changed work (n/a), 0 later passed on unchanged work, 0 still open" "the quiet refusal line is wrong"
  assert_contains "$(line_of "$out" 'check refusals')" "by check: none; deliverables shipped: 0" "the quiet refusal line did not name zero checks and shipped"
  assert_contains "$(line_of "$out" 'check intake')" "0 checks written, 0 failed validation (n/a); 0 of 0 launched tasks exempt (n/a); deliverables shipped: 0" "the quiet intake line is wrong"

  # A log holding only other rules' fires is also a quiet night for checks.
  fire "$home" 2026-11-08T01:00:00Z pg page fm-brief.sh /x/brief.md
  out=$(results "$home" --since 2026-11-07T12:00:00Z --until 2026-11-08T12:00:00Z) || rc=$?
  expect_code 0 "$rc" "a log with no checks fires"
  assert_contains "$out" "0 done claims refused on 0 tasks" "a page fire was counted as a checks refusal"
  pass "quiet night: no checked task prints zero counts and n/a shares, not an error"
}

# The regression case: a night with refused dones shows them, attributed to
# the checks that refused, with a later passing run confirming a refusal only
# when it follows that refusal in the log.
test_refused_done_night_shows_in_the_lines() {
  local home out refusals
  home=$(new_home refused)
  fire "$home" 2026-11-07T10:00:00Z t1 checks-admitted fm-spawn.sh guarantee-conditional
  fire "$home" 2026-11-07T10:00:00Z t1 checks-admitted fm-spawn.sh no-dash
  fire "$home" 2026-11-07T10:05:00Z t2 checks-admitted fm-spawn.sh quote-real
  fire "$home" 2026-11-07T10:06:00Z t3 checks-admitted fm-spawn.sh anything
  fire "$home" 2026-11-07T10:07:00Z t4 checks-admitted fm-spawn.sh price-named
  fire "$home" 2026-11-07T10:08:00Z t6 checks-admitted fm-spawn.sh drive-ok
  # t4 was refused before the window and passed on changed work inside it.
  fire "$home" 2026-11-07T11:00:00Z t4 checks-refused fm-crew-state.sh "head=a4; $PREFIX price-named: no line matches US\\$"
  # t1 was refused on one check, then passed on changed work.
  fire "$home" 2026-11-07T13:00:00Z t1 checks-refused fm-crew-state.sh "head=a1; $PREFIX guarantee-conditional: a line matches no questions asked"
  fire "$home" 2026-11-07T14:00:00Z t1 checks-passed fm-crew-state.sh "head=b1; PR https://example.test/o/r/pull/1"
  # t2 passed an earlier done and was refused later: that pass settles nothing.
  fire "$home" 2026-11-07T14:30:00Z t2 checks-passed fm-crew-state.sh "head=a2; implementation ready"
  fire "$home" 2026-11-07T15:00:00Z t2 checks-refused fm-crew-state.sh "head=b2; $PREFIX quote-real: command exited 1; no-such-id: text"
  # t5 was refused on a check no launch recorded admitting.
  fire "$home" 2026-11-07T15:30:00Z t5 checks-refused fm-crew-state.sh "head=a5; $PREFIX ghost: a line matches"
  # t3's checks record was altered, so the refusal names no admitted check.
  fire "$home" 2026-11-07T16:00:00Z t3 checks-refused fm-crew-state.sh "head=a3; $PREFIX the admitted checks record /s/t3.checks.json has digest x, not the checks_sha=y spawn admitted; the checks were changed after launch"
  fire "$home" 2026-11-07T17:00:00Z t4 checks-passed fm-crew-state.sh "head=b4; report ready"
  # t6 was refused, then the same work passed (a transient failure or a fixed
  # evidence path): disclosed as unchanged, never a confirmation.
  fire "$home" 2026-11-07T18:00:00Z t6 checks-refused fm-crew-state.sh "head=a6; $PREFIX drive-ok: assertion apply failing"
  fire "$home" 2026-11-07T18:30:00Z t6 checks-passed fm-crew-state.sh "head=a6; PR https://example.test/o/r/pull/6 drive=/x/results.tsv"
  # A pass after the window ends never settles a refusal in it.
  fire "$home" 2026-11-08T13:00:00Z t2 checks-passed fm-crew-state.sh "head=c2; PR https://example.test/o/r/pull/2"

  out=$(results "$home" --since 2026-11-07T12:00:00Z --until 2026-11-08T12:00:00Z --json "$home/out.json") \
    || fail "the refused night did not exit 0: $out"
  refusals=$(line_of "$out" 'check refusals')
  assert_contains "$refusals" "5 done claims refused on 5 tasks, 1 confirmed by a later pass on changed work (20%), 1 later passed on unchanged work, 3 still open" "the refused night's counts are wrong"
  assert_contains "$refusals" "earlier refusals confirmed in this window: 1" "a refusal before the window confirmed inside it was not counted"
  assert_contains "$refusals" "tasks whose checks passed: 4" "the tasks whose checks passed are wrong"
  assert_contains "$refusals" "captain send-backs after checks passed: not recorded" "the unrecorded send-backs were not stated as such"
  assert_contains "$refusals" "by check: t1/guarantee-conditional 1 refused 1 confirmed 0 unchanged, t2/quote-real 1 refused 0 confirmed 0 unchanged, t3/record 1 refused 0 confirmed 0 unchanged, t5/unattributed 1 refused 0 confirmed 0 unchanged, t6/drive-ok 1 refused 0 confirmed 1 unchanged" "the refusals were not attributed to their checks"
  case "$refusals" in
    *no-dash*|*no-such-id*) fail "a check that did not refuse, or an id that was never admitted, was attributed: $refusals" ;;
  esac
  [ "$(jq -r '.refusals.refused, .refusals.confirmed, .refusals.unchanged, .refusals.open, .refusals.captain_send_backs' "$home/out.json" | paste -s -d' ' -)" = "5 1 1 3 null" ] \
    || fail "the --json figures disagree with the lines: $(cat "$home/out.json")"
  jq -e '.lines == null and .schema == "fm-check-results.v1"' "$home/out.json" >/dev/null \
    || fail "the --json file is not the v1 figures object: $(cat "$home/out.json")"
  pass "refused night: refused dones show in the lines, attributed by check, confirmed only by a later pass on changed work in the window"
}

# A refusal or pass with no recorded head can never prove the work changed, so
# its first later pass is disclosed as unchanged rather than confirmed.
test_a_missing_head_never_confirms() {
  local home out
  home=$(new_home headless)
  fire "$home" 2026-11-07T10:00:00Z h1 checks-admitted fm-spawn.sh only
  fire "$home" 2026-11-07T13:00:00Z h1 checks-refused fm-crew-state.sh "$PREFIX only: a line matches"
  fire "$home" 2026-11-07T14:00:00Z h1 checks-passed fm-crew-state.sh "head=b; PR https://example.test/o/r/pull/3"
  out=$(results "$home" --since 2026-11-07T12:00:00Z --until 2026-11-08T12:00:00Z) \
    || fail "the headless night did not exit 0: $out"
  assert_contains "$out" "1 done claims refused on 1 tasks, 0 confirmed by a later pass on changed work (0%), 1 later passed on unchanged work, 0 still open" \
    "a refusal with no recorded head was confirmed"
  assert_contains "$out" "by check: h1/only 1 refused 0 confirmed 1 unchanged" "the headless refusal was not attributed to its check"
  pass "missing head: a refusal whose head was not recorded is never counted as confirmed"
}

# The intake line counts each written check once, counts one that failed
# validation even after a corrected relaunch admitted it, counts a malformed
# slot as one failed check, and counts a task exempt only when its latest
# launch in the window took the exemption.
test_intake_line_counts_written_invalid_and_exempt() {
  local home out intake
  home=$(new_home intake)
  fire "$home" 2026-11-07T13:00:00Z a checks-invalid fm-spawn.sh "guarantee: passes its bad example"
  fire "$home" 2026-11-07T13:00:00Z a checks-admitted fm-spawn.sh price
  fire "$home" 2026-11-07T13:10:00Z a checks-admitted fm-spawn.sh guarantee
  fire "$home" 2026-11-07T13:10:00Z a checks-admitted fm-spawn.sh price
  fire "$home" 2026-11-07T14:00:00Z b checks-invalid fm-spawn.sh "## Checks holds no fenced json block"
  fire "$home" 2026-11-07T15:00:00Z c checks-exempt fm-spawn.sh "a fleet code change"
  fire "$home" 2026-11-07T16:00:00Z d checks-exempt fm-spawn.sh "first launch"
  fire "$home" 2026-11-07T16:30:00Z d checks-admitted fm-spawn.sh real-check
  # Launches outside the window are not counted.
  fire "$home" 2026-11-07T11:00:00Z e checks-invalid fm-spawn.sh "old: before the window"
  fire "$home" 2026-11-08T12:00:00Z f checks-exempt fm-spawn.sh "at the window's end"
  out=$(results "$home" --since 2026-11-07T12:00:00Z --until 2026-11-08T12:00:00Z) \
    || fail "the intake night did not exit 0: $out"
  intake=$(line_of "$out" 'check intake')
  assert_contains "$intake" "4 checks written, 2 failed validation (50%); 1 of 4 launched tasks exempt (25%)" "the intake counts are wrong"
  pass "intake: written checks counted once, failed validation counted even after a fix, exemption read from the latest launch"
}

# Deliverables shipped counts Done ship and scout rows, live and archived,
# whose local closed day begins inside the window, and nothing else.
test_shipped_counts_done_ship_and_scout_rows_per_local_day() {
  local home out
  home=$(new_home shipped)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  {
    printf -- '- [x] ship-in - A ship (repo: fleet) (kind: ship) (merged 2026-11-08)\n'
    printf -- '- [x] call-in - A captain call (repo: fleet) (kind: captain) (done 2026-11-08)\n'
    printf -- '- [x] ship-before - An earlier ship (repo: fleet) (kind: ship) (merged 2026-11-07)\n'
    printf -- '- [x] ship-after - A later ship (repo: fleet) (kind: ship) (merged 2026-11-09)\n'
  } >> "$home/data/backlog.md"
  printf '\n## Archived 2026-11-08\n- [x] scout-in - A scout, report data/scout-in/report.md (repo: fleet) (kind: scout) (reported 2026-11-08)\n- [x] task-in - A task (repo: fleet) (kind: task) (done 2026-11-08)\n' > "$home/data/done-archive.md"
  out=$(results "$home" --since 2026-11-08T06:00:00Z --until 2026-11-09T06:00:00Z) \
    || fail "the shipped night did not exit 0: $out"
  assert_contains "$(line_of "$out" 'check refusals')" "deliverables shipped: 1" "a window starting mid-day did not count only the day that began inside it"
  out=$(results "$home" --since 2026-11-08 --until 2026-11-09) \
    || fail "the date window did not exit 0: $out"
  assert_contains "$(line_of "$out" 'check intake')" "deliverables shipped: 2" "the archived scout or the live ship was not counted, or a captain or task row was"
  # tasks-axi records closed as a local day: in UTC+10 a window from 22:00
  # local to 22:00 local the next day holds exactly that next day.
  out=$(TZ=AEST-10 FM_HOME="$home" bash "$RESULTS" --since 2026-11-07T12:00:00Z --until 2026-11-08T12:00:00Z 2>&1) \
    || fail "the local-day window did not exit 0: $out"
  assert_contains "$(line_of "$out" 'check intake')" "deliverables shipped: 2" "a nightly window in a non-UTC zone did not count its local day once"
  pass "shipped: Done ship and scout rows, live and archived, counted once per local day inside the window"
}

test_usage_errors() {
  local home out rc
  home=$(new_home usage)
  rc=0; out=$(results "$home") || rc=$?
  expect_code 2 "$rc" "no --since"
  assert_contains "$out" "--since is required" "the missing --since was not named"
  rc=0; out=$(results "$home" --since yesterday) || rc=$?
  expect_code 2 "$rc" "an unparsable --since"
  rc=0; out=$(results "$home" --since 2026-11-08 --until 2026-11-07) || rc=$?
  expect_code 2 "$rc" "an until before since"
  mkdir -p "$home/data/skill-fires.tsv"
  rc=0; out=$(results "$home" --since 2026-11-07) || rc=$?
  expect_code 1 "$rc" "a skill-fire log that is a directory"
  assert_contains "$out" "is not a readable file" "the unreadable log was not named"
  pass "usage: a missing or unparsable window exits 2, an unreadable log exits 1"
}

fm_test_run \
  test_quiet_night_prints_zero_counts \
  test_refused_done_night_shows_in_the_lines \
  test_a_missing_head_never_confirms \
  test_intake_line_counts_written_invalid_and_exempt \
  test_shipped_counts_done_ship_and_scout_rows_per_local_day \
  test_usage_errors

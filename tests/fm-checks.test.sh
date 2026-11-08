#!/usr/bin/env bash
# Behavior tests for bin/fm-checks.sh: the intake check format a brief's
# `## Checks` slot carries, the validator that admits a check only when its
# known-good example passes and its known-bad example fails, the runner the
# done gate uses on a deliverable, and the drive assertion-results format.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKS="$ROOT/bin/fm-checks.sh"
TMP_ROOT=$(fm_test_tmproot fm-checks)
fm_git_identity fmtest fmtest@example.invalid

# Write a brief whose `## Checks` slot body is <body>.
write_checks_brief() {  # <file> <body>
  mkdir -p "$(dirname "$1")"
  {
    printf '# Task\n<!-- fm-brief: task-slots v4 -->\n## Captain'\''s intent\nMake the ad.\n\n## Firstmate spec\nBuild it.\n\n## Checks\n'
    printf '%s\n' "$2"
    printf '\n# Definition of done\nDone.\n'
  } > "$1"
}

# A `## Checks` body holding one fenced json block with <json>.
json_block() {  # <json>
  # shellcheck disable=SC2016 # literal markdown code fences, not expansions.
  printf '```json\n%s\n```' "$1"
}

validate() {  # <brief> <kind> [args...]
  local brief=$1 kind=$2
  shift 2
  "$CHECKS" validate "$brief" --kind "$kind" "$@" 2>&1
}

# A check of every type admitted when its good example passes and its bad one
# fails, with the record normalized and written only on success.
test_validate_admits_every_type_on_its_own_examples() {
  local brief="$TMP_ROOT/admit/brief.md" record="$TMP_ROOT/admit/record.json" out rc
  # shellcheck disable=SC2016 # the command check's own shell expands FM_CHECK_TARGET.
  write_checks_brief "$brief" "$(json_block '[
 {"id":"guarantee-conditional","source":"higher price guarantees should always be conditional","type":"not-contains","target":"ad.txt","pattern":"(any reason|no questions asked)","good":"If you run them 30 days and none wins, next month is free.","bad":"Full refund for any reason, no questions asked."},
 {"id":"names-the-person","source":"a specific problem for a specific person","type":"contains","target":"ad.txt","pattern":"(HVAC|plumb|remodel)","good":"For plumbers who lose jobs to slow quotes.","bad":"For every business in every industry."},
 {"id":"short-ad","source":"one screen","type":"command","target":"ad.txt","run":"test \"$(wc -l < \"$FM_CHECK_TARGET\")\" -le 2","good":"one\n","bad":"one\ntwo\nthree\n"},
 {"id":"status-ok","source":"the run reports ok","type":"json-field","target":"r.json","path":".result.status","equals":"ok","good":"{\"result\":{\"status\":\"ok\"}}","bad":"{\"result\":{\"status\":\"error\"}}"},
 {"id":"row-passes","source":"the ledger row passes","type":"tsv-field","target":"r.tsv","key":"S4","field":3,"equals":"pass","good":"S1\tx\tfail\nS4\ty\tpass\n","bad":"S4\ty\tfail\n"},
 {"id":"apply-works","source":"click Apply and the console shows no error","type":"assertions","assertions":["apply-no-console-error"],"good":"apply-no-console-error\tpass\n","bad":"apply-no-console-error\tfail\tTypeError\n"}
]')"
  out=$(validate "$brief" ship --admit "$record"); rc=$?
  expect_code 0 "$rc" "six sound checks were not all admitted: $out"
  assert_contains "$out" "checks: 6 admitted, 0 invalid" "the summary did not count six admitted checks"
  assert_contains "$out" "admitted apply-works" "the assertions check was not admitted"
  [ "$(jq -r '.version, .kind, (.checks | length), (.checks[] | select(.id == "row-passes") | .key_field)' "$record" | paste -s -d ' ' -)" = "1 ship 6 1" ] \
    || fail "the admitted record is not the normalized ship record: $(cat "$record")"
  [ "$(jq 'has("root")' "$record")" = false ] || fail "a ship record carries a root"

  brief="$TMP_ROOT/admit/scout.md"
  write_checks_brief "$brief" "$(json_block '[{"id":"cites-evidence","source":"every claim names evidence","type":"contains","pattern":"file:[0-9]+","good":"see bin/x.sh file:12","bad":"trust me"}]')"
  out=$(validate "$brief" scout --root "$TMP_ROOT/data/s1" --admit "$record"); rc=$?
  expect_code 0 "$rc" "a scout check with the default target was not admitted: $out"
  [ "$(jq -r '.kind, .root, .checks[0].target' "$record" | paste -s -d ' ' -)" = "scout $TMP_ROOT/data/s1 report.md" ] \
    || fail "a scout record did not default its target to report.md under its root: $(cat "$record")"
  pass "validate: every type is admitted on its own good and bad examples, and the admitted record is normalized"
}

# A check that cannot tell bad work from good is refused before it ever judges
# real work: one that fails its good example, passes its bad example, ignores
# its target, or cannot run at all.
test_validate_refuses_checks_that_cannot_tell_good_from_bad() {
  local brief="$TMP_ROOT/refuse/brief.md" record="$TMP_ROOT/refuse/record.json" good_file="$TMP_ROOT/refuse/past-good.txt" out rc
  mkdir -p "$TMP_ROOT/refuse"
  printf 'Book a call with us\n' > "$good_file"
  printf '{}\n' > "$record"
  write_checks_brief "$brief" "$(json_block '[
 {"id":"has-cta","source":"the ad has a call to action","type":"contains","target":"ad.txt","pattern":"(Book|Call|Get)","good":"Book a call","bad":"Get a full refund for any reason"},
 {"id":"too-narrow","source":"the mechanism is explained","type":"contains","target":"ad.txt","pattern":"because our system","good":"It works since every ad starts from a real review.","bad":"We make ads."},
 {"id":"ignores-target","source":"x","type":"command","target":"ad.txt","run":"true","good":"a","bad":"b"},
 {"id":"broken-regex","source":"x","type":"contains","target":"ad.txt","pattern":"(","good":"a","bad":"b"},
 {"id":"broken-jq","source":"x","type":"json-field","target":"r.json","path":".a | |","equals":"x","good":"{}","bad":"{}"},
 {"id":"from-real-work","source":"x","type":"contains","target":"ad.txt","pattern":"Book","good_file":"'"$good_file"'","bad":"Nothing here"},
 {"id":"missing-file","source":"x","type":"contains","target":"ad.txt","pattern":"a","good_file":"'"$TMP_ROOT"'/refuse/nope.txt","bad":"b"}
]')"
  out=$(validate "$brief" ship --admit "$record"); rc=$?
  expect_code 1 "$rc" "invalid checks were accepted"
  assert_contains "$out" "invalid has-cta: passes its bad example" "a generic check that passes its bad example was admitted"
  assert_contains "$out" "invalid too-narrow: fails its good example" "a check that fails its good example was admitted"
  assert_contains "$out" "invalid ignores-target: passes its bad example" "a command that never reads its target was admitted"
  assert_contains "$out" "invalid broken-regex: pattern /(/ is not a valid extended regular expression" "an unrunnable regex was not named"
  assert_contains "$out" "invalid broken-jq: path .a | | is not a valid jq filter" "an unrunnable jq filter was not named"
  assert_contains "$out" "admitted from-real-work" "a check validated against a real past file was refused"
  assert_contains "$out" "invalid missing-file: good_file $TMP_ROOT/refuse/nope.txt is not a readable regular file" "an unreadable example file was not named"
  assert_contains "$out" "checks: 1 admitted, 6 invalid" "the summary did not count checks"
  [ "$(cat "$record")" = '{}' ] || fail "a refused validation replaced the admitted record"
  pass "validate: refuses a check that passes its bad example, fails its good one, ignores its target, or cannot run"
}

test_validate_refuses_schema_breaks() {
  local brief="$TMP_ROOT/schema/brief.md" out rc
  write_checks_brief "$brief" "$(json_block '[
 {"id":"Bad Id","source":"x","type":"contains","target":"a","pattern":"a","good":"a","bad":"b"},
 {"id":"no-source","type":"contains","target":"a","pattern":"a","good":"a","bad":"b"},
 {"id":"typo","source":"x","type":"contains","target":"a","patern":"a","good":"a","bad":"b"},
 {"id":"absolute","source":"x","type":"contains","target":"/etc/hostname","pattern":"a","good":"a","bad":"b"},
 {"id":"escapes","source":"x","type":"contains","target":"../x","pattern":"a","good":"a","bad":"b"},
 {"id":"no-target","source":"x","type":"contains","pattern":"a","good":"a","bad":"b"},
 {"id":"both-goods","source":"x","type":"contains","target":"a","pattern":"a","good":"a","good_file":"/x","bad":"b"},
 {"id":"no-bad","source":"x","type":"contains","target":"a","pattern":"a","good":"a"},
 {"id":"judged","source":"x","type":"judge","target":"a","good":"a","bad":"b"},
 {"id":"drive-target","source":"x","type":"assertions","target":"a","assertions":["x"],"good":"x\tpass\n","bad":"x\tfail\n"},
 {"id":"twice","source":"x","type":"contains","target":"a","pattern":"a","good":"a","bad":"b"},
 {"id":"twice","source":"x","type":"contains","target":"a","pattern":"a","good":"a","bad":"b"}
]')"
  out=$(validate "$brief" ship); rc=$?
  expect_code 1 "$rc" "schema breaks were accepted"
  assert_contains "$out" "invalid Bad Id: id must be lowercase letters, digits, and dashes" "a bad id was accepted"
  assert_contains "$out" "invalid no-source: source must name" "a check without a source was accepted"
  assert_contains "$out" "invalid typo: unknown field patern" "a misspelled field was ignored"
  assert_contains "$out" "invalid absolute: target must be a relative path" "an absolute target was accepted"
  assert_contains "$out" "invalid escapes: target must be a relative path" "a target escaping the deliverable was accepted"
  assert_contains "$out" "invalid no-target: a ship check needs a target" "a ship check without a target was accepted"
  assert_contains "$out" "invalid both-goods: give good or good_file, not both" "two good examples were accepted"
  assert_contains "$out" "invalid no-bad: needs a known-bad example" "a check without a bad example was accepted"
  assert_contains "$out" "invalid judged: type must be one of" "a type outside the closed set was accepted"
  assert_contains "$out" "invalid drive-target: an assertions check reads the drive results" "an assertions check with a target was accepted"
  assert_contains "$out" "invalid twice: id twice is used by more than one check" "a duplicate id was accepted"
  assert_contains "$out" "checks: 0 admitted, 12 invalid" "a check with several problems was counted more than once"
  [ "$(printf '%s\n' "$out" | grep -c '^invalid ')" = 12 ] \
    || fail "a check with several problems printed more than one invalid line: $out"
  assert_contains "$out" "invalid typo: unknown field patern; type contains needs pattern" "a check's several problems were not joined on its one line"
  pass "validate: refuses schema breaks, unknown fields, unsafe targets, missing examples, and duplicate ids"
}

# The slot is exactly one json block or exactly one reasoned exemption line.
test_validate_reads_the_slot_forms() {
  local dir="$TMP_ROOT/slot" record out rc label body expect code
  record="$dir/record.json"
  mkdir -p "$dir"
  printf '{}\n' > "$record"
  write_checks_brief "$dir/exempt.md" 'routine: no checks - verbatim copy edit with nothing a script can judge'
  out=$(validate "$dir/exempt.md" ship --admit "$record"); rc=$?
  expect_code 0 "$rc" "a reasoned exemption was refused"
  [ "$out" = "exempt: verbatim copy edit with nothing a script can judge" ] || fail "the exemption verdict is wrong: $out"
  assert_absent "$record" "an exemption left the stale admitted record in place"
  while IFS='|' read -r label body expect; do
    [ -n "$label" ] || continue
    write_checks_brief "$dir/$label.md" "$(printf '%b' "$body")"
    out=$(validate "$dir/$label.md" ship); code=$?
    expect_code 1 "$code" "$label: a malformed slot was accepted"
    assert_contains "$out" "$expect" "$label: the refusal did not explain itself"
  done <<'EOF'
no-reason|routine: no checks - |exactly one line `routine: no checks - <reason>`
mixed|routine: no checks - fine\nAlso some prose.|exactly one line `routine: no checks - <reason>`
prose|These checks matter.\n```json\n[]\n```|holds text outside one fenced json block
after|```json\n[{"id":"a"}]\n```\ntrailing words|holds text after its fenced json block
unclosed|```json\n[|has an unclosed fenced json block
empty-array|```json\n[]\n```|is not a non-empty JSON array
object|```json\n{"id":"a"}\n```|is not a non-empty JSON array
EOF
  printf '# Task\n## Captain'\''s intent\nx\n' > "$dir/none.md"
  out=$(validate "$dir/none.md" ship); rc=$?
  expect_code 1 "$rc" "a brief without the slot validated"
  assert_contains "$out" "has no ## Checks subsection" "the missing slot was not named"
  pass "validate: one json block or one reasoned exemption; an exemption removes a stale record"
}

# A ship's checks read its committed HEAD, so an uncommitted fix never passes.
test_run_reads_the_committed_ship_tree() {
  local dir="$TMP_ROOT/run" repo brief record out rc
  repo="$dir/repo"
  brief="$dir/brief.md"
  record="$dir/record.json"
  git init -q "$repo"
  printf 'Full refund, no questions asked.\n' > "$repo/ad.txt"
  git -C "$repo" add ad.txt
  git -C "$repo" commit -q -m ad
  write_checks_brief "$brief" "$(json_block '[
 {"id":"guarantee-conditional","source":"higher price guarantees should always be conditional","type":"not-contains","target":"ad.txt","pattern":"no questions asked","good":"If you run it 30 days, next month is free.","bad":"Refund, no questions asked."},
 {"id":"has-page","source":"the page ships","type":"contains","target":"site/index.html","pattern":"<h1>","good":"<h1>Hi</h1>","bad":"<p>Hi</p>"}
]')"
  validate "$brief" ship --admit "$record" >/dev/null || fail "the run fixture checks were not admitted"
  out=$("$CHECKS" run "$record" --head "$repo" 2>&1); rc=$?
  expect_code 1 "$rc" "failing ship work passed its checks"
  assert_contains "$out" "fail guarantee-conditional: a line matches /no questions asked/: Full refund, no questions asked." "the failing line was not quoted"
  assert_contains "$out" "fail has-page: target site/index.html is not in the committed tree at HEAD" "a missing target did not fail its check"
  printf 'If you run it 30 days and none wins, next month is free.\n' > "$repo/ad.txt"
  mkdir -p "$repo/site"
  printf '<h1>Hi</h1>\n' > "$repo/site/index.html"
  out=$("$CHECKS" run "$record" --head "$repo" 2>&1); rc=$?
  expect_code 1 "$rc" "an uncommitted fix passed the committed-tree checks"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m fix
  out=$("$CHECKS" run "$record" --head "$repo" 2>&1); rc=$?
  expect_code 0 "$rc" "committed passing work failed its checks: $out"
  assert_contains "$out" "checks: 2 passed, 0 failed" "the passing summary is wrong"
  out=$("$CHECKS" run "$dir/no-record.json" --head "$repo" 2>&1); rc=$?
  expect_code 2 "$rc" "a missing admitted record did not stop the run"
  pass "run: a ship's checks read the committed HEAD, a missing target fails, and an uncommitted fix does not pass"
}

# A scout's checks read its data directory; a symlinked target is not observed.
test_run_reads_a_scout_directory_and_drive_results() {
  local dir="$TMP_ROOT/scout" data brief record out rc
  data="$dir/data/s1"
  brief="$dir/brief.md"
  record="$dir/record.json"
  mkdir -p "$data"
  write_checks_brief "$brief" "$(json_block '[
 {"id":"quote-verbatim","source":"the captain never said long, then short","type":"not-contains","pattern":"long, then short, then back to long","good":"I probably have a long sentence, then a short one.","bad":"Your transcript said long, then short, then back to long"},
 {"id":"pick-form","source":"the pick form queues an answer","type":"assertions","assertions":["pick-form-queues"],"good":"pick-form-queues\tpass\n","bad":"pick-form-queues\tfail\n"}
]')"
  validate "$brief" scout --root "$data" --admit "$record" >/dev/null || fail "the scout checks were not admitted"
  out=$("$CHECKS" run "$record" --dir "$data" 2>&1); rc=$?
  expect_code 1 "$rc" "a scout without its report passed"
  assert_contains "$out" "fail quote-verbatim: target report.md is missing from $data" "a missing report did not fail"
  assert_contains "$out" "fail pick-form: the done line names no drive= results" "an assertions check passed without drive results"
  printf 'Your transcript said long, then short, then back to long.\n' > "$dir/elsewhere.md"
  ln -s "$dir/elsewhere.md" "$data/report.md"
  out=$("$CHECKS" run "$record" --dir "$data" 2>&1); rc=$?
  assert_contains "$out" "fail quote-verbatim: target report.md is missing" "a symlinked report was read"
  rm -f "$data/report.md"
  printf 'Their words: I probably have a long sentence, then a short one.\n' > "$data/report.md"
  printf 'pick-form-queues\tfail\tno answer queued\n' > "$dir/drive.tsv"
  out=$("$CHECKS" run "$record" --dir "$data" --drive "$dir/drive.tsv" 2>&1); rc=$?
  expect_code 1 "$rc" "a failed drive assertion passed"
  assert_contains "$out" "fail pick-form: the drive results show assertion pick-form-queues failing" "the failing assertion was not named"
  printf 'pick-form-queues\tpass\n' > "$dir/drive.tsv"
  out=$("$CHECKS" run "$record" --dir "$data" --drive "$dir/drive.tsv" 2>&1); rc=$?
  expect_code 0 "$rc" "a passing scout failed its checks: $out"
  pass "run: a scout's checks read its data directory, refuse a symlinked target, and assertions read the drive results"
}

# The cache reruns checks only when the record, a target, or the drive path changes.
test_run_cache_reruns_only_on_change() {
  local dir="$TMP_ROOT/cache" data brief record cache counter out rc
  data="$dir/data"
  brief="$dir/brief.md"
  record="$dir/record.json"
  cache="$dir/result"
  counter="$dir/runs"
  mkdir -p "$data"
  # shellcheck disable=SC2016 # the check's own shell expands FM_CHECK_TARGET.
  write_checks_brief "$brief" "$(json_block '[{"id":"counted","source":"x","type":"command","target":"report.md","run":"echo run >> '"$counter"'; grep -q ok \"$FM_CHECK_TARGET\"","good":"ok","bad":"no"}]')"
  validate "$brief" scout --root "$data" --admit "$record" >/dev/null || fail "the counted check was not admitted"
  : > "$counter"
  printf 'ok\n' > "$data/report.md"
  "$CHECKS" run "$record" --dir "$data" --cache "$cache" >/dev/null || fail "the counted check failed"
  out=$("$CHECKS" run "$record" --dir "$data" --cache "$cache" 2>&1) || fail "the cached result changed its verdict"
  assert_contains "$out" "pass counted" "the cached result lost its lines"
  [ "$(wc -l < "$counter" | tr -d ' ')" = 1 ] || fail "an unchanged deliverable reran its command"
  printf 'no\n' > "$data/report.md"
  out=$("$CHECKS" run "$record" --dir "$data" --cache "$cache" 2>&1); rc=$?
  expect_code 1 "$rc" "a changed target reused the passing cache"
  [ "$(wc -l < "$counter" | tr -d ' ')" = 2 ] || fail "a changed target did not rerun its command"
  pass "run --cache: an unchanged deliverable reuses its result, and a changed target reruns"
}

test_drive_results_reads_only_assertion_results() {
  local dir="$TMP_ROOT/drive" out rc label body expect
  mkdir -p "$dir/a-dir"
  printf '# drive of the page\npick-form-queues\tpass\tqueued\n\napply\tpass\n' > "$dir/ok.tsv"
  "$CHECKS" drive-results "$dir/ok.tsv" || fail "passing drive results were refused"
  out=$("$CHECKS" drive-results "$dir/a-dir" 2>&1); rc=$?
  expect_code 1 "$rc" "a directory passed as drive results"
  assert_contains "$out" "is not a regular file of drive assertion results" "the directory refusal is wrong"
  out=$("$CHECKS" drive-results ok.tsv 2>&1); rc=$?
  expect_code 1 "$rc" "a relative path passed as drive results"
  while IFS='|' read -r label body expect; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$dir/$label"
    out=$("$CHECKS" drive-results "$dir/$label" 2>&1); rc=$?
    expect_code 1 "$rc" "$label: passed as drive results"
    assert_contains "$out" "$expect" "$label: the refusal did not explain itself"
  done <<'EOF'
hostname|some-host\n|line 1 is not an <assertion><TAB><pass|fail> result
recipe|# Drive the page\nopen http://localhost:3000\n|line 2 is not an <assertion><TAB><pass|fail> result
verdict|apply\tpassed\n|line 1 is not an <assertion><TAB><pass|fail> result
empty|# nothing ran\n|holds no assertion results
twice|apply\tpass\napply\tpass\n|reports assertion apply twice
failed|apply\tpass\nqueue\tfail\tno answer\n|assertion queue failing
EOF
  pass "drive-results: only a regular file of assertion results with every assertion passing is drive evidence"
}

fm_test_run \
  test_validate_admits_every_type_on_its_own_examples \
  test_validate_refuses_checks_that_cannot_tell_good_from_bad \
  test_validate_refuses_schema_breaks \
  test_validate_reads_the_slot_forms \
  test_run_reads_the_committed_ship_tree \
  test_run_reads_a_scout_directory_and_drive_results \
  test_run_cache_reruns_only_on_change \
  test_drive_results_reads_only_assertion_results

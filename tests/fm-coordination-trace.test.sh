#!/usr/bin/env bash
# Behavior tests for bin/fm-coordination-trace.sh.
#
# A synthetic main home, second mate home and worker record are laid out from
# the real record formats (parent channel, handled inbox, pending replies,
# branch-outcome rows with statusEndpoint, worker status with [at=]), then the
# trace is run through its public interface and its printed hops, counts and
# fallback list are asserted. Nothing here reads production state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRACE="$ROOT/bin/fm-coordination-trace.sh"
TMP_ROOT=$(fm_test_tmproot fm-coordination-trace)
MAIN="$TMP_ROOT/main"
MATE="$TMP_ROOT/mate"
STATE="$MAIN/state"

# Epochs inside 2026-10-20 UTC.
ROUTE=1792454460        # 09:01:00 handoff wake written
SPAWN=1792454580        # 09:03:00 worker first status line
ACK=1792454640          # 09:04:00 mate moved the wake into handled/
WORKER_DONE=1792458000  # 10:00:00 worker done line
FACT=1792458010         # 10:00:10 child-outcome line on the parent channel
FACT_ROW=1792458100     # 10:01:40 main wake row that presented the fact line
MATE_LINE_ROW=1792458400 # 10:06:40 main wake row that presented the mate's own line
CORR=0123456789abcdef
CORR2=fedcba9876543210

seed_fixture() {
  mkdir -p "$STATE/trelume.inbox/handled" "$STATE/pending-replies" "$MAIN/data" \
    "$MATE/state" "$MATE/data/alpha-task"
  printf -- '- trelume - Trelume domain (home: %s; scope: Trelume work; projects: Trelume; added 2026-10-01)\n' "$MATE" \
    > "$MAIN/data/secondmates.md"
  # Handoff wake (001) then a redundant second steer about the same item (002).
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\n[fm-from-firstmate]corr=%s New routed work is in your backlog. Run bin/fm-session-start.sh now, then act on the routed task.\n' \
    "$(date -u -d "@$ROUTE" +%Y-%m-%dT%H:%M:%SZ)" "$CORR" > "$STATE/trelume.inbox/handled/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\n[fm-from-firstmate]corr=%s New item handed into your backlog: alpha-task. Dispatch it now as a scout.\n' \
    "$(date -u -d "@$((ROUTE + 90))" +%Y-%m-%dT%H:%M:%SZ)" "$CORR2" > "$STATE/trelume.inbox/handled/002.msg"
  for c in "$CORR" "$CORR2"; do
    printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=trelume\ncreated_epoch=%s\ndelivered_epoch=%s\nphase=resolved\nresolved_epoch=%s\nresolved_via=status\n' \
      "$c" "$ROUTE" "$ROUTE" "$((ACK + 10))" > "$STATE/pending-replies/$c"
  done
  # Parent channel: the mate's pickup line (names the task and both corrs), the
  # script fact line and the mate's own judgement line.
  {
    printf 'working [key=alpha-task]: corr=%s corr=%s alpha-task dispatched as a scout\n' "$CORR" "$CORR2"
    printf 'done [key=child-outcome-alpha-task-done-0a1b2c3d] [at=%s]: child alpha-task done: report written [report=data/alpha-task/report.md]\n' "$FACT"
    printf 'done [key=alpha-task]: corr=%s corr=%s alpha-task finished; recommendation: ship it\n' "$CORR" "$CORR2"
  } > "$STATE/trelume.status"
  local line1 line2 line3
  line1=$(head -n 1 "$STATE/trelume.status" | wc -c)
  line2=$(sed -n 2p "$STATE/trelume.status" | wc -c)
  line3=$(sed -n 3p "$STATE/trelume.status" | wc -c)
  {
    printf '{"seq":1,"epoch":%s,"task":"trelume","wake":"signal: %s/trelume.status","verdict":"routine","summary":"pickup","silent":true,"statusEndpoint":%s,"statusIdent":"x"}\n' \
      "$((ACK + 10))" "$STATE" "$line1"
    printf '{"seq":2,"epoch":%s,"task":"trelume","wake":"signal: %s/trelume.status","verdict":"captain","summary":"alpha-task done","silent":false,"statusEndpoint":%s,"statusIdent":"x"}\n' \
      "$FACT_ROW" "$STATE" "$((line1 + line2))"
    printf '{"seq":3,"epoch":%s,"task":"trelume","wake":"signal: %s/trelume.status","verdict":"routine","summary":"mate judgement","silent":true,"statusEndpoint":%s,"statusIdent":"x"}\n' \
      "$MATE_LINE_ROW" "$STATE" "$((line1 + line2 + line3))"
    printf '{"seq":4,"epoch":%s,"task":"own-worker","wake":"signal: %s/own-worker.status","verdict":"routine","summary":"own","silent":true,"statusEndpoint":40,"statusIdent":"y"}\n' \
      "$((FACT_ROW + 5))" "$STATE"
  } > "$STATE/branch-outcomes.jsonl"
  printf 'working [at=%s]: started\ndone [at=%s]: finished\n' "$SPAWN" "$WORKER_DONE" > "$MATE/state/alpha-task.status"
  printf '{"seq":1,"epoch":%s,"task":"alpha-task","wake":"signal: %s/state/alpha-task.status","verdict":"routine","summary":"w","silent":true,"statusEndpoint":30,"statusIdent":"z"}\n' \
    "$((SPAWN + 20))" "$MATE" > "$MATE/state/branch-outcomes.jsonl"
  printf '# brief\n' > "$MATE/data/alpha-task/brief.md"
  printf 'done [at=%s]: own worker finished\n' "$FACT_ROW" > "$STATE/own-worker.status"
  # The handled file's ctime is the acknowledgement; set it last so it is the
  # newest event the test controls (ctime cannot be set directly).
  touch -d "@$ROUTE" "$STATE/trelume.inbox/handled/001.msg" "$STATE/trelume.inbox/handled/002.msg"
}

run_trace() {
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$STATE" "$TRACE" --since 2026-10-20 "$@"
}

test_trace_reconstructs_hops_copies_and_steers() {
  local out
  seed_fixture
  out=$(run_trace 2>&1) || fail "trace failed: $out"
  assert_contains "$out" "fm-coordination-trace: trelume since 2026-10-20" "trace did not resolve the registered mate"
  assert_contains "$out" "  alpha-task" "trace did not list the routed task"
  assert_contains "$out" "route        $(date -u -d "@$ROUTE" '+%Y-%m-%d %H:%M:%S')" "route hop is not the handoff wake's write time"
  assert_contains "$out" "spawn        $(date -u -d "@$SPAWN" '+%Y-%m-%d %H:%M:%S')  (worker first status line)" "spawn hop is not the worker's first status line"
  assert_contains "$out" "worker_end   $(date -u -d "@$WORKER_DONE" '+%Y-%m-%d %H:%M:%S')" "worker end is not the worker's done line"
  assert_contains "$out" "fact_line    $(date -u -d "@$FACT" '+%Y-%m-%d %H:%M:%S')" "fact line is not the child-outcome [at=]"
  assert_contains "$out" "fact_row     $(date -u -d "@$FACT_ROW" '+%Y-%m-%d %H:%M:%S')" "fact row is not the wake row covering the fact line's byte offset"
  assert_contains "$out" "mate_line    $(date -u -d "@$MATE_LINE_ROW" '+%Y-%m-%d %H:%M:%S')" "mate judgement line was not dated by its wake row"
  assert_contains "$out" "worker_end->fact_line=10s" "worker end to fact line edge wrong"
  assert_contains "$out" "fact_line->fact_row=1m30s" "fact line to fact row edge wrong"
  assert_contains "$out" "steers=2 (first ten minutes 2)" "the two steers about the task were not both attributed (corr via the mate's keyed line)"
  assert_contains "$out" "results=1 copies=2 lines in 2 supervision turns" "copies per result did not count the fact line and the mate's own line in two turns"
  assert_contains "$out" "copies per result at main: 2.00 lines, 2.00 supervision turns (1 results)" "summary copies per result wrong"
  assert_contains "$out" "after a handoff wake 2.00" "the redundant second steer after the handoff wake was not counted"
  assert_contains "$out" "1 handoff wakes" "the handoff wake was not classified"
  assert_contains "$out" "own-worker " "main-home task missing from the duplicate-result count"
  assert_contains "$out" "status_rows=1   stale_rows=0   terminal_lines=1" "main-home task rows and terminal lines wrong"
  assert_not_contains "$out" "spawn time fallback" "a worker with a timestamped first line must not report a spawn fallback"
  assert_contains "$out" "no transcript directory" "an absent transcript dir must be reported as the reason ask times are missing"
  pass "trace reconstructs hops from raw records, counts copies per result and steers per handoff"
}

test_trace_reports_fallbacks_and_refuses_unknown_mate() {
  local out rc=0
  rm -f "$MATE/state/alpha-task.status"
  out=$(run_trace --json "$TMP_ROOT/trace.json" 2>&1) || fail "trace without a worker status file failed: $out"
  assert_contains "$out" "(brief.md mtime)" "spawn did not fall back to the brief's mtime once the worker status was gone"
  assert_contains "$out" "spawn time fallback used: brief.md mtime" "the fallback was used but not listed"
  assert_contains "$out" "worker end fallback used: mate's last wake row for the worker's status (file gone)" "worker end fallback not listed"
  [ -s "$TMP_ROOT/trace.json" ] || fail "--json wrote nothing"
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["summary"]["routed_tasks"]==1 and d["tasks"][0]["task"]=="alpha-task", d["summary"]' "$TMP_ROOT/trace.json" \
    || fail "--json does not carry the traced task"
  out=$(FM_HOME="$MAIN" FM_STATE_OVERRIDE="$STATE" "$TRACE" nosuch 2>&1) || rc=$?
  expect_code 2 "$rc" "an unregistered mate must exit 2"
  assert_contains "$out" "mate home for nosuch not found" "an unregistered mate was not named"
  rc=0
  out=$(run_trace --since 2026-10-2x 2>&1) || rc=$?
  expect_code 2 "$rc" "a malformed --since must exit 2"
  assert_contains "$out" "fm-coordination-trace: invalid --since 2026-10-2x" "a malformed --since was not named"
  assert_not_contains "$out" "Traceback" "a malformed --since raised a traceback"
  pass "trace lists every fallback it used, dumps JSON and refuses an unknown mate by name"
}

# A handoff wake that names a connected set counts for every task it names, yet
# once in the steer totals; a wake row names a status file only by its exact
# basename, so not-own-worker.status is not own-worker.status.
test_trace_attributes_set_wakes_and_matches_exact_status_names() {
  mkdir -p "$MATE/data/beta-task"
  printf '# brief\n' > "$MATE/data/beta-task/brief.md"
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\n[fm-from-firstmate]corr=%s New routed work is in your backlog: alpha-task beta-task. Run bin/fm-session-start.sh now, then act on the routed task.\n' \
    "$(date -u -d "@$((ROUTE + 200))" +%Y-%m-%dT%H:%M:%SZ)" 00112233445566ff > "$STATE/trelume.inbox/handled/003.msg"
  printf '{"seq":5,"epoch":%s,"task":"own-worker","wake":"signal: %s/not-own-worker.status","verdict":"routine","summary":"other","silent":true,"statusEndpoint":10,"statusIdent":"w"}\n' \
    "$((FACT_ROW + 6))" "$STATE" >> "$STATE/branch-outcomes.jsonl"
  run_trace --json "$TMP_ROOT/set.json" >/dev/null 2>&1 || fail "trace with a set handoff wake failed"
  python3 -I - "$TMP_ROOT/set.json" <<'PY' || fail "a set handoff wake or an exact status name was traced wrong"
import json, sys
d = json.load(open(sys.argv[1]))
steers = {t["task"]: t["steers"] for t in d["tasks"]}
assert steers == {"alpha-task": 3, "beta-task": 1}, steers
assert d["summary"]["messages_total"] == 3 and d["summary"]["messages_attributed"] == 3, d["summary"]
assert [s["tasks"] for s in d["steers"] if s["id"] == "003"] == [["alpha-task", "beta-task"]], d["steers"]
own = [r for r in d["main_tasks"] if r["task"] == "own-worker"][0]
assert own["rows"] == 2 and own["status_rows"] == 1, own
PY
  pass "a set handoff wake counts for each named task once per steer, and status names match exactly"
}

test_trace_reconstructs_hops_copies_and_steers
test_trace_reports_fallbacks_and_refuses_unknown_mate
test_trace_attributes_set_wakes_and_matches_exact_status_names

#!/usr/bin/env bash
# Tests for bin/fm-browser-sessions.sh and bin/fm-browser-sessions-lib.sh: a
# closed task's chrome-devtools-axi bridge trees are found from their own
# environment and stopped, every other bridge is left alone, and the fleet view
# lists the orphans. Bridges are real detached stand-in processes
# (tests/fixtures.sh), so the /proc reading, the parent-pid walk, and the
# signals are all exercised for real. bin/fm-teardown.sh's own use of this
# stop is covered in tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SESSIONS="$ROOT/bin/fm-browser-sessions.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-sessions)

if ! fm_test_browser_supported; then
  echo "skip: /proc or setsid unavailable"
  exit 0
fi

# Every home lives under TMP_ROOT; make_home runs in command substitutions, so
# the reap finds the bridge directories on disk rather than in a shell array.
reap_all_bridges() {
  local d
  for d in "$TMP_ROOT"/*/bridges; do
    [ -d "$d" ] && fm_test_reap_fake_browser_bridges "$d"
  done
}
trap 'reap_all_bridges; fm_test_cleanup' EXIT

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$home/bridges" "$home/fakebin"
  fm_test_fake_chrome_devtools_axi "$home/fakebin"
  printf '%s\n' "$home"
}

run_sessions() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_CDA_LOG="$home/cda.log" \
    FM_BROWSER_TERM_GRACE_TENTHS=5 "$SESSIONS" "$@"
}

test_stop_reaches_only_the_closed_tasks_bridges_of_this_home() {
  local home other b a_pids b_pids c_pids d_pids e_pids stray rc err alive
  home=$(make_home scope)
  other=$TMP_ROOT/other-home
  mkdir -p "$other"
  b=$home/bridges
  # A: the task's bridge, its session pid file naming it, so stop is asked first.
  a_pids=$(fm_test_fake_browser_bridge "$b" sess-a task-a "$home") || fail "bridge A did not start"
  fm_test_fake_browser_pidfile "$b" sess-a "${a_pids%% *}"
  # B: the task's bridge whose session pid file a later bridge overwrote.
  b_pids=$(fm_test_fake_browser_bridge "$b" sess-b task-a "$home") || fail "bridge B did not start"
  fm_test_fake_browser_pidfile "$b" sess-b 1
  # C: the same task id in another home; D: another task here; E: no task id.
  c_pids=$(fm_test_fake_browser_bridge "$b" sess-c task-a "$other") || fail "bridge C did not start"
  d_pids=$(fm_test_fake_browser_bridge "$b" sess-d task-b "$home") || fail "bridge D did not start"
  e_pids=$(fm_test_fake_browser_bridge "$b" sess-e - "$home") || fail "bridge E did not start"
  # A process carrying the task's variables that is not a session leader, as a
  # worker shell that exported them would be.
  env CHROME_DEVTOOLS_AXI_SESSION=sess-a CHROME_DEVTOOLS_AXI_PORT=9999 FM_TASK_ID=task-a \
    FM_HOME="$home" HOME="$b/home" sleep 300 </dev/null >/dev/null 2>&1 &
  stray=$!
  printf '%s\n' "$stray" > "$b/stray.pids"

  err=$(run_sessions "$home" stop task-a 2>&1 >/dev/null)
  rc=$?
  expect_code 0 "$rc" "stop of a closed task's bridges should succeed: $err"
  # shellcheck disable=SC2086 # pid lists split on purpose
  alive=$(fm_test_alive_pids $a_pids $b_pids)
  [ -z "$alive" ] || fail "the closed task's bridge trees still have live processes: $alive"
  # shellcheck disable=SC2086
  alive=$(fm_test_alive_pids $c_pids $d_pids $e_pids "$stray" | wc -l | tr -d ' ')
  [ "$alive" = 10 ] || fail "a bridge of another home, another task, no task, or a non-leader was touched ($alive of 10 alive)"
  assert_contains "$err" "stopped browser session sess-a for task-a (bridge pid ${a_pids%% *}, port 9999, 3 process(es)): stopped through chrome-devtools-axi; terminated 1 remaining process(es)" \
    "the asked-then-terminated session was not reported"
  assert_contains "$err" "stopped browser session sess-b for task-a (bridge pid ${b_pids%% *}, port 9999, 3 process(es)): chrome-devtools-axi stop skipped: its session pid file names another bridge; terminated 3 remaining process(es)" \
    "the session whose pid file names another bridge was not reported as terminated"
  assert_equals "stop $b/home sess-a" "$(cat "$home/cda.log")" \
    "chrome-devtools-axi stop must run once, for the session whose pid file names the bridge"
  kill -KILL "$stray" 2>/dev/null; wait "$stray" 2>/dev/null
  pass "stop ends only this home's bridge trees for the closed task, asking chrome-devtools-axi first when it can"
}

test_stop_refuses_a_live_task() {
  local home pids rc err
  home=$(make_home live)
  pids=$(fm_test_fake_browser_bridge "$home/bridges" live-sess task-live "$home") || fail "bridge did not start"
  fm_write_meta "$home/state/task-live.meta" "kind=ship"
  err=$(run_sessions "$home" stop task-live 2>&1)
  rc=$?
  expect_code 1 "$rc" "stop must refuse a task that still has a record"
  assert_contains "$err" "REFUSED: task-live is still a live task" "refusal did not name the live task"
  # shellcheck disable=SC2086
  [ "$(fm_test_alive_pids $pids | wc -l | tr -d ' ')" = 3 ] || fail "a refused stop touched the live task's browser"
  pass "stop refuses while the task is still live"
}

test_tree_that_ignores_term_is_killed() {
  local home pids rc err alive
  home=$(make_home stubborn)
  pids=$(fm_test_fake_browser_bridge "$home/bridges" stubborn task-s "$home" ignore-term) || fail "bridge did not start"
  err=$(run_sessions "$home" stop task-s 2>&1)
  rc=$?
  expect_code 0 "$rc" "a tree that ignores TERM should still end: $err"
  # shellcheck disable=SC2086
  alive=$(fm_test_alive_pids $pids)
  [ -z "$alive" ] || fail "processes ignoring TERM survived: $alive"
  assert_contains "$err" "terminated 3 remaining process(es)" "the forced stop was not reported"
  pass "a bridge tree that ignores TERM is killed"
}

test_stop_with_nothing_to_stop_says_so() {
  local home out rc
  home=$(make_home none)
  out=$(run_sessions "$home" stop task-none 2>&1)
  rc=$?
  expect_code 0 "$rc" "stop with no bridges should succeed"
  assert_contains "$out" "no browser sessions of this home for task-none" "empty stop was silent"
  pass "stop with nothing to stop says so"
}

test_list_json_scopes_each_bridge() {
  local home other b live orphan foreign bare json
  home=$(make_home list)
  other=$TMP_ROOT/list-other
  mkdir -p "$other"
  b=$home/bridges
  fm_write_meta "$home/state/task-live.meta" "kind=ship"
  live=$(fm_test_fake_browser_bridge "$b" l-live task-live "$home") || fail "bridge did not start"
  orphan=$(fm_test_fake_browser_bridge "$b" l-orphan task-gone "$home") || fail "bridge did not start"
  foreign=$(fm_test_fake_browser_bridge "$b" l-foreign task-gone "$other") || fail "bridge did not start"
  bare=$(fm_test_fake_browser_bridge "$b" l-bare - -) || fail "bridge did not start"
  json=$(run_sessions "$home" list --json) || fail "list --json failed"
  printf '%s' "$json" | jq -e \
    --argjson live "${live%% *}" --argjson orphan "${orphan%% *}" \
    --argjson foreign "${foreign%% *}" --argjson bare "${bare%% *}" --arg home "$home" '
    def at($p): .helpers[] | select(.pid == $p);
    .supported == true
    and (at($live) | .scope == "live_task" and .task_id == "task-live" and .session == "l-live")
    and (at($orphan) | .scope == "orphan" and .task_id == "task-gone" and .fm_home == $home
         and .port == "9999" and (.age_seconds | type) == "number" and .rss_kb > 0)
    and (at($foreign) | .scope == "other_home")
    and (at($bare) | .scope == "unattributed" and .task_id == null and .fm_home == null)
    and ([.helpers[] | select(.pid == $live or .pid == $orphan or .pid == $foreign or .pid == $bare)] | length == 4)
  ' >/dev/null || fail "list --json scopes or fields wrong: $json"
  pass "list --json reports each bridge with its owner and scope"
}

test_fleet_view_lists_orphans_with_task_and_age() {
  local home pids view
  command -v jq >/dev/null 2>&1 || { pass "fleet view case skipped: jq not found"; return 0; }
  home=$(make_home view)
  pids=$(fm_test_fake_browser_bridge "$home/bridges" v-orphan task-view-gone "$home") || fail "bridge did not start"
  view=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$VIEW") || fail "fleet view failed"
  assert_contains "$view" "## Browser helpers" "fleet view has no browser helper section"
  printf '%s\n' "$view" | grep -E "^\| task-view-gone \| orphan \| v-orphan \| [0-9]+m \| [0-9]+ MB \| ${pids%% *} \| bin/fm-browser-sessions.sh stop task-view-gone \|$" >/dev/null \
    || fail "fleet view did not list the orphan with its task, age, and cleanup: $view"
  pass "fleet view lists an orphan bridge with its task id, age, and cleanup command"
}

test_stop_reaches_only_the_closed_tasks_bridges_of_this_home
test_stop_refuses_a_live_task
test_tree_that_ignores_term_is_killed
test_stop_with_nothing_to_stop_says_so
test_list_json_scopes_each_bridge
test_fleet_view_lists_orphans_with_task_and_age

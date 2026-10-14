#!/usr/bin/env bash
# Guard for tests/env-isolation-helpers.sh: a test process never sees the
# caller's live fleet routing.
#
# Every case starts a child from a caller environment shaped like a worker pane
# inside a live Herdr session - FM_HOME and the state root at a "live" home,
# FM_BACKEND=herdr, the Herdr pane identity, a tmux client, a task inbox, and a
# backlog override - and records what the child can see after each supported
# entry: sourcing tests/lib.sh, sourcing the helper alone, the helper's exec
# mode, and bin/fm-test-run.sh running a script that sources nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-env-isolation)
LIVE_HOME="$TMP_ROOT/live-home"
mkdir -p "$LIVE_HOME/state" "$LIVE_HOME/data" "$LIVE_HOME/tmux" "$LIVE_HOME/pools"
HELPER="$ROOT/tests/env-isolation-helpers.sh"

# live_env <command...>: run <command> under the live-shaped caller environment.
live_env() {
  env FM_HOME="$LIVE_HOME" FM_STATE_OVERRIDE="$LIVE_HOME/state" \
    FM_DATA_OVERRIDE="$LIVE_HOME/data" FM_CONFIG_OVERRIDE="$LIVE_HOME/config" \
    FM_BACKEND=herdr FM_TASK_ID=live-task FM_TASK_INBOX="$LIVE_HOME/state/live-task.inbox" \
    HERDR_ENV=1 HERDR_SESSION=live-session HERDR_SOCKET_PATH="$LIVE_HOME/herdr.sock" \
    HERDR_PANE_ID=w1:p1 HERDR_TAB_ID=w1:t1 HERDR_WORKSPACE_ID=w1 HERDR_NOT_YET_INVENTED=1 \
    TMUX="$LIVE_HOME/tmux/default,1,0" TMUX_PANE=%1 \
    TMUX_TMPDIR="$LIVE_HOME/tmux" TREEHOUSE_ROOT="$LIVE_HOME/pools" \
    ZELLIJ=0 ZELLIJ_SESSION_NAME=live-session CMUX_WORKSPACE_ID=live ORCA_TERMINAL=live \
    TASKS_AXI_FILE="$LIVE_HOME/data/backlog.md" \
    FM_TEST_CALLER_KNOB=kept FM_HERDR_LAB_PROTECTED_SESSION=live-session \
    "$@"
}

# env_line <env-dump> <extended-regex>: the dump has a line matching the regex.
env_line() {
  grep -E -- "$2" "$1" >/dev/null
}

# assert_isolated <env-dump> <label>: nothing in the dump routes to the live
# fleet, and the caller's test-run knobs survived.
assert_isolated() {
  local dump=$1 label=$2 name
  for name in FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND \
    FM_TASK_ID FM_TASK_INBOX TMUX TMUX_PANE TASKS_AXI_FILE; do
    ! env_line "$dump" "^$name=" || fail "$label: the test process still sees the caller's $name"
  done
  ! env_line "$dump" '^(HERDR_|ZELLIJ|CMUX_|ORCA_)' \
    || fail "$label: the test process still sees a caller multiplexer identity:"$'\n'"$(grep -E '^(HERDR_|ZELLIJ|CMUX_|ORCA_)' "$dump")"
  # The protected-session knob names the live session on purpose; every other
  # mention of the live home or session is a leak.
  if grep -v '^FM_HERDR_LAB_PROTECTED_SESSION=' "$dump" | grep -F -e "$LIVE_HOME" -e live-session >/dev/null; then
    fail "$label: the test process can still reach the live home or session:"$'\n'"$(grep -F -e "$LIVE_HOME" -e live-session "$dump")"
  fi
  env_line "$dump" '^FM_TEST_CALLER_KNOB=kept$' || fail "$label: a caller test knob did not survive"
  env_line "$dump" '^FM_HERDR_LAB_PROTECTED_SESSION=live-session$' \
    || fail "$label: the protected Herdr session knob did not survive"
}

test_lib_hides_live_routing() {
  local dump="$TMP_ROOT/lib.env"
  # shellcheck disable=SC2016
  live_env bash -c '. "$1/tests/lib.sh" && env > "$2"' _ "$ROOT" "$dump" \
    || fail "sourcing tests/lib.sh under a live-shaped environment failed"
  assert_isolated "$dump" "tests/lib.sh"
  grep -Fx -- "TMUX_TMPDIR=$FM_TEST_BACKEND_ROOT" "$dump" >/dev/null \
    || fail "tests/lib.sh did not keep a nested suite on its parent's private tmux socket directory"
  grep -Fx -- "TREEHOUSE_ROOT=$FM_TEST_BACKEND_ROOT/treehouse" "$dump" >/dev/null \
    || fail "tests/lib.sh did not keep a nested suite on its parent's private treehouse pool root"
  pass "a suite sourcing tests/lib.sh cannot see the caller's live home, session, or backend"
}

test_lib_gives_a_fresh_suite_private_backend_roots() {
  local dump="$TMP_ROOT/lib-fresh.env" root
  # shellcheck disable=SC2016
  live_env env -u FM_TEST_BACKEND_ROOT bash -c '. "$1/tests/lib.sh" && env > "$2"' _ "$ROOT" "$dump" \
    || fail "sourcing tests/lib.sh as a top-level suite failed"
  root=$(sed -n 's/^FM_TEST_BACKEND_ROOT=//p' "$dump")
  case "$root" in
    /tmp/fm-env.*) ;;
    *) fail "a top-level suite got no private backend root under /tmp: '$root'" ;;
  esac
  grep -Fx -- "TMUX_TMPDIR=$root" "$dump" >/dev/null || fail "a top-level suite's tmux socket directory is not its private root"
  grep -Fx -- "TREEHOUSE_ROOT=$root/treehouse" "$dump" >/dev/null || fail "a top-level suite's treehouse pool root is not private"
  [ ! -e "$root" ] || fail "the suite's private backend root outlived the suite: $root"
  pass "a top-level suite gets a private tmux socket directory and treehouse pool root, removed at exit"
}

test_lib_resolves_the_default_backend_not_the_live_one() {
  local out
  # shellcheck disable=SC2016
  out=$(live_env bash -c '. "$1/tests/lib.sh" && FM_HOME="$2" && . "$1/bin/fm-backend.sh" && fm_backend_name' \
    _ "$ROOT" "$TMP_ROOT/empty-home") || fail "backend resolution under tests/lib.sh failed: $out"
  [ "$out" = tmux ] || fail "a suite resolved the caller's live backend '$out' instead of the default tmux"
  pass "an inherited FM_BACKEND=herdr and Herdr pane no longer select the live backend inside a suite"
}

test_helper_sourced_alone_hides_live_routing() {
  local dump="$TMP_ROOT/helper.env"
  # shellcheck disable=SC2016
  live_env bash -c '. "$1" && env > "$2"' _ "$HELPER" "$dump" \
    || fail "sourcing the isolation helper alone failed"
  assert_isolated "$dump" "env-isolation-helpers.sh sourced"
  pass "a suite sourcing only the isolation helper cannot see the caller's live routing"
}

test_helper_exec_mode_hides_live_routing() {
  local dump="$TMP_ROOT/exec.env"
  # shellcheck disable=SC2016
  live_env bash "$HELPER" sh -c 'env > "$1"' _ "$dump" \
    || fail "the isolation helper's exec mode failed"
  assert_isolated "$dump" "env-isolation-helpers.sh exec"
  pass "the isolation helper's exec mode hands its command a clean environment"
}

test_runner_isolates_a_script_that_sources_nothing() {
  local dir="$TMP_ROOT/runner" dump out
  dump="$dir/probe.env"
  mkdir -p "$dir"
  cat > "$dir/fm-env-probe.test.sh" <<SH
#!/usr/bin/env bash
env > "$dump"
echo "ok - probe"
SH
  out=$(live_env "$ROOT/bin/fm-test-run.sh" "$dir/fm-env-probe.test.sh" 2>&1) \
    || fail "fm-test-run.sh could not run the probe script:"$'\n'"$out"
  [ -f "$dump" ] || fail "the probe script never ran under fm-test-run.sh:"$'\n'"$out"
  assert_isolated "$dump" "fm-test-run.sh"
  pass "fm-test-run.sh starts a script that sources no helper without the caller's live routing"
}

test_refuses_to_run_in_the_live_home() {
  local out status
  # shellcheck disable=SC2016
  out=$(env FM_HOME="$ROOT" bash -c '. "$1/tests/lib.sh" && echo reached-suite-body' _ "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a suite ran with FM_HOME naming its own checkout, the live home"
  assert_not_contains "$out" reached-suite-body "the suite body ran in the live home"
  assert_contains "$out" "refusing to run tests in the live Firstmate home" \
    "the live-home refusal did not explain itself"
  pass "a suite refuses to run when the caller's home is the checkout under test"
}

test_lib_hides_live_routing
test_lib_gives_a_fresh_suite_private_backend_roots
test_lib_resolves_the_default_backend_not_the_live_one
test_helper_sourced_alone_hides_live_routing
test_helper_exec_mode_hides_live_routing
test_runner_isolates_a_script_that_sources_nothing
test_refuses_to_run_in_the_live_home

echo "# all fm-test-env-isolation tests passed"

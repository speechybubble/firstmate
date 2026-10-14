#!/usr/bin/env bash
# tests/env-isolation-helpers.sh - cut a test process off from the caller's live fleet.
#
# A test started from inside a Firstmate pane inherits that pane's routing:
# FM_HOME and the FM_*_OVERRIDE roots name the live home, FM_BACKEND and the
# multiplexer identity (TMUX, HERDR_*, ZELLIJ*, CMUX_*, ORCA_*) name the live
# session, TMUX_TMPDIR and TREEHOUSE_ROOT name the caller's tmux server and
# worktree pools, FM_TASK_* names the live task, and TASKS_AXI_* names the live
# backlog.
# Any bin/ call a test does not pin completely then lands in the live fleet:
# tests/fm-spawn-worktree-settle.test.sh pinned its home but not its backend, so
# an inherited FM_BACKEND=herdr spawned real agent panes and treehouse pools into
# the operator's live Herdr session instead of the suite's fake tmux.
#
# Sourcing this file drops every such variable, so a suite starts from the
# environment CI gives it, and refuses to continue when the checkout under test
# is the caller's live home, where an unpinned FM_HOME would resolve to it.
# A test that exercises one of these variables sets it itself after sourcing;
# that is the only opt-in. Knobs a caller sets for the run itself survive:
# FM_TEST_*, FM_LIVE and the per-guard live switches, and
# FM_HERDR_LAB_PROTECTED_SESSION.
#
# tests/lib.sh sources this first and also gives each suite a private tmux socket
# directory and treehouse pool root (fm_test_env_private_backend_roots); a test
# that does not source lib.sh sources this directly. Executed instead of sourced,
# `bash tests/env-isolation-helpers.sh <command...>` applies the same isolation and then
# execs <command>; bin/fm-test-run.sh runs every script that way, so a script
# that sources neither still starts clean under the runner.
# tests/fm-test-env-isolation.test.sh is the guard.

# fm_test_env_routing_names: print, one per line, every variable currently in the
# environment that routes to a live home, session, task, or backlog.
# Two entries carry their own history: FM_TASK_ID is the marker under which
# bin/fm-test-run.sh refuses a primary checkout, and fixtures run a copied runner
# in the primary of a git-init repository; TASKS_AXI_FILE and TASKS_AXI_BACKEND
# resolve ahead of the .tasks.toml a fixture copies, which once sent
# tests/fm-public-followup.test.sh's writes into the operator's live backlog.
fm_test_env_routing_names() {
  local name
  for name in \
    FM_HOME FM_ROOT FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
    FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_PENDING_REPLY_DIR_OVERRIDE \
    FM_BACKEND FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION FM_ZELLIJ_SESSION \
    FM_TASK_ID FM_TASK_INBOX \
    FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_SUPERVISION_ACTOR \
    FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_REMOTE_JOB_STATE_ROOT FM_LOCK_OWNER_DIR \
    FM_PROCEVENT_CLAIM_ROOT FM_PROCEVENT_CLAIM_STATE_ROOT FM_PROCEVENT_IN_RUNNER \
    FM_TIMING_LOG FM_SESSION_START_STAGE_FILE \
    TASKS_AXI_FILE TASKS_AXI_BACKEND \
    TMUX TMUX_PANE TMUX_TMPDIR TREEHOUSE_DIR TREEHOUSE_ROOT __CFBundleIdentifier; do
    [ -z "${!name+x}" ] || printf '%s\n' "$name"
  done
  # Every multiplexer injects a family of identity variables into its panes and
  # adds more across releases, so these are swept by prefix rather than listed.
  compgen -e | grep -E '^(HERDR_|ZELLIJ|CMUX_|ORCA_)' || true
}

# fm_test_env_refuse_live_home: stop when the caller's FM_HOME names this
# checkout. With routing dropped, every bin/ call a test leaves unpinned resolves
# its home to the code root, which there is the live home itself.
fm_test_env_refuse_live_home() {
  local root home
  [ -n "${FM_HOME:-}" ] || return 0
  root=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P) || return 1
  home=$(cd -P -- "$FM_HOME" 2>/dev/null && pwd -P) || return 0
  [ "$home" != "$root" ] || {
    printf 'not ok - refusing to run tests in the live Firstmate home %s (FM_HOME names it); run them from a disposable worktree\n' \
      "$root" >&2
    return 1
  }
}

# fm_test_env_private_backend_roots <dir>: point any real tmux or treehouse a
# test reaches at <dir>, so a server or pool it starts without naming its own
# lands there instead of beside the operator's sessions and pools. Keep <dir>
# short: tmux places its socket under it.
fm_test_env_private_backend_roots() {
  export TMUX_TMPDIR="$1"
  export TREEHOUSE_ROOT="$1/treehouse"
}

fm_test_env_refuse_live_home || exit 1
while IFS= read -r fm_test_env_name; do
  unset "$fm_test_env_name"
done < <(fm_test_env_routing_names)
unset fm_test_env_name

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ "$#" -gt 0 ] || { echo "usage: bash tests/env-isolation-helpers.sh <command...>" >&2; exit 2; }
  exec "$@"
fi

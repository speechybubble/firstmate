#!/usr/bin/env bash
# tests/fm-spawn-worker-home-env.test.sh - every ship and scout worker starts
# with FM_HOME and FM_STATE_OVERRIDE naming the home that launched it.
#
# A worker's pane takes its environment from the terminal server, which one home
# can share with another: a second mate's workers once started with the main
# home's FM_HOME and FM_STATE_OVERRIDE and wrote a decision row into the wrong
# home's backlog. So the pane environment here deliberately names a different
# home, and the launch must override it rather than inherit it.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# (and bin/fm-control.sh relaunch) against a fake pane, then EXECUTE the launch
# command the pane received under that foreign pane environment, with the
# harness replaced by a probe that prints the two variables it started with.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worker-home-env)
FOREIGN_HOME="$TMP_ROOT/foreign-home"
mkdir -p "$FOREIGN_HOME/state"

install_home_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf 'FM_HOME=%s FM_STATE_OVERRIDE=%s\n' "${FM_HOME-unset}" "${FM_STATE_OVERRIDE-unset}"
SH
  chmod +x "$1/$2"
}

# Run the pane's pre-launch exports and the launch command in a pane shell whose
# inherited environment names the foreign home.
#   foreign_pane_run <fakebin> <pane-home> <preamble> <launch>
foreign_pane_run() {
  env -i HOME="$2" PATH="$1:$PATH" TERM=xterm TMUX=synthetic-pane \
    FM_HOME="$FOREIGN_HOME" FM_STATE_OVERRIDE="$FOREIGN_HOME/state" \
    /bin/sh -c "$3
$4"
}

expected_env() {  # <home>
  printf 'FM_HOME=%s FM_STATE_OVERRIDE=%s' "$(cd "$1" && pwd -P)" "$(cd "$1/state" && pwd -P)"
}

test_spawn_sets_dispatching_home() {
  local kind setting name case_dir home proj wt fakebin launchlog panelog id out status seen
  for kind in ship scout; do
    for setting in absent enabled; do
      name="$kind-$setting"
      id="home-$name-a1"
      case_dir="$TMP_ROOT/$name"
      home="$case_dir/home"
      proj="$case_dir/project"
      wt="$case_dir/wt"
      launchlog="$case_dir/launch.log"
      panelog="$case_dir/pane.log"
      fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
      fm_test_spawn_home "$home" codex
      fm_git_worktree "$proj" "$wt" "wt-$name"
      fm_test_spawn_brief "$home" "$id"
      [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
      : > "$launchlog"
      : > "$panelog"
      if [ "$kind" = ship ]; then
        out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
          fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
      else
        out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
          fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      install_home_probe "$fakebin" codex
      seen=$(foreign_pane_run "$fakebin" "$TMP_ROOT/pane-home" "$(grep '^export ' "$panelog")" "$(cat "$launchlog")") \
        || fail "$kind, allowlist $setting: the emitted launch failed to run"
      assert_equals "$(expected_env "$home")" "$seen" \
        "a $kind worker launched with allowlist=$setting from a pane naming another home must start in its dispatching home"
    done
  done
  pass "ship and scout spawns start their worker in the dispatching home whatever the pane environment names"
}

# bin/fm-control.sh relaunch rebuilds the launch through bin/fm-spawn.sh
# --relaunch. This stub models just enough pane lifecycle for that transaction,
# following tests/fm-spawn-compact-adviser-disable.test.sh.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) printf 'codex' > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# The relaunch caller's own environment also names the foreign state root, as
# the second mate's sessions did; only FM_HOME is the dispatching home, which
# bin/fm-control.sh requires explicitly.
test_relaunch_sets_dispatching_home() {
  local setting dir home proj wt id out status seen launch
  for setting in absent enabled; do
    id="home-relaunch-$setting-a1"
    dir="$TMP_ROOT/relaunch-$setting"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$dir/user-home"
    touch "$home/state/.last-watcher-beat"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    make_relaunch_stub "$dir"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$setting"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/literal"
    : > "$dir/fake/keys"
    printf 'codex' > "$dir/fake/command"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=codex"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "tasktmp=$dir/tasktmp"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"

    out=$(env -u FM_STATE_OVERRIDE PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with allowlist=$setting should succeed: $out"
    launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
    [ -n "$launch" ] || fail "relaunch with allowlist=$setting sent no replacement launch command"
    install_home_probe "$dir/fakebin" codex
    seen=$(foreign_pane_run "$dir/fakebin" "$dir/user-home" "$(grep '^export ' "$dir/fake/keys")" "$launch") \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run"
    assert_equals "$(expected_env "$home")" "$seen" \
      "a relaunched worker with allowlist=$setting must start in its dispatching home, exactly as a fresh spawn does"
  done
  pass "relaunch starts the replacement worker in the dispatching home whatever the pane environment names"
}

test_spawn_sets_dispatching_home
test_relaunch_sets_dispatching_home

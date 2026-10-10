#!/usr/bin/env bash
# Disposable live lab: marked FM lab home, private tmux server, real
# bin/fm-spawn.sh / bin/fm-control.sh, stand-in claude on PATH.
set -u
REPO=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M4K823EVWQRYWV0TRYDS48QG
LAB=${LAB:-/tmp/rsl/lab}
labenv() {
  env -u TMUX -u TMUX_PANE -u CLAUDE_CONFIG_DIR -u FM_TASK_ID -u FM_TASK_INBOX \
    -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    HOME="$LAB/userhome" FM_HOME="$LAB/home" TMUX_TMPDIR="$(cat "$LAB/tmuxdir")" \
    PATH="/tmp/rsl:$PATH" FM_SPAWN_NO_GUARD=1 "$@"
}
ltmux() { labenv tmux "$@"; }
teardown() {
  [ -f "$LAB/tmuxdir" ] && { ltmux kill-server 2>/dev/null; "$REPO/bin/fm-lab-home.sh" teardown "$LAB/home" >/dev/null 2>&1; }
  pkill -f "^/usr/bin/python3 /tmp/rsl/claude" 2>/dev/null
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
}
setup() {
  teardown; mkdir -p "$LAB/userhome"
  "$REPO/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
  "$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB/home" > "$LAB/tmuxdir"
  ltmux new-session -d -s firstmate -n main -x 200 -y 50 -c "$LAB/home" 'exec sleep 3600'
}
# add_ship <id>
add_ship() {
  local id=$1 proj="$LAB/proj-$1" wt="$LAB/wt-$1"
  mkdir -p "$proj"; git -C "$proj" init -q -b main
  printf 'hello\n' > "$proj/README.md"; git -C "$proj" add -A; git -C "$proj" -c user.name=t -c user.email=t@x.invalid commit -qm init
  git -C "$proj" worktree add -q -b "task-$id" "$wt"
  mkdir -p "$LAB/home/data/$id"
  cat > "$LAB/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise exact-session relaunch for $id.

## Firstmate spec
Preserve the conversation while replacing the agent process.
EOF
  cat > "$LAB/home/state/$id.meta" <<EOF
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$wt
project=$proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$id
model=default
effort=default
EOF
  ltmux new-window -d -t firstmate: -n "fm-$id" -c "$wt"
}
"$@"

#!/usr/bin/env bash
# Disposable live fixture: private real tmux server (-L), throwaway HOME,
# FM home, project repo + task worktree, and a ship/secondmate meta.
# Usage: setup.sh <root> <repo-root> <id> <kind:ship|secondmate>
set -eu
R=$1 REPO=$2 ID=$3 KIND=${4:-ship}
EV=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$R"/{fb,user-home}
"$REPO/bin/fm-lab-home.sh" create "$R/home" >/dev/null
mkdir -p "$R/home/state" "$R/home/data/$ID"
REAL_TMUX=$(command -v tmux)
SOCK=fmlive-$ID-$$
printf '%s' "$SOCK" > "$R/sock"
printf '#!/usr/bin/env bash\nexec %s -L %s -f /dev/null "$@"\n' "$REAL_TMUX" "$SOCK" > "$R/fb/tmux"
cp "$EV/fake-claude.sh" "$R/fb/claude"
chmod +x "$R/fb/tmux" "$R/fb/claude"
. "$REPO/tests/lib.sh" >/dev/null 2>&1 || true
if [ "$KIND" = ship ]; then
  WT=$R/wt
  fm_git_worktree "$R/proj" "$WT" "task-$ID" >/dev/null
  cat > "$R/home/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Exercise live exact-session resume for $ID.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  printf '%s\n' "window=fmlive:fm-$ID" "endpoint_task_id=$ID" "worktree=$WT" "project=$R/proj" \
    harness=claude kind=ship mode=no-mistakes yolo=off "tasktmp=/tmp/fm-$ID" model=default effort=default \
    > "$R/home/state/$ID.meta"
fi
printf '%s' "$WT" > "$R/wt-path"
# Pane environment: empty start, fake bin first, throwaway HOME.
env -i HOME="$R/user-home" PATH="$R/fb:/usr/local/bin:/usr/bin:/bin" TERM=xterm-256color \
  SHELL=/bin/bash FAKE_CLAUDE_LOG="$R/claude.log" LANG=C.UTF-8 \
  "$R/fb/tmux" new-session -d -s fmlive -n "fm-$ID" -c "$WT" -x 160 -y 40 'bash --norc --noprofile'
echo "root=$R wt=$WT sock=$SOCK"

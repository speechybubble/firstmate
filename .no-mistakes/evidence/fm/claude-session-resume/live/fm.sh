#!/usr/bin/env bash
# Run a Fleet script against the disposable fixture: fm.sh <root> <repo> <script> <args...>
R=$1 REPO=$2 S=$3; shift 3
exec env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
  -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u FM_TASK_ID -u FM_TASK_INBOX \
  PATH="$R/fb:$PATH" FM_HOME="$R/home" HOME="$R/user-home" CLAUDE_CONFIG_DIR='' \
  FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 FAKE_CLAUDE_LOG="$R/claude.log" \
  "$REPO/bin/$S" "$@"

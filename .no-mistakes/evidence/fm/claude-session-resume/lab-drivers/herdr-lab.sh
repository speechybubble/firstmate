#!/usr/bin/env bash
# Real-Herdr lab: isolated fm-lab-* session, marked FM lab home, legacy
# secondmate (FM_HOME only) running the stand-in claude in a real Herdr pane.
set -u
R=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M4K823EVWQRYWV0TRYDS48QG
HL=/tmp/rsl/hlab
export FM_HERDR_LAB_PROTECTED_SESSION=kun
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX TMUX_PANE CLAUDE_CONFIG_DIR FM_TASK_ID FM_TASK_INBOX
case "$1" in
up)
  rm -rf $HL; mkdir -p $HL/userhome
  S=$($R/bin/fm-herdr-lab.sh name rsresume) || exit 1; echo "$S" > $HL/session
  $R/bin/fm-herdr-lab.sh provision "$S" || exit 1
  $R/bin/fm-lab-home.sh create $HL/home >/dev/null
  SM=$HL/smhome; mkdir -p $HL/smproj; git -C $HL/smproj init -q -b main; echo x > $HL/smproj/f; git -C $HL/smproj add -A; git -C $HL/smproj -c user.name=t -c user.email=t@x.invalid commit -qm i; git -C $HL/smproj worktree add -q -b sm-branch $SM
  mkdir -p $SM/state $SM/data $SM/bin; echo hsm1 > $SM/.fm-secondmate-home; echo '# charter' > $SM/data/charter.md; echo '# agents' > $SM/AGENTS.md
  printf 'claude\n' > $HL/home/config/secondmate-harness
  ( export HERDR_SESSION=$S; . $R/bin/fm-backend.sh; fm_backend_source herdr
    C=$(fm_backend_herdr_container_ensure "$SM") || exit 1; CONT=${C%%$'\t'*}; SEED=${C#*$'\t'}; WS=${CONT#*:}
    read -r TAB PANE <<<"$(fm_backend_herdr_create_task "$CONT" fm-hsm1 "$SM" "$SEED")"
    cat > $HL/home/state/hsm1.meta <<EOF
window=$S:$PANE
endpoint_task_id=hsm1
worktree=$SM
project=$SM
harness=claude
kind=secondmate
mode=secondmate
yolo=off
model=default
effort=default
home=$SM
projects=
backend=herdr
herdr_session=$S
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
    sleep 1
    fm_backend_herdr_send_text_line "$S:$PANE" "export CLAUDE_CONFIG_DIR=$HL/userhome/.claude PATH=/tmp/rsl:\$PATH; unset FM_TASK_INBOX FM_TASK_ID; cd $SM"
    sleep 0.5
    fm_backend_herdr_send_text_line "$S:$PANE" "FM_HOME=$SM claude"
  )
  ;;
env)
  shift; S=$(cat $HL/session)
  env CLAUDE_CONFIG_DIR=$HL/userhome/.claude FM_HOME=$HL/home HERDR_SESSION=$S PATH="/tmp/rsl:$PATH" FM_SPAWN_NO_GUARD=1 "$@"
  ;;
down)
  S=$(cat $HL/session); $R/bin/fm-herdr-lab.sh teardown "$S"; pkill -f "^/usr/bin/python3 /tmp/rsl/claude" ; find $HL -type d -exec chmod u+rwx {} + 2>/dev/null; rm -rf $HL
  ;;
esac

#!/usr/bin/env bash
# S4 driver: legacy secondmate (FM_HOME only, no FM_TASK_INBOX) in its pane.
set -u
EV=$(cd "$(dirname "$0")" && pwd); W=$1; ID=rsm1
R=$(mktemp -d /tmp/fmlive-s.XXXX); echo $R >> /tmp/fmlive-roots
mkdir -p $R/fb $R/user-home
"$W/bin/fm-lab-home.sh" create $R/home >/dev/null; mkdir -p $R/home/state $R/home/data $R/home/config
printf 'claude\n' > $R/home/config/secondmate-harness
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec %s -L fmlive-sm-%s -f /dev/null "$@"\n' "$REAL_TMUX" $$ > $R/fb/tmux
cp "$EV/fake-claude.sh" $R/fb/claude; chmod +x $R/fb/tmux $R/fb/claude
( . "$W/tests/lib.sh" >/dev/null 2>&1; fm_git_worktree $R/proj $R/smhome sm-branch >/dev/null )
mkdir -p $R/smhome/state $R/smhome/data $R/smhome/bin
printf '%s\n' $ID > $R/smhome/.fm-secondmate-home; printf '# charter\n' > $R/smhome/data/charter.md; printf '# agents\n' > $R/smhome/AGENTS.md
printf '%s\n' "window=fmlive:fm-$ID" "endpoint_task_id=$ID" "worktree=$R/smhome" "project=$R/smhome" harness=claude \
  kind=secondmate mode=secondmate yolo=off model=default effort=default "home=$R/smhome" "projects=" > $R/home/state/$ID.meta
env -i HOME=$R/user-home PATH="$R/fb:/usr/local/bin:/usr/bin:/bin" TERM=xterm-256color SHELL=/bin/bash LANG=C.UTF-8 \
  FAKE_CLAUDE_LOG=$R/claude.log $R/fb/tmux new-session -d -s fmlive -n fm-$ID -c $R/smhome -x 160 -y 40 'bash --norc --noprofile'
sleep 0.5
# Legacy launch: the agent carries FM_HOME (its own home) and no FM_TASK_INBOX.
$R/fb/tmux send-keys -t fmlive:fm-$ID "FM_HOME=$R/smhome claude --dangerously-skip-permissions" Enter
sleep 1.5
C=$R/user-home/.claude; AGENT=$(jq -r .pid $C/sessions/*.json); SID=$(jq -r .sessionId $C/sessions/$AGENT.json)
echo "# S4: legacy second mate (pre-FM_TASK_INBOX launch, FM_HOME only, in its pane; private real tmux server)"
echo "agent pid $AGENT session $SID; Fleet env of the running agent:"; tr '\0' '\n' < /proc/$AGENT/environ | grep -E '^FM_' | sort
echo "pane root pid: $($R/fb/tmux display -p -t fmlive:fm-$ID '#{pane_pid}'), agent ppid: $(ps -o ppid= -p $AGENT | tr -d ' ')"
echo "\$ fm-control.sh $ID relaunch --resume-session $SID"
out=$("$EV/fm.sh" $R $W fm-control.sh $ID relaunch --resume-session $SID 2>&1); rc=$?
printf '%s\n' "$out" | grep -v -e '^fm-gate-refuse'; echo "rc=$rc"
sleep 2
echo "-> old agent $AGENT alive: $(kill -0 $AGENT 2>/dev/null && echo yes || echo no)"
echo "-> live session records:"; cat $C/sessions/*.json
echo "-> stand-in log:"; cat -v $R/claude.log
echo "-> transcript:"; cat $C/projects/*/$SID.jsonl
echo "-> charter untouched: $(cat $R/smhome/data/charter.md)"
echo "-> meta kind: $(grep ^kind= $R/home/state/$ID.meta)"
echo "-> operational inbox (no launch-brief doorbell): $(ls $R/home/state/operational-inbox 2>/dev/null | wc -l) messages"
echo "-> pane:"; $R/fb/tmux capture-pane -p -t fmlive:fm-$ID | head -4

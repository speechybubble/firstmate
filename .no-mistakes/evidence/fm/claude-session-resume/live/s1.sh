#!/usr/bin/env bash
# S1 driver: Fleet-launched worker, then exact-session resume relaunch.
EV=$(cd "$(dirname "$0")" && pwd); W=$1
R=$(mktemp -d /tmp/fmlive-a.XXXX); echo $R >> /tmp/fmlive-roots
"$EV/setup.sh" $R $W live1 ship >/dev/null
"$EV/fm.sh" $R $W fm-spawn.sh live1 --relaunch --harness claude 2>&1 | grep -v warning; sleep 2
SID=$(jq -r .sessionId $R/user-home/.claude/sessions/*.json); OLD=$(jq -r .pid $R/user-home/.claude/sessions/*.json)
echo "unfinished change" > $R/wt/wip.txt
echo "# S1: worker resumes its exact Claude session (private real tmux server; Fleet-launched agent pid $OLD owns session $SID)"
echo "\$ fm-control.sh live1 relaunch --resume-session $SID --note 'cutover restart'"
"$EV/fm.sh" $R $W fm-control.sh live1 relaunch --resume-session $SID --note "cutover restart" 2>&1; echo "rc=$?"
sleep 2
echo "--- old agent pid $OLD alive afterwards: $(kill -0 $OLD 2>/dev/null && echo yes || echo no)"
echo "--- live session records (sessions/*.json):"; cat $R/user-home/.claude/sessions/*.json
echo "--- transcript projects/*/$SID.jsonl (one file, both incarnations):"; ls $R/user-home/.claude/projects/*/; cat $R/user-home/.claude/projects/*/$SID.jsonl
echo "--- stand-in claude log (argv + Fleet env per incarnation):"; cat -v $R/claude.log
echo "--- state/live1.meta:"; cat $R/home/state/live1.meta
echo "--- journal phase/resume:"; grep -E '^(phase|resume_session|rollback)=' $R/home/state/live1.control-relaunch 2>/dev/null
echo "--- busy-state:"; cat $R/home/state/live1.busy-state
echo "--- worker busy/status hooks in worktree settings:"; jq -c '.hooks|keys' $R/wt/.claude/settings.local.json 2>&1
echo "--- worktree status (unfinished change kept):"; git -C $R/wt status --short
echo "--- operational-inbox messages (launch-brief doorbells):"; ls $R/home/state/operational-inbox
echo "--- pane:"; $R/fb/tmux capture-pane -p -t fmlive:fm-live1 | head -4

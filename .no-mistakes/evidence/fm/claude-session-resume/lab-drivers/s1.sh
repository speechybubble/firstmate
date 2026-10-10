#!/usr/bin/env bash
# s1.sh <id> <evidence-file>
id=$1; out=$2; LAB=/tmp/rsl/lab; export LAB; R=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M4K823EVWQRYWV0TRYDS48QG
cd /tmp/rsl
WT=$(sed -n 's/^worktree=//p' $LAB/home/state/$id.meta)
rec=$(grep -l "\"cwd\": \"$WT\"" $LAB/userhome/.claude/sessions/*.json | head -1)
SID=$(jq -r .sessionId $rec); OLD=$(jq -r .pid $rec)
./lab.sh ltmux send-keys -t firstmate:fm-$id -l 'remember the codeword AZURE-17'; ./lab.sh ltmux send-keys -t firstmate:fm-$id Enter
printf 'unfinished edit\n' >> $WT/README.md; echo wip > $WT/new-file.txt
sleep 1
{
echo "## exact-session relaunch over a real private tmux server (task $id)"
echo "\$ session before: $SID  (claude pid $OLD)"
echo "\$ old agent FM env:"; tr '\0' '\n' < /proc/$OLD/environ | grep -E '^FM_(TASK_ID|TASK_INBOX|HOME)='
echo "\$ git status (before):"; git -C $WT status --short
echo "\$ fm-control.sh $id relaunch --resume-session $SID --note 'cutover restart'"
./lab.sh labenv $R/bin/fm-control.sh $id relaunch --resume-session $SID --note 'cutover restart' 2>&1 | grep -v '^fm-gate-refuse'; echo "rc=${PIPESTATUS[0]}"
sleep 2
echo "\$ old pid $OLD alive?"; kill -0 $OLD 2>/dev/null && echo yes || echo no
echo "\$ live session records for $WT:"; grep -l "\"cwd\": \"$WT\"" $LAB/userhome/.claude/sessions/*.json | xargs cat; echo
NEW=$(jq -r .pid $(grep -l "\"cwd\": \"$WT\"" $LAB/userhome/.claude/sessions/*.json | head -1))
echo "\$ new agent FM env:"; tr '\0' '\n' < /proc/$NEW/environ | grep -E '^FM_(TASK_ID|TASK_INBOX|HOME|SUPERVISION_MODEL)='
echo "\$ new agent argv (resume part):"; tr '\0' '\n' < /proc/$NEW/cmdline | grep -A1 -- '--resume'
echo "\$ new agent argv contains a launch-brief doorbell?"; tr '\0' '\n' < /proc/$NEW/cmdline | grep -c 'Firstmate operational input waiting'
echo "\$ new agent argv contains worker trust contract (--append-system-prompt)?"; tr '\0' '\n' < /proc/$NEW/cmdline | grep -c -- '--append-system-prompt'
echo "\$ transcript $SID.jsonl (one conversation, appended across both processes):"
jq -c '{type,pid,resumed,restored_user_turns,text,brief_doorbell:(.brief_doorbell|length?)}' $LAB/userhome/.claude/projects/*/$SID.jsonl
echo "\$ transcripts in project dir:"; ls $LAB/userhome/.claude/projects/$(printf '%s' "$WT" | sed 's/[^A-Za-z0-9]/-/g')/
echo "\$ git status (after):"; git -C $WT status --short
echo "\$ pane:"; ./lab.sh ltmux capture-pane -p -t firstmate:fm-$id | grep -v '^$' | cut -c1-200 | tail -8
echo "\$ meta:"; grep -E '^(window|harness|kind|busy_gen|worktree)=' $LAB/home/state/$id.meta
[ -f $LAB/home/state/$id.busy-state ] && { echo "\$ busy-state:"; cat $LAB/home/state/$id.busy-state; }
G=$(sed -n 's/^busy_gen=//p' $LAB/home/state/$id.meta); [ -n "$G" ] && { echo "\$ worktree hooks carry new busy_gen $G:"; grep -c "$G" $WT/.claude/settings.local.json; }
echo "\$ relaunch journal:"; grep -hE '^(phase|resume_session|exit_result)=' $LAB/home/state/$id.control-relaunch 2>/dev/null
} 2>&1 | tee "$out"

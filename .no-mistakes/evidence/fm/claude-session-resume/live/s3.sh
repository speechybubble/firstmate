#!/usr/bin/env bash
# S3 driver: post-stop failure -> named recovery command -> exact resume.
EV=$(cd "$(dirname "$0")" && pwd); W=$1; R=$(tail -1 /tmp/fmlive-roots); C=$R/user-home/.claude
AGENT=$(jq -r .pid $C/sessions/*.json | head -1); SID=$(jq -r .sessionId $C/sessions/$AGENT.json)
echo "# S3: a failure after the stop names the exact-session recovery (agent pid $AGENT, session $SID)"
echo "(fixture: on /exit the stand-in leaves a detached child owning the session record for ~8s, so fm-spawn's 'released' check fails after the stop)"
touch $R/linger
echo "\$ fm-control.sh live1 relaunch --resume-session $SID --note 'cutover restart'"
out=$("$EV/fm.sh" $R $W fm-control.sh live1 relaunch --resume-session $SID --note "cutover restart" 2>&1); rc=$?
printf '%s\n' "$out" | grep -v -e '^fm-gate-refuse' -e '^warning:'; echo "rc=$rc"
rm -f $R/linger
echo "-> agent pid $AGENT alive: $(kill -0 $AGENT 2>/dev/null && echo yes || echo no)"
echo "-> any replacement started after the stop: $(grep -c '^=== start' $R/claude.log | awk '{print ($1>2)?"YES":"no"}')"
CMD=$(printf '%s\n' "$out" | sed -n 's/.*once no live process owns it, run: \(.*\); a plain relaunch.*/\1/p')
echo "-> named recovery command: $CMD"
echo
echo "## running the named command while the lingering owner still holds the session"
echo "\$ $CMD"
"$EV/fm.sh" $R $W ${CMD#$W/bin/} 2>&1 | grep -v -e '^fm-gate-refuse' -e '^warning:'; echo "rc=${PIPESTATUS[0]}"
echo "-> replacement started: $(grep -c '^=== start' $R/claude.log | awk '{print ($1>2)?"YES":"no"}')"
echo
echo "## waiting for the session to be released, then running the same named command"
for i in $(seq 1 30); do ls $C/sessions/*.json >/dev/null 2>&1 || break; sleep 1; done
echo "live session records: $(ls $C/sessions/ | wc -l)"
echo "\$ $CMD"
"$EV/fm.sh" $R $W ${CMD#$W/bin/} 2>&1 | grep -v -e '^fm-gate-refuse' -e '^warning:'; echo "rc=${PIPESTATUS[0]}"
sleep 2
echo "-> live session records:"; cat $C/sessions/*.json
echo "-> last incarnation in stand-in log:"; grep -A1 '^=== start' $R/claude.log | tail -2 | sed 's/\[--append-system-prompt\].*//'
echo "-> transcript (same file, all incarnations):"; cat $C/projects/*/$SID.jsonl
echo "-> worktree status:"; git -C $R/wt status --short
echo "-> pane:"; $R/fb/tmux capture-pane -p -t fmlive:fm-live1 | head -4

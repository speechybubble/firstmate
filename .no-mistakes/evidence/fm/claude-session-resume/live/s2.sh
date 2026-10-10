#!/usr/bin/env bash
# S2 driver: every refusal must happen before the task's agent is stopped.
EV=$(cd "$(dirname "$0")" && pwd); W=$1; R=$(tail -1 /tmp/fmlive-roots)
C=$R/user-home/.claude; WT=$R/wt
AGENT=$(jq -r .pid $(grep -l '"sessionId"' $C/sessions/*.json | head -1)); SID=$(jq -r .sessionId $C/sessions/$AGENT.json)
SLUG=$(cd $WT && pwd -P | sed 's/[^A-Za-z0-9]/-/g')
FOREIGN=()
foreign() {  # start a stand-in claude outside the endpoint, in <cwd>, with env + args
  local cwd=$1; shift
  ( cd "$cwd" && sleep infinity 2>/dev/null </dev/null | env -u FM_TASK_INBOX -u FM_TASK_ID -u FM_HOME HOME=$R/user-home CLAUDE_CONFIG_DIR= FAKE_CLAUDE_LOG=$R/foreign.log "$@" >/dev/null 2>&1 & )
  sleep 0.7
}
check() {  # <label> <session-id> [expect-substring]
  local label=$1 id=$2 before_meta exits_before starts_before out rc
  before_meta=$(sha1sum < $R/home/state/live1.meta)
  exits_before=$(grep -c '^input .*/exit' $R/claude.log); starts_before=$(grep -c '^=== start' $R/claude.log)
  echo; echo "## $label"
  echo "\$ fm-control.sh live1 relaunch --resume-session $id --note 'cutover restart'"
  out=$("$EV/fm.sh" $R $W fm-control.sh live1 relaunch --resume-session "$id" --note "cutover restart" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -v '^fm-gate-refuse'; echo "rc=$rc"
  echo "-> task agent pid $AGENT still alive: $(kill -0 $AGENT 2>/dev/null && echo yes || echo NO)"
  echo "-> /exit sent to agent: $([ "$(grep -c '^input .*/exit' $R/claude.log)" = "$exits_before" ] && echo no || echo YES)"
  echo "-> replacement launched: $([ "$(grep -c '^=== start' $R/claude.log)" = "$starts_before" ] && echo no || echo YES)"
  echo "-> state/live1.meta unchanged: $([ "$(sha1sum < $R/home/state/live1.meta)" = "$before_meta" ] && echo yes || echo NO)"
}
echo "# S2: refusals before any stop (task agent pid $AGENT, its session $SID)"
check "malformed id" "NOT-A-UUID"
check "missing: well-formed id with no transcript and no owner" "99999999-aaaa-4bbb-8ccc-dddddddddddd"
MIS=12345678-1234-4234-8234-123456789abc
printf '{"type":"user","sessionId":"%s"}\n' $MIS > $C/projects/$SLUG/$MIS.jsonl
check "mismatched: transcript in the worktree, but the running agent is on another conversation" $MIS
foreign $WT $R/fb/claude
FSID=$(jq -r --arg a "$AGENT" 'select((.pid|tostring)!=$a)|.sessionId' $C/sessions/*.json | head -1)
check "foreign same-worktree interactive claude (outside the endpoint tree, no Fleet env) owns the id" $FSID
foreign $WT env FM_TASK_ID=live1 $R/fb/claude
F2=$(jq -r --arg a "$AGENT" --arg f "$FSID" 'select((.pid|tostring)!=$a and .sessionId!=$f)|.sessionId' $C/sessions/*.json | head -1)
check "foreign same-worktree claude spoofing FM_TASK_ID=live1 outside the endpoint tree owns the id" $F2
foreign $WT env FM_TASK_INBOX=$R/home/state/other.inbox $R/fb/claude
F3=$(jq -r --arg a "$AGENT" --arg f "$FSID" --arg g "$F2" 'select((.pid|tostring)!=$a and .sessionId!=$f and .sessionId!=$g)|.sessionId' $C/sessions/*.json | head -1)
check "another task's agent (FM_TASK_INBOX of task 'other') owns the id" $F3
foreign $WT $R/fb/claude --resume $SID
check "already owned: a second live process also holds the task agent's own session" $SID
echo; echo "--- live session records at end:"; cat $C/sessions/*.json
for p in $(jq -r --arg a "$AGENT" 'select((.pid|tostring)!=$a)|.pid' $C/sessions/*.json); do kill $p; done
pkill -f "^sleep infinity$" 2>/dev/null; true

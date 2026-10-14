#!/usr/bin/env bash
# Lab driver: one scenario per invocation against a real tmux pane on the lab's
# private socket, the real fm-watch.sh, real fm-crew-state.sh, real fm-procevent.sh
# and real fm-wake-drain.sh. Emulates the supervisor loop: run the watcher, drain
# and ack every wake it queues, relaunch, while the worker pane churns.
# Usage: drive.sh <scenario> <status-line> <pr|nopr> <board:none|live|foreign|captured|dead> <secs>
set -u
ROOT=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M4W1TPP3HW89S3CBBRYZ306R
. /tmp/fm-lab-current.env
export TMUX_TMPDIR=$TD
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
name=$1 line=$2 pr=$3 board=$4 secs=$5
task=held-merge
win=lab:fm-$task
S=$LAB/state
log=$LAB/run-$name.log
: > "$log"
say() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$log"; }

# fresh state for this scenario (keep the lab marker files)
tmux kill-server 2>/dev/null || true
find "$S" -mindepth 1 -not -name '.fm-lab-tmux-dir' -exec rm -rf {} + 2>/dev/null
rm -rf "$LAB/claims"; chmod 700 "$S"
mkdir -p "$LAB/projects/demo-wt"
if [ "${WEDGE:-0}" = 1 ]; then
  tmux new-session -d -s lab -n "fm-$task" -x 120 -y 30 bash --norc --noprofile
else
  tmux new-session -d -s lab -n "fm-$task" -x 120 -y 30 bash --norc --noprofile
fi
mkdir -p "$LAB/projects/demo-wt"; printf "window=%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\nproject=demo\nendpoint_task_id=%s\n" "$win" "$LAB/projects/demo-wt" "$task" > "$S/$task.meta"
[ "$pr" = pr ] && printf 'pr=https://example.invalid/pull/42\n' >> "$S/$task.meta"
printf '%s\n' "$line" > "$S/$task.status"

pe() { "$ROOT/bin/fm-procevent.sh" "$@"; }
if [ "$board" = foreign ]; then
  tmux new-window -d -t lab -n fm-other-task bash --norc --noprofile
  mkdir -p "$LAB/projects/other-wt"
  printf "window=lab:fm-other-task\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\nproject=demo\nendpoint_task_id=other-task\n" "$LAB/projects/other-wt" > "$S/other-task.meta"
  printf 'working: reviewing on its own board\n' > "$S/other-task.status"
fi
case "$board" in
  live|captured) owner=$task ;;
  foreign) owner=other-task ;;
  dead) owner=$task ;;
esac
case "$board" in
  live|foreign|captured)
    pe register-task lavish lab-board "$owner" -- /bin/sh -c 'sleep 900' >>"$log" 2>&1 || say "register-task failed"
    FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 pe reconcile >>"$log" 2>&1
    ;;
  dead)
    pe register-task lavish lab-board "$owner" -- /bin/sh -c 'exit 3' >>"$log" 2>&1 || say "register-task failed"
    ;;
esac
if [ "$board" = captured ]; then
  # a real captured round: the runner's child exits with a result. Re-register the
  # source with a child that prints a result and exits, so the runner captures it.
  pe retire lab-board >>"$log" 2>&1
  pe register-task lavish lab-board "$owner" -- /bin/sh -c 'printf "session:\n  status: feedback\n"' >>"$log" 2>&1
  FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 pe reconcile >>"$log" 2>&1
  sleep 3
fi
say "procevent list:"; pe list 2>&1 | tee -a "$log"
ls -la "$S/procevent" "$S/procevent-inbox" 2>/dev/null >>"$log"

end=$(( $(date +%s) + secs ))
tick=0
churn() {
  while [ "$(date +%s)" -lt "$end" ]; do
    tick=$((tick + 1))
    tmux send-keys -t "$win" "echo worker idle tick $tick" Enter
    sleep 7
  done
}
if [ "${WEDGE:-0}" = 1 ]; then
  "$ROOT/bin/fm-busy-event.sh" arm "$S" "$task" --state busy >/dev/null
  export FM_STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-20} FM_BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-15}
  sleep 10; tmux capture-pane -p -t "$win" | grep -v "^$" | tail -6 >> "$log"
  churn_pid=
  say "crew-state: $("$ROOT/bin/fm-crew-state.sh" "$task")"
else
  churn &
  churn_pid=$!
fi
wakes=0
while [ "$(date +%s)" -lt "$end" ]; do
  rem=$(( end - $(date +%s) ))
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCH_HANDLING_SUCCESSOR=1 \
    timeout "$rem" "$ROOT/bin/fm-watch.sh" >> "$LAB/watch-$name.out" 2>&1
  rc=$?
  [ "$rc" -eq 124 ] && break
  err=$(mktemp)
  out=$("$ROOT/bin/fm-wake-drain.sh" 2>"$err")
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  say "WAKE (watcher rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
  case "$out" in *"stale: lab:fm-held-merge"*) wakes=$((wakes + 1)) ;; esac
  [ -n "$seq" ] && "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  sleep 1
done
[ -n "$churn_pid" ] && kill "$churn_pid" 2>/dev/null; wait 2>/dev/null
say "RESULT $name: stale wakes surfaced to supervisor in ${secs}s of pane churn = $wakes"
say "triage log (stale lines):"
grep -iE 'stale|wedge|defer' "$S/.watch-triage.log" 2>/dev/null | sed 's/^/    /' | tail -15 | tee -a "$log"
say "pane:"; tmux capture-pane -p -t "$win" | grep -v '^$' | tail -4 | tee -a "$log"
pe retire lab-board >/dev/null 2>&1
tmux kill-server 2>/dev/null || true

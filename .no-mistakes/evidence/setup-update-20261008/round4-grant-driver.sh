#!/usr/bin/env bash
set -eu
unset NODE_OPTIONS
root="$PWD"
export PATH="$root/.live/node/node_modules/.bin:$PATH"
export FM_HOME="$root/.live/grants"
"$root/bin/fm-lab-home.sh" create "$FM_HOME"
mkdir -p "$FM_HOME/projects/demo"
printf 'project=%s\nwindow=fm-held\n' "$FM_HOME/projects/demo" > "$FM_HOME/state/held.meta"
printf 'project=%s\nwindow=fm-routine\n' "$FM_HOME/projects/demo" > "$FM_HOME/state/routine.meta"
"$root/bin/fm-captain-hold.sh" hold held --title 'Disposable held task' --reason 'Captain review required'
printf '1\t1\tsignal\theld.turn-ended\tsignal: held.turn-ended\n2\t2\tsignal\troutine.status\tsignal: routine.status\n' > "$FM_HOME/state/.wake-queue"
printf 'working: ordinary update\n' > "$FM_HOME/state/routine.status"
cp "$FM_HOME/state/.wake-queue" "$FM_HOME/queue.before"
for mode in attended away; do
 args=(); [ "$mode" != away ] || args=(--afk)
 echo "=== $mode held trigger ==="
 printf 'signal: held.turn-ended\n' | node "$root/bin/fm-branch-dispatch.mjs" offer "${args[@]}"
 echo "=== $mode independent routine trigger ==="
 printf 'signal: routine.status\n' | node "$root/bin/fm-branch-dispatch.mjs" offer "${args[@]}"
done
grant="$root/bin/fm-wake-grant.sh"
"$grant" activate "$$" live-grant
check_reject() {
 local rc=0
 "$grant" publish "$@" || rc=$?
 echo "publication $*: exit=$rc"
 [ "$rc" -ne 0 ]; [ ! -f "$FM_HOME/state/.branch-eligible-rows" ]
 cmp "$FM_HOME/queue.before" "$FM_HOME/state/.wake-queue"
 echo 'grant absent; unread queue unchanged'
}
check_reject live-grant --tasks held --rows 1
check_reject live-grant --tasks routine --rows 99
check_reject stale-owner --tasks routine --rows 2
"$grant" publish live-grant --tasks routine --rows 2
echo "valid routine grant=$(< "$FM_HOME/state/.branch-eligible-rows")"
"$grant" release live-grant
"$root/bin/fm-captain-hold.sh" hold routine --title 'Routine now held' --reason 'Late captain hold'
check_reject live-grant --tasks routine --rows 2
"$grant" deactivate "$$" live-grant
cmp "$FM_HOME/queue.before" "$FM_HOME/state/.wake-queue"
echo 'Final queue: both unread rows preserved, including held task without status file'

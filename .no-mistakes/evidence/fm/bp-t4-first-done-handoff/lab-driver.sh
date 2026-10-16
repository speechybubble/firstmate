#!/usr/bin/env bash
# Runs inside the lab tmux pane: builds ship tasks and reads them through the real scripts.
set -u
ROOT=$1; LAB=$FM_HOME; export NM_HOME="$LAB/nmhome" FM_CREW_STATE_NO_FORGE=1
. "$ROOT/bin/fm-meta-lib.sh" 2>/dev/null || true
mk() {  # <id> <kind> <mode> <status-line>
  local id=$1 kind=$2 mode=$3 line=$4 wt="$LAB/projects/$1"
  git init -q -b main "$wt"; git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$wt" checkout -q -b "fm/$id"; git -C "$wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'the fix'
  git -C "$wt" update-ref "refs/remotes/origin/fm/$id" HEAD
  tmux new-window -d -t fm: -n "fm-$id" bash
  { echo "window=fm:fm-$id"; echo "worktree=$wt"; echo "project=$wt"; echo "kind=$kind"
    [ -z "$mode" ] || echo "mode=$mode"; echo "harness=claude"; } > "$LAB/state/$id.meta"
  printf '%s\n' "$line" > "$LAB/state/$id.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop >/dev/null
}
mk nmhandoff ship no-mistakes "done: implementation committed on fm/nmhandoff; stopping until told to run /no-mistakes"
mk nomode ship "" "done: implementation committed"
mk nmgreen ship no-mistakes "done: PR https://github.com/o/r/pull/5 checks green"
mk nmprnote ship no-mistakes "done: PR https://github.com/o/r/pull/6"
mk directpr ship direct-PR "done: PR https://github.com/o/r/pull/7"
mk localonly ship local-only "done: ready in branch fm/localonly"
mk scoutdone scout no-mistakes "done: report written"
mk nmworking ship no-mistakes "working: implementing"
sleep 1
for id in nmhandoff nomode nmgreen nmprnote directpr localonly scoutdone nmworking; do
  printf '%-10s live:    %s\n' "$id" "$("$ROOT/bin/fm-crew-state.sh" "$id" 2>&1)"
done
printf '%-10s history: %s\n' nmhandoff "$(FM_CREW_STATE_HISTORY_ONLY=1 "$ROOT/bin/fm-crew-state.sh" nmhandoff 2>&1)"
"$ROOT/bin/fm-fleet-snapshot.sh" --json > "$LAB/driver/snapshot.json" 2>"$LAB/driver/snapshot.err"; echo "snapshot rc=$?"
echo DRIVE-DONE

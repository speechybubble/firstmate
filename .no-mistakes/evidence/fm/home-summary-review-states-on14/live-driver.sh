#!/usr/bin/env bash
# Live driver: disposable homes, real fm-fleet-snapshot / fm-home-summary-refresh / fm-bearings-snapshot.
set -u
ROOT=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M4P37KQE0EE5BSDK47TFCQPW
EV=/home/denni/.no-mistakes/evidence/01M4P37KQE0EE5BSDK47TFCQPW
W=$(mktemp -d /tmp/nmlive.XXXXXX)
trap 'rm -rf "$W"' EXIT
HOME_C=$W/child; FB=$W/fakebin
mkdir -p "$HOME_C"/{state,data,projects,config,nm} "$FB"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "no-mistakes $*" >> "$NM_CALL_LOG"
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
f="$FM_CHILD_HOME/nm/${branch//\//_}"
case "$*" in
  axi) cat "$f.overview" 2>/dev/null ;;
  "axi status"*) cat "$f.status" 2>/dev/null ;;
esac
exit 0
SH
# forge: pull/31 OPEN, pull/13 MERGED, pull/32 CLOSED, anything else unreadable
cat > "$FB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$NM_CALL_LOG"
case "$*" in
  *number=31*) printf 'state=OPEN\nmerged=false\n'; exit 0 ;;
  *number=13*) printf 'state=MERGED\nmerged=true\n'; exit 0 ;;
  *number=32*) printf 'state=CLOSED\nmerged=false\n'; exit 0 ;;
esac
exit 1
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/tmux"
chmod +x "$FB"/*
export NM_CALL_LOG=$W/calls.log FM_CHILD_HOME=$HOME_C
: > "$NM_CALL_LOG"

child() {  # <id> <outcome> <status-line> [<pr>]
  local id=$1 outcome=$2 line=$3 pr=${4:-} wt=$HOME_C/projects/$1 head gen
  mkdir -p "$wt"; git -C "$wt" init -q
  git -C "$wt" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b "fm/$id"; head=$(git -C "$wt" rev-parse HEAD)
  printf 'run:\n  id: "01%s"\n  branch: fm/%s\n  status: completed\n  head: "%s"\n  head_sha: "%s"\n  pr: "%s"\n  findings: none\noutcome: %s\n' \
    "$id" "$id" "$head" "$head" "$pr" "$outcome" > "$HOME_C/nm/fm_$id.status"
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "01%s",fm/%s,completed,%s,""\n' "$id" "$id" "${head:0:8}" > "$HOME_C/nm/fm_$id.overview"
  { printf 'window=firstmate:fm-%s\nworktree=%s\nproject=alpha\nharness=claude\nkind=ship\nmode=no-mistakes\n' "$id" "$wt"
    [ -z "$pr" ] || printf 'pr=%s\n' "$pr"; } > "$HOME_C/state/$id.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_C/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_C/state" "$id" idle --gen "$gen" --source claude-hook --event stop
  printf '%s\n' "$line" > "$HOME_C/state/$id.status"
}
cat > "$HOME_C/data/backlog.md" <<'EOF'
## In flight
- [ ] ready - Ready for review (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] passed-open - Run passed with PR open (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] paused-failed - Paused after a failed run (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] held-failed - Held after a failed run (repo: alpha) (kind: ship) (hold: keep stopped until release) (hold-kind: captain) (since 2026-10-01)
- [ ] merged - Passed, PR already merged (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] closed - Passed, PR closed (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] unproven - Passed, PR unreadable (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] no-pr - Ready for review, no recorded PR (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] failed-open - Failed, no hold, no wait (repo: alpha) (kind: ship) (since 2026-10-01)

## Queued

## Done
EOF
child ready checks-passed 'working: validating' https://github.com/o/r/pull/11
child passed-open passed 'working: validating' https://github.com/o/r/pull/31
child paused-failed failed 'paused: custody accepted, waiting for release'
child held-failed failed 'working: validating'
child merged passed 'working: validating' https://github.com/o/r/pull/13
child closed passed 'working: validating' https://github.com/o/r/pull/32
child unproven passed 'working: validating' https://github.com/o/r/pull/12
child no-pr checks-passed 'working: validating'
child failed-open failed 'working: validating'

export PATH="$FB:$PATH"
cd "$W"
echo "=== S1: home with expected states AND real contradictions (default settings) ==="
env -u FM_SNAPSHOT_CREW_STATE_TIMEOUT FM_HOME="$HOME_C" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary \
  | jq '{valid,state,reason,invalidity,awaiting_merge,held_failed_runs,counts:(.counts|{awaiting_merge,held_failed_runs,active_children})}' | tee "$EV/s1-mixed-summary.json"

echo "=== S2: contradictions removed -> valid summary ==="
for id in merged closed unproven no-pr failed-open; do rm -f "$HOME_C/state/$id."*; done
grep -Ev '^- \[ \] (merged|closed|unproven|no-pr|failed-open) ' "$HOME_C/data/backlog.md" > "$W/b" && mv "$W/b" "$HOME_C/data/backlog.md"
env -u FM_SNAPSHOT_CREW_STATE_TIMEOUT FM_HOME="$HOME_C" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary \
  | jq '{schema,valid,state,reason,invalidity,awaiting_merge,held_failed_runs,counts:(.counts|{awaiting_merge,held_failed_runs}),omitted}' | tee "$EV/s2-valid-summary.json"

echo "=== S3: real refresh publishes the ledger ==="
FM_HOME="$HOME_C" "$ROOT/bin/fm-home-summary-refresh.sh"; echo "refresh rc=$?"
jq '{valid,state,awaiting:[.awaiting_merge[].id],held:[.held_failed_runs[].id]}' "$HOME_C/state/home-summary.json" | tee "$EV/s3-published-ledger.json"

echo "=== S4: parent fleet snapshot + bearings through a local secondmate ==="
P=$W/parent; mkdir -p "$P"/{state,data,projects,config}
mkdir -p "$HOME_C/bin"; printf '# Firstmate fixture\n' > "$HOME_C/AGENTS.md"; printf 'mate\n' > "$HOME_C/.fm-secondmate-home"
printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: alpha; added 2026-10-01)\n' "$HOME_C" > "$P/data/secondmates.md"
printf '## In flight\n- [ ] mate - Child home (kind: secondmate) (since 2026-10-01)\n\n## Queued\n\n## Done\n' > "$P/data/backlog.md"
printf 'window=firstmate:fm-mate\nendpoint_task_id=mate\nworktree=%s\nproject=%s\nharness=echo\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n' "$HOME_C" "$HOME_C" "$HOME_C" > "$P/state/mate.meta"
FM_HOME="$P" "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$W/parent.json"; echo "parent snapshot rc=$?"
jq '.secondmate_current.records[] | {id,current,provenance:.provenance.selected,awaiting_merge,held_failed_runs,counts:(.counts|{awaiting_merge,held_failed_runs})}' "$W/parent.json" | tee "$EV/s4-parent-record.json"
FM_HOME="$P" "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$W/bearings.json"; echo "bearings rc=$?"
jq '{secondmates:[.secondmates[]|{id,state,doing}],in_flight:[.in_flight[]|{id,state,doing}]}' "$W/bearings.json" | tee "$EV/s4-bearings.json"
FM_HOME="$P" "$ROOT/bin/fm-bearings-snapshot.sh" > "$EV/s4-bearings-human.txt" 2>&1; echo "bearings human rc=$?"
cat "$EV/s4-bearings-human.txt"

echo "=== S5: no merge / mutation was ever invoked ==="
sort -u "$NM_CALL_LOG" | tee "$EV/s5-external-calls.txt"
grep -Eq '^gh pr (merge|edit|close|review|ready)|^gh api .*(-X|--method) *(PUT|POST|PATCH|DELETE)|mutation|^no-mistakes .*(respond|approve|merge)' "$NM_CALL_LOG" && echo "MUTATION FOUND" || echo "no merge or mutating forge call"

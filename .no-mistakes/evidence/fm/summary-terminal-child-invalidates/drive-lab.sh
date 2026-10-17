#!/usr/bin/env bash
# Live drive: real fm-home-summary-refresh / fm-fleet-snapshot / fm-bearings-snapshot /
# fm-secondmate-reconcile against a disposable lab parent home with one registered
# secondmate home holding a finished scout and a failed ship under in-flight items.
# Usage: drive-lab.sh <repo-root> <variant: finished|finished+unknown>
set -u
ROOT=$1 VARIANT=$2
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB="$BASE/parent"; mkdir -p "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export TMUX_TMPDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB"); unset TMUX TMUX_PANE
MATE="$BASE/mate-home"
mkdir -p "$MATE/state" "$MATE/data" "$MATE/config" "$MATE/projects/finished-scout" "$MATE/projects/bp-t8" "$MATE/bin" "$MATE/data/finished-scout"
printf '# Firstmate lab\n' > "$MATE/AGENTS.md"; printf 'ops\n' > "$MATE/.fm-secondmate-home"
printf -- '- ops - lab domain (home: %s; scope: lab; projects: alpha; added 2026-10-17)\n' "$MATE" > "$LAB/data/secondmates.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
cat > "$MATE/data/backlog.md" <<'B'
## In flight
- [ ] finished-scout - Finished scout (repo: alpha) (kind: scout) (since 2026-10-12)
- [ ] bp-t8 - Listener truth (repo: alpha) (kind: ship) (since 2026-10-16)

## Queued

## Done
B
printf '# Report\n' > "$MATE/data/finished-scout/report.md"
printf 'window=firstmate:fm-finished-scout\nworktree=%s\nproject=alpha\nharness=claude\nkind=scout\nmode=scout\n' "$MATE/projects/finished-scout" > "$MATE/state/finished-scout.meta"
printf 'done: report at data/finished-scout/report.md\n' > "$MATE/state/finished-scout.status"
for id in finished-scout bp-t8; do g=$("$ROOT/bin/fm-busy-event.sh" arm "$MATE/state" "$id"); "$ROOT/bin/fm-busy-event.sh" apply "$MATE/state" "$id" idle --gen "$g" --source claude-hook --event stop; done
printf 'window=firstmate:fm-bp-t8\nworktree=%s\nproject=alpha\nharness=claude\nkind=ship\nmode=no-mistakes\n' "$MATE/projects/bp-t8" > "$MATE/state/bp-t8.meta"
printf 'failed: validation run died in machine restart\n' > "$MATE/state/bp-t8.status"
if [ "$VARIANT" = "finished+unknown" ]; then
  sed -i '/^## In flight$/a\
- [ ] lost - Child lost in a machine restart (repo: alpha) (kind: ship) (since 2026-10-16)' "$MATE/data/backlog.md"
  mkdir -p "$MATE/projects/lost"
  printf 'window=firstmate:dead-lost\nworktree=%s\nproject=alpha\nharness=codex\nkind=ship\nmode=no-mistakes\n' "$MATE/projects/lost" > "$MATE/state/lost.meta"
fi
tmux -L default new-session -d -s firstmate -n fm-finished-scout "sleep 600"; tmux -L default new-window -d -t firstmate -n fm-bp-t8 "sleep 600"
echo "tmux windows: $(tmux -L default list-windows -a -F '#S:#W' | tr '\n' ' ')"
echo "== secondmate home summary (fm-home-summary-refresh.sh, then --secondmate-home-summary)"
FM_HOME="$MATE" "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null 2>&1; echo "refresh rc=$?"
FM_HOME="$MATE" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary \
  | jq '{valid,reason,invalidity,reconcile_inventory,state,awaiting_firstmate,counts:{awaiting_firstmate:.counts.awaiting_firstmate}}'
echo "== parent fleet snapshot record for ops"
SNAP=$(FM_HOME="$LAB" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf '%s' "$SNAP" | jq '.secondmate_current.records[] | select(.id=="ops")
  | {current,invalidity,reconcile_inventory,trust:.provenance.trust,summary_valid:.provenance.summary_valid,awaiting_firstmate:[.awaiting_firstmate[]?|{id,kind,outcome}]}'
echo "== bearings (captain view) TOON"
FM_HOME="$LAB" "$ROOT/bin/fm-bearings-snapshot.sh" 2>&1 | sed -n '1,60p'
echo "== bearings JSON: ops home row and its in_flight rows"
FM_HOME="$LAB" "$ROOT/bin/fm-bearings-snapshot.sh" --json | jq '{secondmate:[.secondmates[]?|select(.id=="ops")], in_flight:[.in_flight[]?|select(.id|startswith("ops/"))]}'
echo "== reconcile request from the captured snapshot"
printf '%s' "$SNAP" | FM_HOME="$LAB" "$ROOT/bin/fm-secondmate-reconcile.sh" request --snapshot -; echo "reconcile rc=$?"
ls "$LAB/state/reconcile-notify" 2>/dev/null
tmux -L default kill-server 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$BASE"; echo "lab removed: $([ -e "$BASE" ] && echo no || echo yes)"

#!/usr/bin/env bash
# Live drive: rebased pipeline runs (context shift, conflict resolution) and merged-branch guard.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_SHIP_CHECKS_REGISTRY="$LAB/registry"
GATE_CMD=$(python3 -c 'import yaml,sys;print([g for g in yaml.safe_load(open(sys.argv[1]))["gates"] if g["name"]=="task-checks"][0]["command"])' "$WT/.no-mistakes.yaml")
run_gate() { ( cd "$1" && bash -c "$GATE_CMD" ); echo "gate exit=$?"; }
git clone -q --bare --no-local "$WT" "$LAB/origin.git" 2>/dev/null
git -C "$LAB/origin.git" update-ref refs/heads/main "$(git -C "$WT" rev-parse HEAD)"
git clone -q -b main "$LAB/origin.git" "$LAB/p"; P="$LAB/p"
git -C "$P" config user.email ship@example.com; git -C "$P" config user.name ship
git init -q --bare -b main "$LAB/gate.git"; G="$LAB/gate.git"
git -C "$G" remote add origin "$LAB/origin.git"
fetchmain() { git -C "$G" fetch -q origin '+refs/heads/main:refs/remotes/origin/main'; }
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\n' > "$P/notes.txt"; git -C "$P" add notes.txt; git -C "$P" commit -qm notes; git -C "$P" push -q origin main 2>/dev/null; fetchmain
cat > "$LAB/brief.md" <<'B'
# Task
<!-- fm-brief: task-slots v4 -->
## Captain's intent
Make the ad.

## Firstmate spec
Build it.

## Checks
```json
[{"id":"names-the-trade","source":"captain: speak to plumbers","type":"contains","target":"ad.txt","pattern":"[Pp]lumb","good":"For plumbers.","bad":"For everyone."}]
```

# Definition of done
Done.
B
mkship() {  # <id> ; registers a ship with the admitted record
  "$WT/bin/fm-checks.sh" validate "$LAB/brief.md" --kind ship --admit "$LAB/state/$1.checks.json" >/dev/null || echo "validate failed"
  printf 'kind=ship\nmode=no-mistakes\nbranch=fm/%s\nchecks=1\nchecks_sha=%s\n' "$1" "$(sha256sum "$LAB/state/$1.checks.json" | awk '{print $1}')" > "$LAB/state/$1.meta"
  "$WT/bin/fm-checks.sh" register "$LAB/state" "$1"
}
echo "### S4a: ship edits line 4; main later edits line 2 (inside the ship hunk's context); pipeline rebase replays cleanly"
git -C "$P" checkout -qb fm/ctx
sed 's/^four$/four ship/' "$P/notes.txt" > "$P/n" && mv "$P/n" "$P/notes.txt"; printf 'For everyone.\n' > "$P/ad.txt"
git -C "$P" add -A; git -C "$P" commit -qm 'ship: ad and notes'; C1=$(git -C "$P" rev-parse HEAD)
mkship ctx; git -C "$P" push -q "$G" fm/ctx 2>/dev/null
git -C "$P" checkout -q main; sed 's/^two$/two base/' "$P/notes.txt" > "$P/n" && mv "$P/n" "$P/notes.txt"; git -C "$P" commit -qam 'base edits line two'; git -C "$P" push -q origin main 2>/dev/null; fetchmain
git -C "$G" worktree add -q --detach "$LAB/run-ctx" "$C1" 2>/dev/null
git -C "$LAB/run-ctx" -c user.email=nm@example.com -c user.name=nm rebase -q refs/remotes/origin/main && echo "rebase ok (no conflict)"
echo "ship patch-id    $(git -C "$P" diff-tree -p "$C1" | git patch-id --stable | cut -c1-12)"
echo "rebased patch-id $(git -C "$LAB/run-ctx" diff-tree -p HEAD | git patch-id --stable | cut -c1-12)"
echo "run head is new commit: $( [ "$(git -C "$LAB/run-ctx" rev-parse HEAD)" != "$C1" ] && echo yes)"
run_gate "$LAB/run-ctx"
echo
echo "### S4b: ship edits line 6; main edits line 6 too; the pipeline rebase resolves the conflict"
git -C "$P" checkout -qb fm/conf
sed 's/^six$/six ship/' "$P/notes.txt" > "$P/n" && mv "$P/n" "$P/notes.txt"; printf 'For everyone.\n' > "$P/ad.txt"
git -C "$P" add -A; git -C "$P" commit -qm 'ship: ad and six'; C2=$(git -C "$P" rev-parse HEAD)
mkship conf; git -C "$P" push -q "$G" fm/conf 2>/dev/null
git -C "$P" checkout -q main; sed 's/^six$/six base/' "$P/notes.txt" > "$P/n" && mv "$P/n" "$P/notes.txt"; git -C "$P" commit -qam 'base edits six'; git -C "$P" push -q origin main 2>/dev/null; fetchmain
git -C "$G" worktree add -q --detach "$LAB/run-conf" "$C2" 2>/dev/null
git -C "$LAB/run-conf" -c user.email=nm@example.com -c user.name=nm rebase -q refs/remotes/origin/main >/dev/null 2>&1 && echo "unexpected: no conflict" || echo "rebase conflicted; resolving"
sed -e '/^<<<<<<<\|^=======\|^>>>>>>>/d' -e 's/^six base$//' "$LAB/run-conf/notes.txt" | sed '/^$/d' > "$LAB/n"; mv "$LAB/n" "$LAB/run-conf/notes.txt"
git -C "$LAB/run-conf" add notes.txt; GIT_EDITOR=true git -C "$LAB/run-conf" -c user.email=nm@example.com -c user.name=nm rebase --continue >/dev/null 2>&1 && echo "conflict resolved, rebase continued"
echo "rebased head subject/author: $(git -C "$LAB/run-conf" log -1 --format='%s | %ae | %at') vs ship $(git -C "$P" log -1 --format='%s | %ae | %at' "$C2")"
run_gate "$LAB/run-conf"
echo
echo "### S4c (guard): a ship branch fully merged into main binds no later unrelated run"
git -C "$P" checkout -q main; git -C "$P" merge -q --ff-only fm/conf 2>/dev/null || git -C "$P" merge -q --no-edit -X ours fm/conf >/dev/null 2>&1; git -C "$P" push -q origin main 2>/dev/null; fetchmain
git -C "$P" checkout -qb unrelated; printf 'u\n' > "$P/u.txt"; git -C "$P" add u.txt; git -C "$P" commit -qm unrelated; git -C "$P" push -q "$G" unrelated 2>/dev/null
git -C "$G" worktree add -q --detach "$LAB/run-u" "$(git -C "$P" rev-parse HEAD)" 2>/dev/null
run_gate "$LAB/run-u"

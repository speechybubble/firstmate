#!/usr/bin/env bash
# Live drive of the task-checks gate exactly as no-mistakes invokes it.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_SHIP_CHECKS_REGISTRY="$LAB/registry"
GATE_CMD=$(yq -r '.gates[] | select(.name=="task-checks") | .command' "$WT/.no-mistakes.yaml" 2>/dev/null || python3 -c 'import yaml,sys;print([g for g in yaml.safe_load(open(sys.argv[1]))["gates"] if g["name"]=="task-checks"][0]["command"])' "$WT/.no-mistakes.yaml")
AFTER=$(python3 -c 'import yaml,sys;print([g for g in yaml.safe_load(open(sys.argv[1]))["gates"] if g["name"]=="task-checks"][0]["after"])' "$WT/.no-mistakes.yaml")
echo "### .no-mistakes.yaml gate task-checks: after=$AFTER command=$GATE_CMD"
# Project origin = a clone of this Firstmate repo at the change under test.
git clone -q --bare --no-local "$WT" "$LAB/origin.git" 2>/dev/null
git -C "$LAB/origin.git" update-ref refs/heads/main "$(git -C "$WT" rev-parse HEAD)"
git clone -q -b main "$LAB/origin.git" "$LAB/project"
git -C "$LAB/project" config user.email ship@example.com; git -C "$LAB/project" config user.name ship
# Gate repo: what no-mistakes keeps, fetching origin main.
git init -q --bare -b main "$LAB/gate.git"
git -C "$LAB/gate.git" remote add origin "$LAB/origin.git"
git -C "$LAB/gate.git" fetch -q origin '+refs/heads/main:refs/remotes/origin/main'
# Real brief scaffold with real checks slot, validated/admitted by the real validator.
FM_HOME="$LAB" "$WT/bin/fm-brief.sh" ad-ship proj --mode no-mistakes >/dev/null 2>&1 || echo "WARN brief scaffold failed"
BRIEF="$LAB/data/ad-ship/brief.md"
python3 - "$BRIEF" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
block='```json\n[{"id":"names-the-trade","source":"captain: the ad must speak to plumbers, not everyone","type":"contains","target":"ad.txt","pattern":"([Pp]lumb|HVAC)","good":"For plumbers who lose jobs to slow quotes.","bad":"For every business in every industry."},\n {"id":"no-hype","source":"captain: no hype words","type":"not-contains","target":"ad.txt","pattern":"revolutionary","good":"Quotes in minutes.","bad":"A revolutionary quoting tool."},\n {"id":"click-works","source":"captain: Apply must work","type":"assertions","assertions":["apply-ok"],"good":"apply-ok\\tpass\\n","bad":"apply-ok\\tfail\\tboom\\n"}]\n```'
s=s.replace('{CHECKS}',block)
open(p,'w').write(s)
PY
echo "### validate --admit (spawn's admission step)"
"$WT/bin/fm-checks.sh" validate "$BRIEF" --kind ship --admit "$LAB/state/ad-ship.checks.json"; echo "validate exit=$?"
SHA=$(sha256sum "$LAB/state/ad-ship.checks.json" | awk '{print $1}')
printf 'kind=ship\nmode=no-mistakes\nbranch=fm/ad-ship\nworktree=%s\nchecks=3\nchecks_sha=%s\n' "$LAB/project" "$SHA" > "$LAB/state/ad-ship.meta"
"$WT/bin/fm-checks.sh" register "$LAB/state" ad-ship; echo "register exit=$?"; echo "registry:"; cat "$LAB/registry"/*.ship
# Ship work: a bad ad the reviewer might accept as plausible.
git -C "$LAB/project" checkout -qb fm/ad-ship
printf 'A revolutionary tool for every business in every industry.\n' > "$LAB/project/ad.txt"
git -C "$LAB/project" add ad.txt && git -C "$LAB/project" commit -qm 'write the ad'
git -C "$LAB/project" push -q "$LAB/gate.git" fm/ad-ship 2>/dev/null
run_gate() { ( cd "$1" && bash -c "$GATE_CMD" ); }
echo; echo "### S1: pipeline run of the ship with failing task checks (run worktree detached at ship head)"
git -C "$LAB/gate.git" worktree add -q --detach "$LAB/run" "$(git -C "$LAB/project" rev-parse HEAD)" 2>/dev/null
run_gate "$LAB/run"; echo "gate exit=$?"
echo; echo "### S2: pipeline fix commit satisfies the checks"
printf 'For plumbers who lose jobs to slow quotes.\n' > "$LAB/run/ad.txt"
echo "(uncommitted fix only)"; run_gate "$LAB/run"; echo "gate exit=$?"
git -C "$LAB/run" -c user.email=nm@example.com -c user.name=nm commit -qam 'pipeline fix: name the trade'
echo "(committed fix)"; run_gate "$LAB/run"; echo "gate exit=$?"
echo; echo "### S3: an unrelated pipeline run in the same gate repo binds no ship"
git -C "$LAB/project" checkout -q main; git -C "$LAB/project" checkout -qb other
printf 'x\n' > "$LAB/project/other.txt"; git -C "$LAB/project" add other.txt; git -C "$LAB/project" commit -qm other
git -C "$LAB/project" push -q "$LAB/gate.git" other 2>/dev/null
git -C "$LAB/gate.git" worktree add -q --detach "$LAB/run-other" "$(git -C "$LAB/project" rev-parse HEAD)" 2>/dev/null
run_gate "$LAB/run-other"; echo "gate exit=$?"
echo; echo "### S4: pipeline rebase onto a main that edited the line right next to the ship's hunk (patch-id changes)"
git -C "$LAB/project" checkout -q main
printf 'one\ntwo\nthree\nfour\n' > "$LAB/project/notes.txt"; git -C "$LAB/project" add notes.txt; git -C "$LAB/project" commit -qm notes
git -C "$LAB/project" push -q origin main 2>/dev/null; git -C "$LAB/gate.git" fetch -q origin '+refs/heads/main:refs/remotes/origin/main'
git -C "$LAB/project" checkout -qb fm/ad-ship2
printf 'one\ntwo\nTHREE ship\nfour\n' > "$LAB/project/notes.txt"; printf 'A revolutionary tool.\n' > "$LAB/project/ad.txt"
git -C "$LAB/project" add -A; git -C "$LAB/project" commit -qm 'ship edits'
SHIPC=$(git -C "$LAB/project" rev-parse HEAD)
sed "s/^branch=.*/branch=fm\/ad-ship2/" "$LAB/state/ad-ship.meta" > "$LAB/state/ad-ship2.meta"; cp "$LAB/state/ad-ship.checks.json" "$LAB/state/ad-ship2.checks.json"
"$WT/bin/fm-checks.sh" register "$LAB/state" ad-ship2
git -C "$LAB/project" push -q "$LAB/gate.git" fm/ad-ship2 2>/dev/null
git -C "$LAB/project" checkout -q main
printf 'one\ntwo base\nthree\nfour\n' > "$LAB/project/notes.txt"; git -C "$LAB/project" commit -qam 'base edits line two'
git -C "$LAB/project" push -q origin main 2>/dev/null; git -C "$LAB/gate.git" fetch -q origin '+refs/heads/main:refs/remotes/origin/main'
git -C "$LAB/gate.git" worktree add -q --detach "$LAB/run-rb" refs/remotes/origin/main 2>/dev/null
git -C "$LAB/run-rb" cherry-pick "$SHIPC" >/dev/null 2>&1 || echo "cherry-pick conflicted"
echo "patch-id ship:    $(git -C "$LAB/project" diff-tree -p "$SHIPC" | git patch-id --stable | cut -c1-12)"
echo "patch-id rebased: $(git -C "$LAB/run-rb" diff-tree -p HEAD | git patch-id --stable | cut -c1-12)"
run_gate "$LAB/run-rb"; echo "gate exit=$?"
echo; echo "### S5: a tampered admitted record refuses before any check runs"
printf '[]' > /dev/null; jq '.checks |= .[:1]' "$LAB/state/ad-ship.checks.json" > "$LAB/t.json" && cp "$LAB/t.json" "$LAB/state/ad-ship.checks.json"
git -C "$LAB/gate.git" worktree add -q --detach "$LAB/run-t" "$(git -C "$LAB/gate.git" rev-parse fm/ad-ship)" 2>/dev/null
run_gate "$LAB/run-t"; echo "gate exit=$?"
echo; echo "### S6: stale pointer whose meta has no checks= (exempt respawn) binds nothing"
sed -i.bak '/^checks/d' "$LAB/state/ad-ship.meta" && rm -f "$LAB/state/ad-ship.meta.bak"
run_gate "$LAB/run-t"; echo "gate exit=$?"
echo; echo "### S7: unregister (what teardown calls) removes the pointer; the run then binds nothing"
"$WT/bin/fm-checks.sh" unregister "$LAB/state" ad-ship2; ls "$LAB/registry"
run_gate "$LAB/run-rb"; echo "gate exit=$?"

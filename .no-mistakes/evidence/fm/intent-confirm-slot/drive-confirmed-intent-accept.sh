#!/usr/bin/env bash
# Accepted and pre-change paths through the real lab spawn/promote, launching real Claude workers.
set -u
R=$1; H=$R/home; TD=$(cat "$H/state/.fm-lab-tmux-dir"); P=$H/projects/notes; N=b$(date +%s | tail -c 6)
lab() { (cd "$H" && env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/bash TERM=xterm-256color LANG=en_US.UTF-8 \
  TMUX_TMPDIR="$TD" TREEHOUSE_ROOT="$R/treehouse" FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 FM_HOME="$H" "$@"); }
fill() {
  CI=$2 python3 - "$H/data/$1/brief.md" <<'PY'
import os, sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("{TASK}", "yes build the slot - add a docstring to notes/__init__.py. Do nothing else; then report done.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Edit only notes/__init__.py.", 1)
t = t.replace("{EXPERT_PROMPT}", "routine: skipped - one-line docstring", 1)
t = t.replace("{CONFIRMED_INTENT}", os.environ["CI"], 1)
open(p, "w").write(t)
PY
}
section() { echo; echo "=== $* ==="; }
spawn_ship() { lab "$H/bin/fm-tasks-axi.sh" add "$1" "lab $1" --kind ship --repo notes >/dev/null; lab "$H/bin/fm-spawn.sh" "$1" "$P" --mode local-only --yolo on --harness claude --model sonnet --effort low 2>&1; echo "exit=$?  meta=$(sed -n 's/^kind=//p' "$H/state/$1.meta" 2>/dev/null)"; }

id=ci$N-confirmed
section "ACCEPT: confirmed reading + captain confirmed line (ship)"
lab "$H/bin/fm-brief.sh" "$id" notes --mode local-only >/dev/null
fill "$id" $'Outcome: notes/__init__.py gains one module docstring; nothing else changes.\ncaptain confirmed: yes, only real work, and wait for my confirmation'
sed -n '/^## Confirmed intent/,/^## Firstmate spec/p' "$H/data/$id/brief.md"
spawn_ship "$id"
echo "--- launch-brief.md Confirmed intent section as delivered to the worker:"
sed -n '/^## Confirmed intent/,/^## Firstmate spec/p' "$H/data/$id/launch-brief.md" 2>/dev/null || ls "$H/data/$id"

id=ci$N-v1
section "PRE-CHANGE: brief marked expert-prompt v1 with no Confirmed intent (ship) warns and launches"
lab "$H/bin/fm-brief.sh" "$id" notes --mode local-only >/dev/null
fill "$id" 'not captain-originated - placeholder'
grep -v -x -F -e '## Confirmed intent' -e 'not captain-originated - placeholder' "$H/data/$id/brief.md" \
  | sed 's/^<!-- fm-brief: task-slots v2 -->$/<!-- fm-brief: expert-prompt v1 -->/' > "$H/data/$id/b" && mv "$H/data/$id/b" "$H/data/$id/brief.md"
sed -n '/^# Task/,/^routine: skipped/p' "$H/data/$id/brief.md"
spawn_ship "$id"

id=ci$N-scout
section "SCOUT: spawn with exemption, then promotion with the slot deleted is refused, restored slot promotes"
lab "$H/bin/fm-brief.sh" "$id" notes --scout >/dev/null
fill "$id" 'not captain-originated - lab promotion probe'
lab "$H/bin/fm-tasks-axi.sh" add "$id" "lab scout" --kind scout --repo notes >/dev/null; lab "$H/bin/fm-spawn.sh" "$id" "$P" --scout --harness claude --model sonnet --effort low 2>&1; echo "exit=$? kind=$(sed -n 's/^kind=//p' "$H/state/$id.meta")"
cp "$H/data/$id/brief.md" "$R/scout-brief.bak"
grep -v -x -F -e '## Confirmed intent' -e 'not captain-originated - lab promotion probe' "$R/scout-brief.bak" > "$H/data/$id/brief.md"
echo "--- promote with slot deleted:"
lab "$H/bin/fm-promote.sh" "$id" --mode local-only --yolo on 2>&1; echo "exit=$? kind=$(sed -n 's/^kind=//p' "$H/state/$id.meta")"
cp "$R/scout-brief.bak" "$H/data/$id/brief.md"
python3 - "$H/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
t=t.replace("not captain-originated - lab promotion probe","Outcome: report whether notes needs a docstring.\ncaptain confirmed:",1)
open(p,"w").write(t)
PY
echo "--- promote with a captain confirmed: line with no words:"
lab "$H/bin/fm-promote.sh" "$id" --mode local-only --yolo on 2>&1; echo "exit=$? kind=$(sed -n 's/^kind=//p' "$H/state/$id.meta")"
sed -i 's/^captain confirmed:$/captain confirmed: yes, promote it/' "$H/data/$id/brief.md"
echo "--- promote with confirmed reading + words:"
lab "$H/bin/fm-promote.sh" "$id" --mode local-only --yolo on 2>&1; echo "exit=$? kind=$(sed -n 's/^kind=//p' "$H/state/$id.meta")"

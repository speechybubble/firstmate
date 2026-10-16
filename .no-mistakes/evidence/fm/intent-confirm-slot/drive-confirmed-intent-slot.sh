#!/usr/bin/env bash
# Drive the real lab home's fm-brief.sh / fm-spawn.sh / fm-promote.sh against the
# lab's private tmux server. Usage: drive-confirmed-intent-slot.sh <lab-root>
set -u
R=$1; H=$R/home; TD=$(cat "$H/state/.fm-lab-tmux-dir"); P=$H/projects/notes
lab() { (cd "$H" && env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/bash TERM=xterm-256color LANG=en_US.UTF-8 \
  TMUX_TMPDIR="$TD" TREEHOUSE_ROOT="$R/treehouse" FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 FM_HOME="$H" "$@"); }
fill() {  # <id> <confirmed-intent body>
  CI=$2 python3 - "$H/data/$1/brief.md" <<'PY'
import os, sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("{TASK}", "Add a docstring to notes/__init__.py. Do nothing else; report done.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Edit only notes/__init__.py.", 1)
t = t.replace("{EXPERT_PROMPT}", "routine: skipped - one-line docstring", 1)
t = t.replace("{CONFIRMED_INTENT}", os.environ["CI"], 1)
open(p, "w").write(t)
PY
}
section() { echo; echo "=== $* ==="; }
N=$(date +%s | tail -c 6)
section "scaffold a ship brief"
lab "$H/bin/fm-brief.sh" ci$N-probe notes --mode local-only
sed -n '/^# Task/,/^### Expert prompt/p' "$H/data/ci$N-probe/brief.md"

refuse() {  # <label> <body>
  local id=ci$N-$1
  section "REFUSE? $1  body=$(printf %q "$2")"
  lab "$H/bin/fm-brief.sh" "$id" notes --mode local-only >/dev/null
  fill "$id" "$(printf '%b' "$2")"
  lab "$H/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo on --harness claude --model sonnet --effort low 2>&1
  echo "exit=$?  meta_written=$([ -e "$H/state/$id.meta" ] && echo yes || echo no)"
}
refuse unfilled '{CONFIRMED_INTENT}'
refuse empty ''
refuse reading-only 'Add one docstring and nothing else.'
refuse confirm-only 'captain confirmed: yes do it'
refuse confirm-no-words 'Add one docstring.\ncaptain confirmed:   '
refuse confirm-twice 'Add one docstring.\ncaptain confirmed: yes\ncaptain confirmed: go'
refuse exempt-no-reason 'not captain-originated - '
refuse exempt-mixed 'Add one docstring.\nnot captain-originated - cleanup'
id=ci$N-deleted
section "REFUSE? deleted heading on a v2-marked brief"
lab "$H/bin/fm-brief.sh" "$id" notes --mode local-only >/dev/null
fill "$id" 'not captain-originated - placeholder'
grep -v -x -F -e '## Confirmed intent' -e 'not captain-originated - placeholder' "$H/data/$id/brief.md" > "$H/data/$id/b" && mv "$H/data/$id/b" "$H/data/$id/brief.md"
lab "$H/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo on --harness claude --model sonnet --effort low 2>&1
echo "exit=$?  meta_written=$([ -e "$H/state/$id.meta" ] && echo yes || echo no)"
id=ci$N-v2markforged
section "REFUSE? deleted heading with marker rewritten to v1 but expert prompt also deleted"
lab "$H/bin/fm-brief.sh" "$id" notes --mode local-only >/dev/null
fill "$id" 'not captain-originated - placeholder'
grep -v -x -F -e '## Confirmed intent' -e 'not captain-originated - placeholder' -e '### Expert prompt' -e 'routine: skipped - one-line docstring' "$H/data/$id/brief.md" \
  | sed 's/^<!-- fm-brief: task-slots v2 -->$/<!-- fm-brief: expert-prompt v1 -->/' > "$H/data/$id/b" && mv "$H/data/$id/b" "$H/data/$id/brief.md"
lab "$H/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo on --harness claude --model sonnet --effort low 2>&1
echo "exit=$?  meta_written=$([ -e "$H/state/$id.meta" ] && echo yes || echo no)"

echo "$N" > "$R/ci-nonce"

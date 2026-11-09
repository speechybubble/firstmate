#!/usr/bin/env bash
# Live driver: lab home + private tmux + real fm-checks/fm-crew-state/tasks-axi/fm-check-results.
set -u
R=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M6ZZNHES48QQZP9GYYTJCRGK
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME="$LAB"
TD=$("$R/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TD"
# PATH without no-mistakes so ship crew-state does not consult the real daemon
mkdir -p "$LAB/bin"; for t in tasks-axi jq tmux git; do ln -sf "$(command -v $t)" "$LAB/bin/$t"; done
export PATH="$LAB/bin:/usr/bin:/bin"
cleanup(){ tmux kill-server 2>/dev/null; "$R/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
tmux new-session -d -s fm -n fm-ck 'sleep 3600'
tmux new-window -d -t fm: -n fm-sc 'sleep 3600'
tmux new-window -d -t fm: -n fm-sd 'sleep 3600'
step(){ printf '\n### %s\n' "$*"; }
idle(){ g=$("$R/bin/fm-busy-event.sh" arm "$LAB/state" "$1"); "$R/bin/fm-busy-event.sh" apply "$LAB/state" "$1" idle --gen "$g" --source claude-hook --event stop >/dev/null; }
cs(){ "$R/bin/fm-crew-state.sh" "$1" | grep -E '^(state|detail):'; }

# ---------- Ship ck: refused, worker commits still failing, then passes ----------
step "ship ck: admit guarantee-conditional check via fm-checks.sh validate --admit"
WT=$LAB/wt-ck; mkdir -p "$WT"; git -C "$WT" init -q; git -C "$WT" -c user.email=a@b -c user.name=lab commit -q --allow-empty -m init
git -C "$WT" checkout -q -b fm/ck; git -C "$WT" update-ref refs/remotes/origin/main HEAD
gc(){ git -C "$WT" -c user.email=a@b -c user.name=lab commit -q -am "$1" && git -C "$WT" update-ref refs/remotes/origin/fm/ck HEAD; }
printf 'Full refund, no questions asked.\n' > "$WT/ad.txt"; git -C "$WT" add ad.txt; gc 'the ad'
printf '# Task\n## Checks\n```json\n[{"id":"guarantee-conditional","source":"higher price guarantees should always be conditional","type":"not-contains","target":"ad.txt","pattern":"no questions asked","good":"If you run it 30 days, next month is free.","bad":"Refund, no questions asked."}]\n```\n' > "$LAB/ck-brief.md"
"$R/bin/fm-checks.sh" validate "$LAB/ck-brief.md" --kind ship --admit "$LAB/state/ck.checks.json"
dg=$(sha256sum "$LAB/state/ck.checks.json" | awk '{print $1}')
printf '%s\n' window=fm:fm-ck "worktree=$WT" "project=$WT" kind=ship mode=direct-PR checks=1 "checks_sha=$dg" harness=claude backend=tmux > "$LAB/state/ck.meta"
"$R/bin/fm-skill-fires.sh" 2>/dev/null >/dev/null || true
# launch record as fm-spawn writes it
printf '%s\tck\tchecks-admitted\tfm-spawn.sh\tguarantee-conditional\n' "$(date -u +%FT%TZ)" >> "$LAB/data/skill-fires.tsv"
printf 'done [at=1]: PR https://github.com/o/r/pull/9\n' > "$LAB/state/ck.status"; idle ck
step "ship ck: first done read (fails check)"; cs ck; cs ck
printf 'Refund, no questions asked, ever.\n' > "$WT/ad.txt"; gc 'still failing B'
step "ship ck: same done line, still failing at new commit"; cs ck
printf 'If you run it 30 days, next month is free.\n' > "$WT/ad.txt"; gc 'fixed'
step "ship ck: fixed commit, same done line"; cs ck; cs ck

# ---------- Scout sc: refused, fixed by editing the report (changed digest) ----------
step "scout sc: admit report check"
mkdir -p "$LAB/data/sc"; printf 'Prices: TBD\n' > "$LAB/data/sc/report.md"
printf '# Task\n## Checks\n```json\n[{"id":"price-named","source":"name the price in dollars","type":"contains","target":"report.md","pattern":"\\\\$[0-9]","good":"It costs $40 a month.","bad":"Prices: TBD"}]\n```\n' > "$LAB/sc-brief.md"
"$R/bin/fm-checks.sh" validate "$LAB/sc-brief.md" --kind scout --root "$LAB/data/sc" --admit "$LAB/state/sc.checks.json" || cat "$LAB/sc-brief.md"
dg=$(sha256sum "$LAB/state/sc.checks.json" | awk '{print $1}')
mkdir -p "$LAB/wt-sc"; git -C "$LAB/wt-sc" init -q
printf '%s\n' window=fm:fm-sc "worktree=$LAB/wt-sc" kind=scout checks=1 "checks_sha=$dg" harness=claude backend=tmux > "$LAB/state/sc.meta"
printf '%s\tsc\tchecks-admitted\tfm-spawn.sh\tprice-named\n' "$(date -u +%FT%TZ)" >> "$LAB/data/skill-fires.tsv"
printf 'done [at=1]: report at data/sc/report.md\n' > "$LAB/state/sc.status"; idle sc
step "scout sc: done read with TBD report"; cs sc
printf 'It costs $40 a month.\n' > "$LAB/data/sc/report.md"
step "scout sc: report fixed"; cs sc

# ---------- Scout sd: refused, then passes with no change (transient) => unchanged ----------
# Use a standing-style refusal? Instead: refused and left open.
mkdir -p "$LAB/data/sd"; printf 'Prices: TBD\n' > "$LAB/data/sd/report.md"
sed 's/price-named/price-named/' "$LAB/sc-brief.md" > "$LAB/sd-brief.md"
"$R/bin/fm-checks.sh" validate "$LAB/sd-brief.md" --kind scout --root "$LAB/data/sd" --admit "$LAB/state/sd.checks.json" >/dev/null
dg=$(sha256sum "$LAB/state/sd.checks.json" | awk '{print $1}')
mkdir -p "$LAB/wt-sd"; git -C "$LAB/wt-sd" init -q
printf '%s\n' window=fm:fm-sd "worktree=$LAB/wt-sd" kind=scout checks=1 "checks_sha=$dg" harness=claude backend=tmux > "$LAB/state/sd.meta"
printf '%s\tsd\tchecks-admitted\tfm-spawn.sh\tprice-named\n' "$(date -u +%FT%TZ)" >> "$LAB/data/skill-fires.tsv"
printf 'done [at=1]: report at data/sd/report.md\n' > "$LAB/state/sd.status"; idle sd
step "scout sd: done read, left unfixed (stays open)"; cs sd

# ---------- intake: one invalid check (validation fails), one exempt ----------
printf '%s\tbad1\tchecks-invalid\tfm-spawn.sh\tweak-check\n' "$(date -u +%FT%TZ)" >> "$LAB/data/skill-fires.tsv"
printf '%s\tex1\tchecks-exempt\tfm-spawn.sh\tno observable content\n' "$(date -u +%FT%TZ)" >> "$LAB/data/skill-fires.tsv"

# ---------- backlog: ck and sc shipped ----------
step "backlog: record Done rows via tasks-axi"
cd "$LAB/data"
tasks-axi add ck "ship ck" --kind ship --start >/dev/null 2>&1 || tasks-axi add ck "ship ck" --kind ship 2>&1 | tail -2
tasks-axi done ck --pr https://github.com/o/r/pull/9 2>&1 | tail -1
tasks-axi add sc "scout sc" --kind scout --start >/dev/null 2>&1; tasks-axi done sc 2>&1 | tail -1
tasks-axi add sd "scout sd" --kind scout --start >/dev/null 2>&1
cd - >/dev/null

step "backlog rows"; (cd "$LAB/data" && tasks-axi list --state done --fields closed)
step "scout sd: fixed after a window mark (earlier refusal confirmed in window)"
sleep 2; MARK=$(date -u +%FT%TZ); sleep 1
printf 'It costs $40 a month.\n' > "$LAB/data/sd/report.md"; cs sd
step "skill-fires.tsv (the durable log the gate wrote)"
cat "$LAB/data/skill-fires.tsv"
step "fm-check-results.sh --since today"
TODAY=$(date -u +%F)
"$R/bin/fm-check-results.sh" --since "$TODAY" --json "$LAB/out.json"; echo "exit=$?"
step "json"; jq . "$LAB/out.json"
LM=$(date -u -d "$(date +%F) 00:00 $(date +%z)" +%FT%TZ)
step "nightly window aligned to local midnight ($LM)"
"$R/bin/fm-check-results.sh" --since "$LM"; echo "exit=$?"
step "window starting at mark $MARK (sd refused before it, passed inside it)"
"$R/bin/fm-check-results.sh" --since "$MARK"; echo "exit=$?"
step "adversarial: usage errors"
"$R/bin/fm-check-results.sh"; echo "exit=$?"
"$R/bin/fm-check-results.sh" --since yesterday; echo "exit=$?"
"$R/bin/fm-check-results.sh" --since "$TODAY" --until "$TODAY"; echo "exit=$?"
step "window before today: everything outside the window"
"$R/bin/fm-check-results.sh" --since 2026-01-01 --until 2026-01-02; echo "exit=$?"

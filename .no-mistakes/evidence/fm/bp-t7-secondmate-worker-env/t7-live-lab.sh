#!/usr/bin/env bash
# t7-live-lab.sh <ref> <label> - live check of Backpass T7 (N3).
#
# Builds a disposable main lab home (checked out at <ref>) and a real seeded
# second-mate home cloned from it, on a private tmux server that was started
# from the MAIN home's environment (FM_HOME/FM_STATE_OVERRIDE = main), which is
# the shared-server condition the Backpass report found. Then, acting as the
# second mate (FM_HOME=mate), it spawns real Claude ship and scout workers with
# the mate's own bin/fm-spawn.sh, reads the environment each live worker
# process actually started with from /proc, and replays one fleet script with
# that exact environment and no explicit FM_HOME to see which home it writes.
# With label "fixed" it also checks a real secondmate launch and a real
# fm-control.sh relaunch. Everything is torn down at the end.
set -u
REF=$1 LABEL=$2
SRC=/home/denni/.no-mistakes/worktrees/d567722de3ac/01M521XCJ80CXMESD6YCTYN0QT
ROOT=$(mktemp -d /tmp/fmt7.XXXXXX); ROOT=$(cd "$ROOT" && pwd -P)
MAIN=$ROOT/home MATE=$ROOT/mate
NONCE=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
MATE_ID="t7${NONCE}-mate"
say() { printf '%s\n' "$*"; }

"$SRC/bin/fm-lab-home.sh" create "$MAIN" >/dev/null || exit 1
git -C "$MAIN" init -q -b main
git -C "$MAIN" fetch -q "$SRC" "$REF" && git -C "$MAIN" checkout -q -f -B main FETCH_HEAD || exit 1
git -C "$MAIN" config user.name lab; git -C "$MAIN" config user.email lab@example.invalid
mkdir -p "$MAIN/state" "$MAIN/data" "$MAIN/config" "$MAIN/projects" "$ROOT/treehouse"
for h in "$MAIN"; do
  printf 'tmux\n' > "$h/config/backend"; printf 'claude\n' > "$h/config/crew-harness"
  printf 'claude haiku low\n' > "$h/config/secondmate-harness"; printf 'auto\n' > "$h/config/claude-permission-mode"
done
TMUX_DIR=$("$SRC/bin/fm-lab-home.sh" tmux-dir "$MAIN") || exit 1

base_env() {
  printf '%s\n' "HOME=$HOME" "USER=$USER" "LOGNAME=$USER" "PATH=$PATH" "SHELL=${SHELL:-/bin/bash}" \
    "TERM=xterm-256color" "LANG=${LANG:-C.UTF-8}" "TMUX_TMPDIR=$TMUX_DIR" \
    "TREEHOUSE_ROOT=$ROOT/treehouse" "FM_BACKEND=tmux" "DISABLE_AUTOUPDATER=1"
}
run() { local -a b=(); local l; while IFS= read -r l; do b+=("$l"); done < <(base_env); env -i "${b[@]}" "$@"; }
ltmux() { env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux "$@"; }

cleanup() {
  ltmux kill-server 2>/dev/null
  "$SRC/bin/fm-lab-home.sh" teardown "$MAIN" >/dev/null 2>&1
  # spawn registered Claude trust for lab paths; drop those entries again
  python3 - "$ROOT" <<'PY'
import json, os, sys, tempfile
root = sys.argv[1]; p = os.path.expanduser("~/.claude.json")
try: d = json.load(open(p))
except Exception: sys.exit(0)
pr = d.get("projects") or {}
gone = [k for k in pr if k == root or k.startswith(root + "/")]
if not gone: sys.exit(0)
for k in gone: del pr[k]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.realpath(p)))
with os.fdopen(fd, "w") as f: json.dump(d, f, indent=2)
os.replace(tmp, os.path.realpath(p))
print(f"removed {len(gone)} lab trust entries")
PY
  chmod -R u+w "$ROOT" /tmp/fm-t7"$NONCE"-* 2>/dev/null; rm -rf /tmp/fm-t7"$NONCE"-* "$ROOT"
}
trap cleanup EXIT

# The tmux server is started from the MAIN home's environment, as the main
# primary's shared server is.
run FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" tmux -f /dev/null new-session -d -s firstmate -n lab -x 220 -y 60 -c "$ROOT" || exit 1
say "tmux server global env: $(ltmux show-environment -g FM_HOME) $(ltmux show-environment -g FM_STATE_OVERRIDE)"

# Real second-mate home seeded from the main home.
(cd "$MAIN" && run FM_HOME="$MAIN" FM_SECONDMATE_CHARTER='Idle T7 lab second mate. Do nothing until steered.' \
  FM_SECONDMATE_SCOPE='t7 lab' "$MAIN/bin/fm-home-seed.sh" "$MATE_ID" "$MATE" --no-projects) >/dev/null || { say "seed failed"; exit 1; }
mkdir -p "$MATE/state" "$MATE/config" "$MATE/projects"
cp "$MAIN"/config/{backend,crew-harness,claude-permission-mode} "$MATE/config/"
# a tiny project in the mate home
seed=$ROOT/seed; mkdir -p "$seed"; git -C "$seed" init -q -b main
echo '# notes' > "$seed/README.md"; git -C "$seed" add -A; git -C "$seed" -c user.name=lab -c user.email=l@x.invalid commit -qm seed
git clone -q --bare "$seed" "$ROOT/notes-origin.git"; git clone -q "$ROOT/notes-origin.git" "$MATE/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes\n' > "$MATE/data/projects.md"

fill_brief() {  # <home> <id>
  python3 - "$1/data/$2/brief.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("{TASK}", "T7 lab probe worker. Do nothing.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Append one status line saying paused, then end your turn. Do not run any other command.", 1)
t = t.replace("{EXPERT_PROMPT}", "routine: skipped - synthetic T7 live-lab fixture", 1)
open(p, "w").write(t)
PY
}

descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
worker_pid() {  # <window> -> pid of the live claude process under that pane
  local pane i c a0
  for i in $(seq 1 90); do
    pane=$(ltmux display-message -p -t "firstmate:$1" '#{pane_pid}' 2>/dev/null)
    if [ -n "$pane" ]; then
      for c in $pane $(descendants "$pane"); do
        a0=$(tr '\0' '\n' < /proc/$c/cmdline 2>/dev/null | head -1)
        case "${a0##*/}" in claude) echo "$c"; return 0 ;; esac
      done
    fi
    sleep 1
  done
  return 1
}
env_of() { tr '\0' '\n' < "/proc/$1/environ" | grep -E '^(FM_HOME|FM_STATE_OVERRIDE)=' | sort | tr '\n' ' '; }

probe_write() {  # <pid> <row-id>: replay a fleet script under the worker's own env, no explicit FM_HOME
  local -a e=(); local l
  while IFS= read -r l; do e+=("$l"); done < <(tr '\0' '\n' < "/proc/$1/environ" | grep -v '^$')
  (cd "$MATE/projects/notes" && env -i "${e[@]}" "$MATE/bin/fm-tasks-axi.sh" add "$2" "t7 probe row" --kind ship --repo notes >/dev/null 2>&1)
  local where=none
  grep -rqs -- "$2" "$MAIN/data/backlog.md" "$MAIN/data/tasks" 2>/dev/null && where=main
  grep -rqs -- "$2" "$MATE/data/backlog.md" "$MATE/data/tasks" 2>/dev/null && where="${where/none/}${where:+ }mate"
  echo "$where"
}

check_worker() {  # <kind> <allowlist absent|enabled>
  local kind=$1 al=$2 id="t7${NONCE}-$1-$2" args pid seen
  [ "$al" = absent ] && rm -f "$MATE/config/launch-env-allowlist" || : > "$MATE/config/launch-env-allowlist"
  if [ "$kind" = ship ]; then
    (cd "$MATE" && run FM_HOME="$MATE" "$MATE/bin/fm-brief.sh" "$id" notes --mode local-only) >/dev/null || { say "brief fail $id"; return 1; }
    args=(--mode local-only --yolo on)
  else
    (cd "$MATE" && run FM_HOME="$MATE" "$MATE/bin/fm-brief.sh" "$id" notes --scout) >/dev/null || { say "brief fail $id"; return 1; }
    args=(--scout)
  fi
  fill_brief "$MATE" "$id"
  (cd "$MATE" && run FM_HOME="$MATE" "$MATE/bin/fm-tasks-axi.sh" add "$id" "t7 $kind" --kind "$kind" --repo notes) >/dev/null
  # the spawn runs inside the shared server, so its own TMUX names that server
  local out; out=$(cd "$MATE" && run FM_HOME="$MATE" "$MATE/bin/fm-spawn.sh" "$id" "$MATE/projects/notes" "${args[@]}" --harness claude --model haiku --effort low 2>&1)
  say "spawn $id: $(printf '%s' "$out" | tail -1)"
  pid=$(worker_pid "fm-$id") || { say "RESULT $LABEL $kind allowlist=$al: no live claude process found"; return 1; }
  seen=$(env_of "$pid")
  say "RESULT $LABEL $kind allowlist=$al worker pid=$pid env: $seen"
  say "RESULT $LABEL $kind allowlist=$al probe fleet-script write landed in: $(probe_write "$pid" "t7probe-$kind-$al")"
  echo "$id" >> "$ROOT/ids"
}

say "main home=$MAIN"; say "mate home=$MATE"
check_worker ship absent
if [ "$LABEL" = fixed ]; then
  check_worker scout absent
  check_worker ship enabled
  rm -f "$MATE/config/launch-env-allowlist"
  # relaunch the first ship through the real control path, as the mate
  rid="t7${NONCE}-ship-absent"
  old=$(worker_pid "fm-$rid")
  out=$(cd "$MATE" && run FM_HOME="$MATE" "$MATE/bin/fm-control.sh" "$rid" relaunch --note 'T7 lab relaunch' 2>&1)
  say "relaunch: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  for i in $(seq 1 30); do new=$(worker_pid "fm-$rid"); [ -n "$new" ] && [ "$new" != "$old" ] && break; sleep 1; done
  say "RESULT $LABEL relaunch old pid=$old new pid=$new env: $(env_of "$new")"
  # a real secondmate launched from MAIN keeps its own home, not its dispatcher's
  out=$(cd "$MAIN" && run FM_HOME="$MAIN" "$MAIN/bin/fm-spawn.sh" "$MATE_ID" --secondmate 2>&1)
  say "secondmate spawn: $(printf '%s' "$out" | tail -1)"
  pid=$(worker_pid "fm-$MATE_ID") || say "no secondmate claude"
  say "RESULT $LABEL secondmate pid=$pid env: $(env_of "$pid")"
fi
say "--- window list"; ltmux list-windows -a -F '#{session_name}:#{window_name}'
for w in $(ltmux list-windows -a -F '#{window_name}' | grep '^fm-'); do
  ltmux capture-pane -p -t "firstmate:$w" > "$OUTDIR/$LABEL-$w.pane.txt" 2>/dev/null
done
say "done"

#!/usr/bin/env bash
# fm-browser-sessions-lib.sh - find and stop the chrome-devtools-axi browser
# helpers a Firstmate task leaves behind.
#
# A worker that opens a browser through chrome-devtools-axi starts a detached
# bridge: a node process spawned into a session of its own that carries
# CHROME_DEVTOOLS_AXI_SESSION and CHROME_DEVTOOLS_AXI_PORT in its environment
# and owns a chrome-devtools-mcp child, which launches a headless Chrome in yet
# another session. The bridge lives until `chrome-devtools-axi stop` names it,
# so a task that ends without that stop leaves the whole tree running (about
# 150 MB each; on 2026-10-26 eight such leftovers held all of swap). `stop`
# finds its bridge only through the session's bridge.pid file, which a later
# session of the same name overwrites, so it cannot reach an orphan and must
# never be pointed at a pid file that names a different bridge.
#
# Ownership is read from the bridge's own environment, never from a command
# line: the worker's FM_TASK_ID and FM_HOME (bin/fm-spawn.sh exports both to
# every ship and scout) reach the bridge because it inherits the worker's
# environment. A bridge is the process that carries both chrome-devtools-axi
# variables and leads its own session; its descendants are found by parent pid,
# because Chrome and chrome-devtools-mcp do not keep those variables.
# Chrome's crash handlers are reparented to init at launch and exit on their own
# once their Chrome is gone, so the descendant walk does not need them.
#
# Enumeration needs Linux /proc. Elsewhere the functions report the sweep as
# unsupported (status 2) and touch nothing.
#
# Functions:
#   fm_browser_supported
#     Status 0 when /proc can be read for this sweep.
#   fm_browser_bridges
#     One line per bridge visible to this user, fields separated by the ASCII
#     unit separator (0x1f, FM_BROWSER_FS) so an empty field survives `read`:
#     pid, session, port, task-id, fm-home, age-seconds, tree-rss-kb.
#     task-id and fm-home are empty when the bridge carries none.
#   fm_browser_home_matches <bridge-fm-home> <home>
#     Status 0 when both name the same directory.
#   fm_browser_stop_task <home> <task-id> <log-prefix>
#     Stops every bridge whose FM_TASK_ID is <task-id> and whose FM_HOME is
#     <home>, and only those. For each, it first asks `chrome-devtools-axi stop`
#     when that session's pid file names exactly this bridge, then terminates
#     whatever remains of the tree captured before the stop (TERM, then KILL),
#     re-checking each pid's start time before every signal so a reused pid is
#     never hit. Each stopped session prints one line to stderr, and
#     FM_BROWSER_MATCHED holds how many bridges matched. Status 1 when any
#     process of a matched tree is still alive at the end.

FM_BROWSER_TERM_GRACE_TENTHS=${FM_BROWSER_TERM_GRACE_TENTHS:-30}
FM_BROWSER_STOP_TIMEOUT_SECS=${FM_BROWSER_STOP_TIMEOUT_SECS:-15}
FM_BROWSER_FS=$'\x1f'

fm_browser_supported() {
  [ -r /proc/self/stat ] && [ -r /proc/self/environ ]
}

# Start time in clock ticks since boot (field 22 of /proc/<pid>/stat), the
# identity checked before every signal. A zombie has already exited and waits
# only for its parent to reap it, so it has no identity here.
fm_browser_starttime() {  # <pid>
  local line
  local -a fields
  line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a fields <<< "${line##*)}"
  [ "${#fields[@]}" -ge 20 ] || return 1
  [ "${fields[0]}" != Z ] || return 1
  case "${fields[19]}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "${fields[19]}"
}

# Session id (field 6) of <pid>.
fm_browser_sid() {  # <pid>
  local line
  local -a fields
  line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a fields <<< "${line##*)}"
  [ "${#fields[@]}" -ge 4 ] || return 1
  printf '%s\n' "${fields[3]}"
}

# Reads the variables this lib needs from /proc/<pid>/environ into
# FM_BROWSER_ENV_{SESSION,PORT,TASK,FMHOME,HOME}. A field separator or newline
# in a value becomes '?', so the values stay safe as listing fields.
fm_browser_read_env() {  # <pid>
  local kv value
  FM_BROWSER_ENV_SESSION=
  FM_BROWSER_ENV_PORT=
  FM_BROWSER_ENV_TASK=
  FM_BROWSER_ENV_FMHOME=
  FM_BROWSER_ENV_HOME=
  [ -r "/proc/$1/environ" ] || return 1
  while IFS= read -r -d '' kv; do
    value=${kv#*=}
    value=${value//"$FM_BROWSER_FS"/?}
    value=${value//$'\n'/?}
    case "$kv" in
      CHROME_DEVTOOLS_AXI_SESSION=*) FM_BROWSER_ENV_SESSION=$value ;;
      CHROME_DEVTOOLS_AXI_PORT=*) FM_BROWSER_ENV_PORT=$value ;;
      FM_TASK_ID=*) FM_BROWSER_ENV_TASK=$value ;;
      FM_HOME=*) FM_BROWSER_ENV_FMHOME=$value ;;
      HOME=*) FM_BROWSER_ENV_HOME=$value ;;
    esac
  done < "/proc/$1/environ" 2>/dev/null
  return 0
}

# Pids of <root> and every descendant, by parent pid, from one process table read.
fm_browser_tree_pids() {  # <root-pid>
  ps -e -o pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      if (!(root in parent)) exit
      tree[root] = 1
      grew = 1
      while (grew) {
        grew = 0
        for (p in parent) if (!(p in tree) && (parent[p] in tree)) { tree[p] = 1; grew = 1 }
      }
      for (p in tree) print p
    }'
}

# Pids of candidate bridges: processes whose environment names a
# chrome-devtools-axi session. One grep over every environ file this user can read.
fm_browser_candidate_pids() {
  local path pid
  grep -lsaz '^CHROME_DEVTOOLS_AXI_SESSION=' /proc/[0-9]*/environ 2>/dev/null \
    | while IFS= read -r path; do
        pid=${path#/proc/}
        pid=${pid%/environ}
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        printf '%s\n' "$pid"
      done
}

fm_browser_bridges() {
  local pid sid roots=""
  fm_browser_supported || return 2
  for pid in $(fm_browser_candidate_pids); do
    sid=$(fm_browser_sid "$pid") || continue
    [ "$sid" = "$pid" ] || continue
    fm_browser_read_env "$pid" || continue
    [ -n "$FM_BROWSER_ENV_SESSION" ] && [ -n "$FM_BROWSER_ENV_PORT" ] || continue
    roots="$roots$pid$FM_BROWSER_FS$FM_BROWSER_ENV_SESSION$FM_BROWSER_FS$FM_BROWSER_ENV_PORT$FM_BROWSER_FS$FM_BROWSER_ENV_TASK$FM_BROWSER_FS$FM_BROWSER_ENV_FMHOME
"
  done
  [ -n "$roots" ] || return 0
  # One process-table read gives every bridge its age and the summed resident
  # memory of its whole tree.
  { ps -e -o pid=,ppid=,rss=,etimes= 2>/dev/null; printf '%s\n' '--roots--'; printf '%s' "$roots"; } \
    | awk -v fs="$FM_BROWSER_FS" '
      $0 == "--roots--" { inroots = 1; next }
      !inroots {
        rss[$1] = $3; age[$1] = $4
        kids[$2] = kids[$2] " " $1
        next
      }
      {
        split($0, f, fs)
        total = 0; depth = 1; stack[1] = f[1]
        while (depth > 0) {
          p = stack[depth--]
          if (p in seen) continue
          seen[p] = 1; total += rss[p]
          n = split(kids[p], k, " ")
          for (i = 1; i <= n; i++) stack[++depth] = k[i]
        }
        delete seen
        printf "%s%s%s%s%s%s%s%s%s%s%d%s%d\n", f[1], fs, f[2], fs, f[3], fs, f[4], fs, f[5], fs, age[f[1]], fs, total
      }'
}

fm_browser_home_matches() {  # <bridge-fm-home> <home>
  local a=$1 b=$2
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  a=$(cd "$a" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$b" 2>/dev/null && pwd -P) || return 1
  [ "$a" = "$b" ]
}

# Asks chrome-devtools-axi to stop <session> as the bridge's own user home sees
# it, only when that session's pid file names exactly <pid>. Status 0 when the
# stop ran and reported success; otherwise FM_BROWSER_POLITE_SKIPPED says why.
fm_browser_polite_stop() {  # <pid> <session> <bridge-home>
  local pid=$1 session=$2 bridge_home=$3 pidfile recorded
  FM_BROWSER_POLITE_SKIPPED=
  command -v chrome-devtools-axi >/dev/null 2>&1 \
    || { FM_BROWSER_POLITE_SKIPPED="chrome-devtools-axi is not on PATH"; return 1; }
  [ -n "$bridge_home" ] \
    || { FM_BROWSER_POLITE_SKIPPED="the bridge carries no HOME"; return 1; }
  case "$session" in
    default) pidfile=$bridge_home/.chrome-devtools-axi/bridge.pid ;;
    *) pidfile=$bridge_home/.chrome-devtools-axi/sessions/$session/bridge.pid ;;
  esac
  recorded=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$pidfile" 2>/dev/null | head -n 1)
  [ "$recorded" = "$pid" ] \
    || { FM_BROWSER_POLITE_SKIPPED="its session pid file names another bridge"; return 1; }
  env -u CHROME_DEVTOOLS_AXI_PORT -u CHROME_DEVTOOLS_AXI_BROWSER_URL \
    -u CHROME_DEVTOOLS_AXI_MCP_SERVER_URL \
    HOME="$bridge_home" CHROME_DEVTOOLS_AXI_SESSION="$session" \
    timeout "$FM_BROWSER_STOP_TIMEOUT_SECS" chrome-devtools-axi stop >/dev/null 2>&1 \
    || { FM_BROWSER_POLITE_SKIPPED="chrome-devtools-axi stop failed"; return 1; }
}

# Prints the pids from the parallel arrays FM_BROWSER_TREE_PIDS and
# FM_BROWSER_TREE_STARTS that are still the same processes.
fm_browser_tree_survivors() {
  local i pid
  for i in "${!FM_BROWSER_TREE_PIDS[@]}"; do
    pid=${FM_BROWSER_TREE_PIDS[$i]}
    [ "$(fm_browser_starttime "$pid" 2>/dev/null)" = "${FM_BROWSER_TREE_STARTS[$i]}" ] \
      && printf '%s\n' "$pid"
  done
}

fm_browser_signal_survivors() {  # <signal>
  local pid
  for pid in $(fm_browser_tree_survivors); do
    kill "-$1" "$pid" 2>/dev/null || true
  done
}

# Waits up to <tenths> tenths of a second for the captured tree to exit.
fm_browser_wait_tree_gone() {  # <tenths>
  local n=0
  while [ "$n" -lt "$1" ]; do
    [ -z "$(fm_browser_tree_survivors)" ] && return 0
    sleep 0.1
    n=$((n + 1))
  done
  [ -z "$(fm_browser_tree_survivors)" ]
}

# shellcheck disable=SC2034 # FM_BROWSER_MATCHED is the caller's result.
fm_browser_stop_task() {  # <home> <task-id> <log-prefix>
  local home=$1 task=$2 prefix=$3 line pid session port btask bhome age rss
  local start tree tpid how left count wait rc=0
  local -a matched=()
  FM_BROWSER_MATCHED=0
  [ -n "$task" ] || return 1
  fm_browser_supported || return 2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$FM_BROWSER_FS read -r pid session port btask bhome age rss <<< "$line"
    [ "$btask" = "$task" ] || continue
    fm_browser_home_matches "$bhome" "$home" || continue
    matched+=("$pid")
  done <<EOF
$(fm_browser_bridges)
EOF
  FM_BROWSER_MATCHED=${#matched[@]}
  for pid in "${matched[@]+"${matched[@]}"}"; do
    start=$(fm_browser_starttime "$pid") || continue
    # Re-read and re-check ownership against the live process, so a pid reused
    # since the listing is never stopped.
    fm_browser_read_env "$pid" || continue
    [ "$FM_BROWSER_ENV_TASK" = "$task" ] || continue
    fm_browser_home_matches "$FM_BROWSER_ENV_FMHOME" "$home" || continue
    session=$FM_BROWSER_ENV_SESSION
    port=$FM_BROWSER_ENV_PORT
    FM_BROWSER_TREE_PIDS=()
    FM_BROWSER_TREE_STARTS=()
    tree=$(fm_browser_tree_pids "$pid")
    for tpid in $tree; do
      [ "$tpid" = "$$" ] && continue
      start=$(fm_browser_starttime "$tpid") || continue
      FM_BROWSER_TREE_PIDS+=("$tpid")
      FM_BROWSER_TREE_STARTS+=("$start")
    done
    count=${#FM_BROWSER_TREE_PIDS[@]}
    if fm_browser_polite_stop "$pid" "$session" "$FM_BROWSER_ENV_HOME"; then
      how="stopped through chrome-devtools-axi"
      wait=20
    else
      how="chrome-devtools-axi stop skipped: $FM_BROWSER_POLITE_SKIPPED"
      wait=0
    fi
    if ! fm_browser_wait_tree_gone "$wait"; then
      left=$(fm_browser_tree_survivors | wc -l | tr -d ' ')
      fm_browser_signal_survivors TERM
      if ! fm_browser_wait_tree_gone "$FM_BROWSER_TERM_GRACE_TENTHS"; then
        fm_browser_signal_survivors KILL
        fm_browser_wait_tree_gone 20 || true
      fi
      how="$how; terminated $left remaining process(es)"
    fi
    left=$(fm_browser_tree_survivors | wc -l | tr -d ' ')
    if [ "$left" -gt 0 ]; then
      echo "$prefix: browser session $session for $task (bridge pid $pid, port $port) still has $left of $count process(es) alive after TERM and KILL: $(fm_browser_tree_survivors | tr '\n' ' ')" >&2
      rc=1
    else
      echo "$prefix: stopped browser session $session for $task (bridge pid $pid, port $port, $count process(es)): $how" >&2
    fi
  done
  return "$rc"
}

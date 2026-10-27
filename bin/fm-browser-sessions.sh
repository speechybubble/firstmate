#!/usr/bin/env bash
# fm-browser-sessions.sh - list the chrome-devtools-axi browser helpers on this
# machine and stop the ones a closed task of this home left behind.
#
# Usage:
#   fm-browser-sessions.sh list [--json]
#   fm-browser-sessions.sh stop <task-id>
#
# list prints every bridge this user can see with its owner, as read from the
# bridge's own environment (bin/fm-browser-sessions-lib.sh owns that reading).
# Each bridge has one scope relative to this home:
#   live_task     FM_HOME is this home and state/<task-id>.meta exists.
#   orphan        FM_HOME is this home and the task has no record any more.
#   other_home    the bridge names a task of another home, or a task and no home.
#   unattributed  the bridge carries no FM_TASK_ID (a firstmate's own session,
#                 or one started outside a task).
# --json prints {supported, helpers[]} with pid, session, port, task_id,
# fm_home, age_seconds, rss_kb, and scope; supported is false where /proc is
# unavailable, and helpers is then empty.
#
# stop stops this home's bridges for <task-id> exactly as teardown does, for a
# task that closed before teardown stopped browser sessions. It refuses while
# state/<task-id>.meta exists: a live task's browser belongs to its worker, and
# bin/fm-teardown.sh stops it once that task may close. Bridges of other homes
# and bridges without FM_TASK_ID are never touched.
# Exit status: 0 done (including nothing to stop), 1 a process survived or the
# task is still live, 2 usage error or no /proc on this platform.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-browser-sessions-lib.sh
. "$SCRIPT_DIR/fm-browser-sessions-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-browser-sessions.sh list [--json]
       fm-browser-sessions.sh stop <task-id>

list  show every chrome-devtools-axi browser helper with its task, home, age
      and memory, and whether it is this home's live task, an orphan of this
      home, another home's, or unattributed.
stop  stop this home's helpers for a task that has already closed.
EOF
}

task_id_valid() {
  local LC_ALL=C
  case "${1-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

helper_scope() {  # <task-id> <fm-home>
  if [ -z "$1" ]; then
    echo unattributed
  elif ! fm_browser_home_matches "$2" "$FM_HOME"; then
    echo other_home
  elif task_id_valid "$1" && [ -e "$STATE/$1.meta" ]; then
    echo live_task
  else
    echo orphan
  fi
}

list_helpers() {  # <json:0|1>
  local json=$1 rows line pid session port task home age rss scope
  if ! fm_browser_supported; then
    if [ "$json" = 1 ]; then
      printf '{"supported":false,"helpers":[]}\n'
      return 0
    fi
    echo "fm-browser-sessions: /proc is unavailable here; browser helpers cannot be listed" >&2
    return 2
  fi
  rows=$(fm_browser_bridges)
  if [ "$json" = 1 ]; then
    command -v jq >/dev/null 2>&1 || { echo "fm-browser-sessions: jq not found" >&2; return 1; }
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS=$FM_BROWSER_FS read -r pid session port task home age rss <<< "$line"
      printf '%s%s%s\n' "$line" "$FM_BROWSER_FS" "$(helper_scope "$task" "$home")"
    done <<EOF | jq -Rn '
      def opt($v): if $v == "" then null else $v end;
      {supported:true,
       helpers:([inputs | split("\u001f")
         | {pid:(.[0] | tonumber), session:.[1], port:.[2],
            task_id:opt(.[3]), fm_home:opt(.[4]),
            age_seconds:(.[5] | tonumber), rss_kb:(.[6] | tonumber), scope:.[7]}]
         | sort_by(.pid))}'
$rows
EOF
    return 0
  fi
  if [ -z "$rows" ]; then
    echo "No browser helpers running."
    return 0
  fi
  printf '%-8s %-13s %-28s %-24s %8s %9s  %s\n' PID SCOPE TASK SESSION AGE RSS_MB HOME
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$FM_BROWSER_FS read -r pid session port task home age rss <<< "$line"
    scope=$(helper_scope "$task" "$home")
    printf '%-8s %-13s %-28s %-24s %7sh %9s  %s\n' "$pid" "$scope" "${task:--}" "$session" \
      "$((age / 3600))" "$((rss / 1024))" "${home:--}"
  done <<EOF
$rows
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  list)
    case "${2:-}" in
      --json) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; list_helpers 1; exit $? ;;
      "") [ "$#" -eq 1 ] || { usage >&2; exit 2; }; list_helpers 0; exit $? ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  stop)
    if [ "$#" -ne 2 ] || ! task_id_valid "$2"; then usage >&2; exit 2; fi
    if [ -e "$STATE/$2.meta" ]; then
      echo "REFUSED: $2 is still a live task of this home; its browser sessions stop when bin/fm-teardown.sh closes it." >&2
      exit 1
    fi
    fm_browser_stop_task "$FM_HOME" "$2" fm-browser-sessions
    rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "fm-browser-sessions: /proc is unavailable here; nothing was stopped" >&2
    elif [ "$FM_BROWSER_MATCHED" -eq 0 ]; then
      echo "fm-browser-sessions: no browser sessions of this home for $2"
    fi
    exit "$rc"
    ;;
  *) usage >&2; exit 2 ;;
esac

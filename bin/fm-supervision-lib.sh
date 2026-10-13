# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/fm-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         or a registered custom check
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check id beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  FM_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ]; then
      continue
    fi
    [ -e "$state/$id.check-trust" ] || continue
    FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# The supervision fault record is state/.codex-watch-error: the failure
# bin/fm-codex-stop-watch.sh leaves when its Stop-owned cycle could not run the
# watcher or deliver a durable wake, and clears with fm_supervision_fault_clear
# on its next successful delivery. bin/fm-guard.sh prints it at the top of
# every drain, for MAIN and the supervision branch alike. A branch's chat never
# reaches MAIN, so bin/fm-branch-report.sh accepts only --verdict captain while
# the printed fault is unreported, and a recorded captain report marks it
# reported (state/.supervision-fault-reported, keyed to the fault's text). The
# same text rewritten before a clear is the same fault; a different text, or
# any fault after a clear, is a new one that must be reported again.

# fm_supervision_fault_text <state-dir>
# Prints the fault, bounded to 2048 bytes, and exits 0; exits 1 when none.
fm_supervision_fault_text() {
  local fault="$1/.codex-watch-error"
  [ -f "$fault" ] && [ ! -L "$fault" ] && [ -s "$fault" ] || return 1
  head -c 2048 "$fault"
}

# fm_supervision_fault_unreported <state-dir>
# Prints the key of a fault no captain report has carried yet and exits 0;
# exits 1 when there is no fault or it was already reported.
fm_supervision_fault_unreported() {
  local text key
  text=$(fm_supervision_fault_text "$1") || return 1
  key=$(printf '%s' "$text" | cksum | awk '{ print $1 "-" $2 }') || return 1
  [ -n "$key" ] || return 1
  [ "$(cat "$1/.supervision-fault-reported" 2>/dev/null)" != "$key" ] || return 1
  printf '%s\n' "$key"
}

# fm_supervision_fault_mark_reported <state-dir> <key>
# Records that a captain report carried the fault with this key.
fm_supervision_fault_mark_reported() {
  local tmp
  tmp=$(mktemp "$1/.supervision-fault-reported.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1/.supervision-fault-reported"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# fm_supervision_fault_clear <state-dir>
# Ends the fault: removes the record and its reported mark together.
fm_supervision_fault_clear() {
  rm -f "$1/.codex-watch-error" "$1/.supervision-fault-reported"
}

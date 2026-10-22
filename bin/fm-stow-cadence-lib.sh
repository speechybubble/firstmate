#!/usr/bin/env bash
# fm-stow-cadence-lib.sh - the one owner of the per-session compaction counter
# and the stow-required record behind the automatic stow cadence
# (docs/turnend-guard.md "Stow pass required").
#
# Why: a compaction summary is where captain corrections get lost, and the
# captain's chosen remedy is a stow pass every second compaction of a primary
# session. The compact session-start digest counts compactions here, the
# turn-end guard blocks a stop while a pass is owed, and the stow skill's last
# step runs bin/fm-stow-mark.sh to record the pass and release the block.
#
# Records, all regular files directly under <state>, each a key=value list:
#   .compactions     pid=<lock pid> session=<lock session or empty>
#                    count=<compactions seen for that pid> stowed_at=<count at
#                    the last recorded stow pass, 0 when none>
#   .stow-required   pid= session= count=<the compaction that made the pass
#                    due> at=<epoch>; present exactly while a pass is owed
#   .stow-pass       pid= session= count= at=<epoch>; the marker of the last
#                    recorded pass
# The pid is the harness pid state/.lock records and the session is the
# trusted id state/.lock-session records when one exists; a record naming
# another pid belongs to a previous session and is replaced, never continued.
#
# Cadence: config/stow-every-compactions, one positive base-10 integer plus one
# newline, default 2 (the captain's number). A malformed value falls back to
# the default and FM_STOW_CADENCE_NOTE says so; it is a cadence, not a safety
# gate, so it degrades to the default rather than refusing.
#
# Functions (every one returns 1 instead of acting when <state> is unusable):
#   fm_stow_cadence_every <config>
#       Prints the effective cadence and sets FM_STOW_CADENCE_EVERY to it;
#       sets FM_STOW_CADENCE_NOTE on fallback (call it outside a command
#       substitution to read either variable).
#   fm_stow_cadence_record_compaction <state> <config> <pid> [session]
#       Counts one compaction for <pid> and decides whether a pass is now due.
#       Returns 0 when it wrote .stow-required this call, 1 otherwise. Sets
#       FM_STOW_CADENCE_COUNT, FM_STOW_CADENCE_SINCE (compactions since the
#       last pass), FM_STOW_CADENCE_EVERY, and FM_STOW_CADENCE_DUE (0|1, also
#       1 when an earlier .stow-required for this pid is still unanswered).
#   fm_stow_cadence_required <state> <pid> [session]
#       Returns 0 when .stow-required exists for the live session <pid> (and
#       for <session> when both sides name one), setting
#       FM_STOW_CADENCE_REQUIRED_COUNT and FM_STOW_CADENCE_REQUIRED_AT.
#   fm_stow_cadence_mark <state> <pid> [session]
#       Records a completed pass: writes .stow-pass, sets stowed_at to the
#       current count in .compactions (creating it at count 0 for a session
#       that has not compacted yet), and removes .stow-required.
#   fm_stow_cadence_lock_identity <state>
#       Prints "<pid> <session>" from state/.lock and state/.lock-session, or
#       returns 1 when the lock holds no numeric pid.

FM_STOW_CADENCE_DEFAULT_EVERY=2
FM_STOW_CADENCE_NOTE=

_fm_stow_cadence_regular() {  # <path>: a regular, non-symlink file
  [ -f "$1" ] && [ ! -L "$1" ]
}

_fm_stow_cadence_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

_fm_stow_cadence_write() {  # <file> <content>
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$2" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$1" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

fm_stow_cadence_lock_identity() {  # <state>
  local pid session=''
  _fm_stow_cadence_regular "$1/.lock" || return 1
  pid=$(head -n 1 "$1/.lock" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if _fm_stow_cadence_regular "$1/.lock-session"; then
    session=$(head -n 1 "$1/.lock-session" 2>/dev/null || true)
    case "$session" in *[!A-Za-z0-9._-]*) session='' ;; esac
  fi
  printf '%s %s\n' "$pid" "$session"
}

fm_stow_cadence_every() {  # <config>
  local file="$1/stow-every-compactions" value
  FM_STOW_CADENCE_NOTE=
  FM_STOW_CADENCE_EVERY=$FM_STOW_CADENCE_DEFAULT_EVERY
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' "$FM_STOW_CADENCE_EVERY"
    return 0
  fi
  if _fm_stow_cadence_regular "$file" && value=$(cat "$file" 2>/dev/null) \
    && [ "$(printf '%s' "$value" | wc -l | tr -d ' ')" -eq 0 ] \
    && printf '%s' "$value" | grep -Eq '^[1-9][0-9]*$'; then
    FM_STOW_CADENCE_EVERY=$value
    printf '%s\n' "$FM_STOW_CADENCE_EVERY"
    return 0
  fi
  FM_STOW_CADENCE_NOTE="config/stow-every-compactions is malformed (one positive integer plus one newline expected); using the default $FM_STOW_CADENCE_DEFAULT_EVERY"
  printf '%s\n' "$FM_STOW_CADENCE_EVERY"
}

fm_stow_cadence_record_compaction() {  # <state> <config> <pid> [session]
  local state=$1 config=$2 pid=$3 session=${4:-} file count=0 stowed_at=0 old_pid='' every
  FM_STOW_CADENCE_COUNT=0
  FM_STOW_CADENCE_SINCE=0
  FM_STOW_CADENCE_DUE=0
  [ -d "$state" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_stow_cadence_every "$config" >/dev/null
  every=$FM_STOW_CADENCE_EVERY
  file="$state/.compactions"
  if _fm_stow_cadence_regular "$file"; then
    old_pid=$(_fm_stow_cadence_field "$file" pid)
    if [ "$old_pid" = "$pid" ]; then
      count=$(_fm_stow_cadence_field "$file" count)
      stowed_at=$(_fm_stow_cadence_field "$file" stowed_at)
    fi
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$stowed_at" in ''|*[!0-9]*) stowed_at=0 ;; esac
  count=$((count + 1))
  [ "$stowed_at" -le "$count" ] || stowed_at=0
  _fm_stow_cadence_write "$file" "pid=$pid
session=$session
count=$count
stowed_at=$stowed_at
" || return 1
  FM_STOW_CADENCE_COUNT=$count
  FM_STOW_CADENCE_SINCE=$((count - stowed_at))
  if _fm_stow_cadence_regular "$state/.stow-required" \
    && [ "$(_fm_stow_cadence_field "$state/.stow-required" pid)" = "$pid" ]; then
    FM_STOW_CADENCE_DUE=1
    return 1
  fi
  rm -f "$state/.stow-required" 2>/dev/null || true
  [ "$FM_STOW_CADENCE_SINCE" -ge "$every" ] || return 1
  _fm_stow_cadence_write "$state/.stow-required" "pid=$pid
session=$session
count=$count
at=$(date +%s)
" || return 1
  FM_STOW_CADENCE_DUE=1
  return 0
}

fm_stow_cadence_required() {  # <state> <pid> [session]
  local state=$1 pid=$2 session=${3:-} file recorded_pid recorded_session
  FM_STOW_CADENCE_REQUIRED_COUNT=
  FM_STOW_CADENCE_REQUIRED_AT=
  file="$state/.stow-required"
  _fm_stow_cadence_regular "$file" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  recorded_pid=$(_fm_stow_cadence_field "$file" pid)
  [ "$recorded_pid" = "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  recorded_session=$(_fm_stow_cadence_field "$file" session)
  if [ -n "$session" ] && [ -n "$recorded_session" ] && [ "$session" != "$recorded_session" ]; then
    return 1
  fi
  FM_STOW_CADENCE_REQUIRED_COUNT=$(_fm_stow_cadence_field "$file" count)
  FM_STOW_CADENCE_REQUIRED_AT=$(_fm_stow_cadence_field "$file" at)
  return 0
}

fm_stow_cadence_mark() {  # <state> <pid> [session]
  local state=$1 pid=$2 session=${3:-} file count=0 old_pid=''
  [ -d "$state" ] || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  file="$state/.compactions"
  if _fm_stow_cadence_regular "$file"; then
    old_pid=$(_fm_stow_cadence_field "$file" pid)
    [ "$old_pid" != "$pid" ] || count=$(_fm_stow_cadence_field "$file" count)
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  _fm_stow_cadence_write "$file" "pid=$pid
session=$session
count=$count
stowed_at=$count
" || return 1
  _fm_stow_cadence_write "$state/.stow-pass" "pid=$pid
session=$session
count=$count
at=$(date +%s)
" || return 1
  rm -f "$state/.stow-required" 2>/dev/null || true
  FM_STOW_CADENCE_COUNT=$count
  return 0
}

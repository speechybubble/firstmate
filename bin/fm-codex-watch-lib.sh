#!/usr/bin/env bash
# Codex Stop-owned watcher binding and durable notification watermark.
# Sourced after fm-wake-lib.sh. No native message is sent under a queue lock.
# The owner record lives inside the identity-checked hook lock; the watermark
# is scoped to the native process identity AND thread, not a reusable PID/name.

fm_codex_watch_owner_valid() {
  local record="$STATE/.codex-watch.lock/target.json" native_pid native_identity owner_pid owner_identity root codex_home
  [ ! -e "$STATE/.afk" ] || return 1
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  jq -e 'type == "object" and .version == 1 and
    (.thread | type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")) and
    (.native_pid | type == "number") and (.owner_pid | type == "number") and
    (.native_identity | type == "string") and (.owner_identity | type == "string") and
    (.root | type == "string") and (.codex_home | type == "string")' "$record" >/dev/null 2>&1 || return 1
  native_pid=$(jq -r .native_pid "$record") || return 1
  native_identity=$(jq -r .native_identity "$record") || return 1
  owner_pid=$(jq -r .owner_pid "$record") || return 1
  owner_identity=$(jq -r .owner_identity "$record") || return 1
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$native_pid" ] || return 1
  [ "$(cat "$STATE/.codex-watch.lock/pid" 2>/dev/null)" = "$owner_pid" ] || return 1
  [ "${FM_CODEX_WATCH_OWNER_PID:-}" = "$owner_pid" ] || return 1
  [ "$(fm_pid_identity "$native_pid")" = "$native_identity" ] || return 1
  [ "$(fm_pid_identity "$owner_pid")" = "$owner_identity" ] || return 1
  root=$(cd "$FM_ROOT" && pwd -P) || return 1
  codex_home=$(cd "${CODEX_HOME:-$HOME/.codex}" && pwd -P) || return 1
  [ "$(jq -r .root "$record")" = "$root" ] || return 1
  [ "$(jq -r .codex_home "$record")" = "$codex_home" ] || return 1
}

# Returns 0 with FM_CODEX_PENDING_SEQ > 0 only for a not-yet-notified row,
# 1 for no new row or lost ownership, and 2 for an unavailable queue snapshot.
# Callers must surface 2 as failure, never silently treat contention as empty.
fm_codex_watch_pending() {
  local record="$STATE/.codex-watch.lock/target.json" delivered="$STATE/.codex-watch-delivered" seq=0 previous=0 rc=0
  FM_CODEX_PENDING_SEQ=0
  fm_codex_watch_owner_valid || return 1
  fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 5 || return 2
  if [ -e "$FM_WAKE_QUEUE" ]; then
    seq=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { if ($2 > max) max=$2 } END { print max+0 }' "$FM_WAKE_QUEUE" 2>/dev/null) || rc=2
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || return 2
  [ "$rc" -eq 0 ] || return "$rc"
  fm_codex_watch_owner_valid || return 1
  if [ -f "$delivered" ] && [ ! -L "$delivered" ]; then
    previous=$(jq -er --slurpfile target "$record" '
      select(.thread == $target[0].thread and .native_identity == $target[0].native_identity)
      | .seq | select(type == "number" and . >= 0)' "$delivered" 2>/dev/null) || previous=0
  fi
  [ "$seq" -gt "$previous" ] || return 1
  FM_CODEX_PENDING_SEQ=$seq
}

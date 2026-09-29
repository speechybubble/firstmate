#!/usr/bin/env bash
# Native Codex asynchronous Stop hook: one hook-owned watcher cycle, followed
# by one coalesced native queue notification. Codex owns the process tree and
# timeout; this is not a daemon and never backgrounds a shell watcher.
#
# Only an owning native Codex primary/secondmate may bind a target. Each Stop
# may start the next cycle, including a Stop continuation; the unchanged sync
# guard still owns its one-block safety bound. The watcher observes committed
# durable rows, status files and registered checks while the model is parked.
# Queue acceptance advances a delivery watermark only; semantic drain/ack is
# always the model's job. Unacked rows are not repeatedly notified in one native
# generation. A later row gets a later watermark even during an ack race.
#
# Native delivery has two attempts of at most 15s. A successor waits up to 40s
# for the prior hook owner without stealing its live lock. Queue snapshots wait
# up to 5s under that owner; contention is not an empty queue. Exhausted waits
# or delivery failure leave all rows and an advisory for fm-guard.sh; no recursive
# wake, unbounded retry or fake ack.
# AFK, scope/owner loss and native process reuse suppress delivery. A crash
# after acceptance but before watermark commit can duplicate a notification,
# never consume work. Acceptance can duplicate after a crash; it is not an ack.
# docs/supervision-protocols/codex.md owns the configured hook lifetime, expiry
# coverage gap, recovery requirements and native-evidence limits.
set -u
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
PAYLOAD=$(cat 2>/dev/null) || exit 0
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ ! -e "$STATE/.afk" ] || exit 0
NATIVE_PID=$(fm_harness_ancestry_pid) || exit 0
[ "$(basename "$(ps -o comm= -p "$NATIVE_PID" 2>/dev/null)")" = codex ] || exit 0
THREAD=$(printf '%s' "$PAYLOAD" | jq -er '
  select(.hook_event_name == "Stop") | .session_id |
  select(type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))') || exit 0
CODEX_HOME=$(cd "${CODEX_HOME:-$HOME/.codex}" && pwd -P) || exit 0
export CODEX_HOME
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-codex-watch-lib.sh
. "$SCRIPT_DIR/fm-codex-watch-lib.sh"
fm_supervision_needed "$STATE" || [ -s "$FM_WAKE_QUEUE" ] || exit 0
# Native tools can have acquired the numeric lock inside a PID namespace that
# ended with their tool process. Use the existing acquisition owner for a
# provably stale numeric lock, as the Claude Stop owner does. Never steal a
# live foreign owner or synthesize a missing/malformed session lock.
if ! fm_session_lock_owned_by_self "$STATE"; then
  OLD_PID=$(cat "$STATE/.lock" 2>/dev/null) || exit 0
  case "$OLD_PID" in ''|*[!0-9]*) exit 0 ;; esac
  fm_harness_pid_alive "$OLD_PID" && exit 0
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi
fail() {
  printf 'Codex Stop-owned supervision failed: %s. Durable wakes remain unacknowledged; inspect the native hook and queue delivery.\n' "$1" | tee "$STATE/.codex-watch-error" >&2
  exit 1
}
OWNER_LOCK="$STATE/.codex-watch.lock"
# A native successor can finish before the previous queue CLI returns. Wait
# through its two bounded delivery attempts instead of silently discarding
# the successor Stop. This lock is distinct from the durable queue lock.
fm_lock_acquire_wait_bounded "$OWNER_LOCK" 40 || fail 'previous Stop owner did not release within 40s'
OWNER_DIR=$(fm_lock_link_owner "$OWNER_LOCK") || exit 1
OUT=
cleanup() {
  [ -z "$OUT" ] || rm -f "$OUT"
  rm -f "$OWNER_DIR/target.json" "$OWNER_DIR/delivered"
  fm_lock_release "$OWNER_LOCK"
}
trap cleanup EXIT
trap 'fail "hook interrupted"' HUP INT TERM
fm_current_pid FM_CODEX_WATCH_OWNER_PID || fail 'cannot identify hook'
export FM_CODEX_WATCH_OWNER_PID
NATIVE_IDENTITY=$(fm_pid_identity "$NATIVE_PID") || fail 'native identity unavailable'
OWNER_IDENTITY=$(fm_pid_identity "$FM_CODEX_WATCH_OWNER_PID") || fail 'hook identity unavailable'
ROOT_REAL=$(cd "$FM_ROOT" && pwd -P) || exit 0
jq -n --arg thread "$THREAD" --arg home "$CODEX_HOME" --arg root "$ROOT_REAL" \
  --arg native "$NATIVE_IDENTITY" --arg owner "$OWNER_IDENTITY" \
  --argjson pid "$NATIVE_PID" --argjson hook "$FM_CODEX_WATCH_OWNER_PID" \
  '{version:1,thread:$thread,codex_home:$home,root:$root,native_pid:$pid,
    native_identity:$native,owner_pid:$hook,owner_identity:$owner}' > "$OWNER_LOCK/target.json" || fail 'binding write failed'
fm_codex_watch_owner_valid || exit 0
# Respect the existing configured relay cadence, exactly as other Stop owners do.
# shellcheck source=/dev/null
[ ! -f "$CONFIG/x-mode.env" ] || . "$CONFIG/x-mode.env"
OUT=$(mktemp "${TMPDIR:-/tmp}/fm-codex-stop.XXXXXX") || fail 'cannot create output file'
fm_codex_watch_pending
RC=$?
if [ "$RC" -ne 0 ]; then
  [ "$RC" -eq 1 ] || fail 'queue snapshot unavailable after bounded acquisition'
  "$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1
  RC=$?
  fm_codex_watch_owner_valid || exit 0
  [ "$RC" -eq 0 ] || fail "watcher cycle exited $RC: $(tail -c 1024 "$OUT")"
  # A row may have been handled while the watcher returned. No synthetic wake
  # for an empty/replayed recovery notice; the next Stop owns another cycle.
  fm_codex_watch_pending
  RC=$?
  [ "$RC" -ne 1 ] || exit 0
  [ "$RC" -eq 0 ] || fail 'queue snapshot unavailable after bounded acquisition'
fi
SEQ=$FM_CODEX_PENDING_SEQ
MESSAGE='Firstmate Codex watcher: durable events await handling. Run bin/fm-wake-drain.sh, semantically handle its emitted events within existing authority and holds, then run the exact printed WAKE_ACK_REQUIRED command. Do not resume held work. The native Stop hook owns the next watcher; do not manually rearm it.'
for attempt in 1 2; do
  fm_codex_watch_owner_valid || exit 0
  if fm_run_timed 15 codex queue --thread "$THREAD" --message "$MESSAGE" > "$OUT" 2>&1; then
    fm_codex_watch_owner_valid || exit 0
    jq --argjson seq "$SEQ" '{thread,native_identity,seq:$seq}' "$OWNER_LOCK/target.json" > "$OWNER_LOCK/delivered" || fail 'watermark write failed'
    mv "$OWNER_LOCK/delivered" "$STATE/.codex-watch-delivered" || fail 'watermark commit failed'
    rm -f "$STATE/.codex-watch-error"
    exit 0
  fi
done
fail "native queue delivery failed: $(tail -c 1024 "$OUT")"

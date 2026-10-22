#!/usr/bin/env bash
# fm-stow-mark.sh - record that a stow pass finished in this home.
#
# Usage: fm-stow-mark.sh [--help]
#
# The stow skill runs this as the last step of every pass. It writes the
# state/.stow-pass marker, resets the compaction cadence for the session that
# holds state/.lock, and removes state/.stow-required, which releases the
# turn-end guard's "stow pass required" block (bin/fm-stow-cadence-lib.sh owns
# the records; docs/turnend-guard.md "Stow pass required" owns the behavior).
#
# Exit status: 0 when the pass was recorded; 1 with a diagnostic when this home
# has no usable session lock or the state directory refused the write, so a
# pass that cannot be recorded is reported rather than assumed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  '') ;;
  -h|--help)
    sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-stow-mark.sh" | sed 's/^# \{0,1\}//; $d'
    exit 0
    ;;
  *)
    printf 'fm-stow-mark: unknown argument: %s\n' "$1" >&2
    printf 'usage: fm-stow-mark.sh [--help]\n' >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-stow-cadence-lib.sh
. "$SCRIPT_DIR/fm-stow-cadence-lib.sh"

if ! identity=$(fm_stow_cadence_lock_identity "$STATE"); then
  printf 'fm-stow-mark: %s/.lock holds no session pid, so this pass cannot be recorded for a session\n' "$STATE" >&2
  exit 1
fi
pid=${identity%% *}
session=${identity#* }
if ! fm_stow_cadence_mark "$STATE" "$pid" "$session"; then
  printf 'fm-stow-mark: could not write the stow records under %s\n' "$STATE" >&2
  exit 1
fi
printf 'stow pass recorded for session pid %s at compaction %s; the next pass is due after the configured cadence (bin/fm-stow-cadence-lib.sh)\n' \
  "$pid" "$FM_STOW_CADENCE_COUNT"

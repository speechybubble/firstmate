#!/usr/bin/env bash
# fm-coordination-trace.sh - read-only trace of coordination between this main
# firstmate home, one second mate and that mate's workers.
#
# Resolves the records from the home and hands them to bin/fm-coordination-trace.py,
# whose header owns the hop definitions, the record list and the fallback rules.
# Nothing is written except an optional --json dump; the mate's home is read only.
#
# Usage:
#   fm-coordination-trace.sh [<mate-id>] [--since YYYY-MM-DD] [--json <file>]
#                            [--state <dir>] [--mate-home <dir>] [--transcript-dir <dir>]
#
# Defaults: the mate is the only entry in data/secondmates.md (required when there
# are several); state is $FM_STATE_OVERRIDE or $FM_HOME/state; the mate home is the
# registry entry's "home:" field; the transcript dir is Claude Code's project dir
# for $FM_HOME ($HOME/.claude/projects/<FM_HOME with / as ->) when it exists, else
# captain ask and ack times are reported unavailable. --since defaults to
# 2026-10-09 (the Claude fleet migration).
#
# Exit codes: 0 traced; 2 usage or an unresolvable input (named on stderr).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MATE="" MATE_HOME="" TRANSCRIPTS="" ; PASS=()

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d' >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE=$2; shift 2 ;;
    --mate-home) MATE_HOME=$2; shift 2 ;;
    --transcript-dir) TRANSCRIPTS=$2; shift 2 ;;
    --since|--json) PASS+=("$1" "$2"); shift 2 ;;
    -h|--help) usage ;;
    --*) echo "fm-coordination-trace: unknown option $1" >&2; usage ;;
    *) [ -z "$MATE" ] || { echo "fm-coordination-trace: one mate id only" >&2; usage; }; MATE=$1; shift ;;
  esac
done

registry="$FM_HOME/data/secondmates.md"
if [ -z "$MATE" ]; then
  if [ -f "$registry" ]; then
    mapfile -t ids < <(sed -n 's/^- \([a-z0-9][a-z0-9-]*\) - .*/\1/p' "$registry")
    if [ "${#ids[@]}" -eq 1 ]; then MATE=${ids[0]}; else
      echo "fm-coordination-trace: ${#ids[@]} secondmates registered; name one" >&2; exit 2; fi
  else
    echo "fm-coordination-trace: no secondmate registry at $registry; name a mate and pass --mate-home" >&2; exit 2
  fi
fi
if [ -z "$MATE_HOME" ] && [ -f "$registry" ]; then
  MATE_HOME=$(sed -n "s/^- $MATE - .*(home: \([^;)]*\).*/\1/p" "$registry" | head -1)
fi
[ -n "$MATE_HOME" ] && [ -d "$MATE_HOME" ] || { echo "fm-coordination-trace: mate home for $MATE not found (pass --mate-home)" >&2; exit 2; }
[ -d "$STATE" ] || { echo "fm-coordination-trace: state dir $STATE not found" >&2; exit 2; }
if [ -z "$TRANSCRIPTS" ]; then
  candidate="${HOME:-}/.claude/projects/$(printf '%s' "$FM_HOME" | tr '/.' '--')"
  [ -d "$candidate" ] && TRANSCRIPTS=$candidate
fi

exec python3 -I "$SCRIPT_DIR/fm-coordination-trace.py" --state "$STATE" --mate "$MATE" --mate-home "$MATE_HOME" \
  ${TRANSCRIPTS:+--transcript-dir "$TRANSCRIPTS"} "${PASS[@]}"

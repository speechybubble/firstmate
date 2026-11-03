#!/usr/bin/env bash
# fm-quote-check.sh - keep a source of the captain's own typed words and check
# that a captain-facing page quotes them word for word.
#
# bin/fm-quote-check.py's header owns what counts as the captain's typed words,
# the markers that find a page's quotes, and what counts as a match. This
# wrapper owns the homes, the source location and its freshness.
#
# Usage:
#   fm-quote-check.sh check <page>... [--marker <marker>]... [--json] [--verbose]
#                           [--source <file>] [--max-age <hours>]
#   fm-quote-check.sh refresh [--out <file>]
#   fm-quote-check.sh status
#
# check    Find each page's quotes of the captain by every --marker given
#          (default class:verbatim; also attributed and regex:<re>) and look each
#          one up in the source. Prints every quote that is not verbatim
#          (misquoted, verbatim with omissions, or skipped) and a one-line
#          count; --verbose prints the verbatim ones too and the source words
#          each ellipsis left out, --json prints the full result. Before checking, the home's source is rebuilt when
#          it is missing or older than --max-age hours (default 24), so it is
#          never more than a day behind; --source names a fixed source instead
#          and is never rebuilt.
# refresh  Rebuild the source now, on demand.
# status   Print the source's build time, message counts per channel and home,
#          and whether it is older than the default --max-age.
#
# Homes: the root home is $FM_HOME, or its parent when $FM_HOME is a local
# secondmate home (its .fm-secondmate-parent record names a local parent_home);
# the source covers the root home and every local secondmate in its
# data/secondmates.md. A remote secondmate's transcripts are not on this
# machine and are reported as skipped. A home's Claude Code transcripts are
# $HOME/.claude/projects/<home path with / and . as ->; Lavish's session store
# is ${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json. FM_QUOTE_HOMES
# (colon-separated) replaces the resolved home list.
#
# The source is $FM_HOME/data/captain-words/source.json, mode 0600 in a 0700
# directory: transcripts can hold secrets, so it stays home-local, data/ is
# never committed, and no command prints its text.
#
# Exit codes: 0 every quote verbatim (check) or done; 1 at least one quote is
# not in the captain's typed words or is verbatim with omissions; 2 usage
# error (including an unknown or invalid marker) or an unreadable input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SOURCE_DEFAULT="$FM_HOME/data/captain-words/source.json"
MAX_AGE_DEFAULT=24

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d' >&2; exit 2; }
die() { echo "fm-quote-check: $*" >&2; exit 2; }

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"

transcript_dir() { printf '%s/.claude/projects/%s\n' "${HOME:-}" "$(printf '%s' "$1" | tr '/.' '--')"; }

# Print the homes the source covers, one per line, root first.
resolve_homes() {
  local root=$FM_HOME line
  if [ -n "${FM_QUOTE_HOMES:-}" ]; then
    printf '%s\n' "$FM_QUOTE_HOMES" | tr ':' '\n' | sed '/^$/d'
    return
  fi
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" \
     && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ -d "$FM_SECONDMATE_PARENT_HOME" ]; then
    root=$FM_SECONDMATE_PARENT_HOME
  fi
  printf '%s\n' "$root"
  [ -f "$root/data/secondmates.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      echo "fm-quote-check: secondmate $SECONDMATE_REGISTRY_ID is remote; its transcripts are skipped" >&2
      continue
    fi
    printf '%s\n' "$SECONDMATE_REGISTRY_HOME"
  done < "$root/data/secondmates.md"
}

refresh() {  # <out>
  local out=$1 home args=() lavish
  while IFS= read -r home; do
    [ -d "$home" ] || { echo "fm-quote-check: home $home not found; skipped" >&2; continue; }
    args+=(--home "$home" --transcripts "$(transcript_dir "$home")")
  done < <(resolve_homes)
  [ "${#args[@]}" -gt 0 ] || die "no home to read"
  lavish="${LAVISH_AXI_STATE_DIR:-${HOME:-}/.lavish-axi}/state.json"
  [ -f "$lavish" ] && args+=(--lavish-state "$lavish")
  umask 077
  python3 -I "$SCRIPT_DIR/fm-quote-check.py" refresh --out "$out" \
    --operational-lib "$SCRIPT_DIR/fm-operational-input.sh" "${args[@]}"
}

# True when <file> exists and is younger than <hours>.
fresh() {  # <file> <hours>
  local mtime now
  [ -f "$1" ] || return 1
  mtime=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1") || return 1
  now=$(date +%s)
  [ $((now - mtime)) -lt $(($2 * 3600)) ]
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  check)
    source_file="" max_age=$MAX_AGE_DEFAULT pass=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --source) [ $# -ge 2 ] || usage; source_file=$2; shift 2 ;;
        --max-age) [ $# -ge 2 ] || usage; max_age=$2; shift 2 ;;
        --marker) [ $# -ge 2 ] || usage; pass+=(--marker "$2"); shift 2 ;;
        --json|--verbose) pass+=("$1"); shift ;;
        -h|--help) usage ;;
        --*) echo "fm-quote-check: unknown option $1" >&2; usage ;;
        *) pass+=("$1"); shift ;;
      esac
    done
    case "$max_age" in ''|*[!0-9]*) die "--max-age takes whole hours" ;; esac
    if [ -z "$source_file" ]; then
      source_file=$SOURCE_DEFAULT
      fresh "$source_file" "$max_age" || refresh "$source_file" >&2
    fi
    exec python3 -I "$SCRIPT_DIR/fm-quote-check.py" check --source "$source_file" ${pass[@]+"${pass[@]}"}
    ;;
  refresh)
    out=$SOURCE_DEFAULT
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
        -h|--help) usage ;;
        *) echo "fm-quote-check: unknown argument $1" >&2; usage ;;
      esac
    done
    refresh "$out"
    ;;
  status)
    [ $# -eq 0 ] || usage
    [ -f "$SOURCE_DEFAULT" ] || { echo "source: none at $SOURCE_DEFAULT; run refresh"; exit 0; }
    python3 -I - "$SOURCE_DEFAULT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("source: %s, built %s, %d messages" % (sys.argv[1], d.get("built_at"), len(d.get("messages", []))))
for k, v in sorted(d.get("counts", {}).items()):
    print("  %s: %d" % (k, v))
print("  Firstmate inputs excluded: %d" % d.get("excluded_operational", 0))
PY
    if fresh "$SOURCE_DEFAULT" "$MAX_AGE_DEFAULT"; then echo "fresh: yes"; else echo "fresh: no (older than ${MAX_AGE_DEFAULT}h)"; fi
    ;;
  -h|--help|"") usage ;;
  *) echo "fm-quote-check: unknown command $cmd" >&2; usage ;;
esac

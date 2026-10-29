#!/usr/bin/env bash
# fm-drain-filter-lib.sh - detect a filtered bin/fm-wake-drain.sh read in the
# current turn of a Claude transcript (docs/turnend-guard.md "Filtered drain
# read").
#
# Why this exists: a drain read piped through grep, head, tail, cut, awk, or
# sed hides the sections the turn must handle (OPEN DECISIONS, UNREAD STATUS,
# RECORD DIVERGENCE, WAKE_ACK_REQUIRED). The written rule against it held in
# zero of 139 consecutive reads once the captain's correction fell out of
# context, so the turn-end guard enforces it from the transcript instead.
# A whole-output reader (tee, cat, less, more) passes the read on whole, so it
# is not a filter; bin/fm-wake-drain.sh agrees that whole-output readers are
# not filters, and its runtime check refuses every other reader.
#
# Public entry points:
#   fm_drain_filter_scan <transcript-path> [tail-lines]
#     Returns 0 when the current turn's LAST drain read was filtered and no
#     later unfiltered read followed it, setting
#       FM_DRAIN_FILTER_TURN     - uuid of the turn's opening user entry, or
#                                  "window:<uuid>" when the bounded tail holds
#                                  no turn boundary (the turn is longer than
#                                  the window, which is still that one turn)
#       FM_DRAIN_FILTER_NAME     - the filter command the read was piped into
#       FM_DRAIN_FILTER_COMMAND  - the offending statement, single line,
#                                  bounded to 200 bytes
#     Returns 1 in every other case, including an unreadable, absent, or
#     non-Claude-shaped transcript and a missing jq: the predicate never
#     blocks on what it cannot read.
#
#   fm_drain_filter_classify
#     Reads ONE Bash command on stdin and prints one line per drain-related
#     statement, in statement order:
#       filtered<TAB><filter><TAB><statement>   a read piped into a filter,
#                                                or a filter later reading a
#                                                file the read was redirected to
#       unfiltered                               a read whose output reaches the
#                                                caller whole
#       redirect<TAB><file>                      a read sent to a file; it stays
#                                                unfiltered until a later filter
#                                                reads that file
#     Acknowledgement and listing invocations (--ack-through, --decisions,
#     --help) are not reads and print nothing. FM_DRAIN_FILTER_PENDING, a
#     newline-separated list of files earlier commands redirected a read into,
#     seeds the file-then-filter detection across commands.
#
# Cost: one tail, one jq, and one awk per Stop, whatever the turn's length.
# The per-command work stays inside that single awk because a process per
# command made a long turn cost seconds on hosts with slow process creation.
#
# Turn boundary: the last transcript entry of type user that is neither a
# tool_result carrier, a meta entry, nor a compaction summary. A compaction
# summary continues the turn it interrupted, so a read filtered before the
# compaction still counts. Sidechain (subagent) entries are ignored.
#
# Heuristics, stated so their limits are inspectable: statements split on
# newlines, `;`, `&&`, and `||`, pipelines on single `|`, without shell
# quoting awareness. A segment is a drain read only when fm-wake-drain.sh is
# the command it executes: the first word after any leading `VAR=value`
# assignments and `env`, `command`, `exec`, `nice`, `timeout <n>`, or
# `bash`/`sh` prefixes, so `grep -rn fm-wake-drain.sh docs | head` or
# `git diff -- bin/fm-wake-drain.sh | head` is ordinary source inspection, not
# a read. A redirected read that a later `cat` prints whole is cleared before
# any further filter on that file. A read captured in `$(...)` and filtered
# later through a variable is not detected. Both directions of error are bounded: a miss lets
# the existing instruction rule stand alone, as before, and a false hit costs
# one bounded block that names the exact unfiltered command.

# Result variables read by the caller (bin/fm-turnend-guard.sh).
# shellcheck disable=SC2034
FM_DRAIN_FILTER_TURN=
# shellcheck disable=SC2034
FM_DRAIN_FILTER_NAME=
# shellcheck disable=SC2034
FM_DRAIN_FILTER_COMMAND=

# One awk program for both entry points. mode=classify reads a raw command and
# prints verdict lines; mode=scan reads the jq stream ("T uuid", "U uuid",
# "C <json string>") and prints one "turn<TAB>filter<TAB>statement" line and
# exits 0 when the turn ends on a filtered read, otherwise exits 1.
_fm_drain_filter_awk() {  # <mode>
  awk -v mode="$1" -v pending_files="${FM_DRAIN_FILTER_PENDING:-}" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    # The command a segment executes, after leading assignments and wrappers.
    function exec_word(s,    w) {
      s = trim(s)
      while (1) {
        if (s ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/) { sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/, "", s); continue }
        if (s ~ /^(env|command|exec|nice|bash|sh)[[:space:]]+/) { sub(/^(env|command|exec|nice|bash|sh)[[:space:]]+/, "", s); continue }
        if (s ~ /^timeout[[:space:]]+[0-9]+[smh]?[[:space:]]+/) { sub(/^timeout[[:space:]]+[0-9]+[smh]?[[:space:]]+/, "", s); continue }
        break
      }
      w = s; sub(/[[:space:]].*$/, "", w)
      gsub(/[\x27"]/, "", w)
      return w
    }
    function is_drain(seg,    w) { w = exec_word(seg); return w ~ /(^|\/)fm-wake-drain(\.sh)?$/ }
    function first_word(s,    w) { s = trim(s); w = s; sub(/[[:space:]].*$/, "", w); return w }
    function is_filter(w) { return w ~ /^(grep|egrep|fgrep|head|tail|cut|awk|sed)$/ }
    function excerpt(s) { s = trim(s); gsub(/\t/, " ", s); if (length(s) > 200) s = substr(s, 1, 197) "..."; return s }
    function redirect_target(seg,    rest) {
      if (match(seg, />>?[[:space:]]*[^[:space:]&;|]+/)) {
        rest = substr(seg, RSTART, RLENGTH)
        sub(/^>>?[[:space:]]*/, "", rest)
        if (rest == "/dev/null") return ""
        return rest
      }
      return ""
    }
    function tee_target(seg,    w) {
      w = trim(seg)
      if (w !~ /^tee([[:space:]]|$)/) return ""
      sub(/^tee[[:space:]]+/, "", w)
      while (w ~ /^-[^[:space:]]*[[:space:]]+/) sub(/^-[^[:space:]]*[[:space:]]+/, "", w)
      sub(/[[:space:]].*$/, "", w)
      if (w == "" || w == "/dev/null" || w ~ /^-/) return ""
      return w
    }
    # Decode a JSON string literal (with its quotes) into raw text.
    function json_decode(s,    out, i, c, n) {
      s = substr(s, 2, length(s) - 2)
      out = ""; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c != "\\") { out = out c; i++; continue }
        c = substr(s, i + 1, 1)
        if (c == "n") out = out "\n"
        else if (c == "t") out = out "\t"
        else if (c == "r") out = out "\r"
        else if (c == "u") { out = out "?"; i += 4 }
        else out = out c
        i += 2
      }
      return out
    }
    # Record one statement verdict: print it in classify mode, fold it into the
    # turn state in scan mode.
    function verdict(kind, name, stmt) {
      ordinal++
      if (mode == "classify") {
        if (kind == "filtered") printf "filtered\t%s\t%s\n", name, excerpt(stmt)
        else if (kind == "redirect") printf "redirect\t%s\n", name
        else print "unfiltered"
        return
      }
      if (kind == "filtered") { last_filtered = ordinal; filter_name = name; filter_stmt = excerpt(stmt) }
      else last_unfiltered = ordinal
    }
    function classify_command(text,    count, stmts, s, stmt, nseg, segs, drain, k, w, t, hit, f) {
      gsub(/\\\n/, " ", text)
      gsub(/&&/, "\n", text); gsub(/\|\|/, "\n", text); gsub(/;/, "\n", text)
      count = split(text, stmts, "\n")
      for (s = 1; s <= count; s++) {
        stmt = stmts[s]
        if (trim(stmt) == "") continue
        nseg = split(stmt, segs, "|")
        drain = 0
        for (k = 1; k <= nseg; k++) {
          if (is_drain(segs[k])) {
            if (segs[k] ~ /--ack-through|--decisions|--help|(^|[[:space:]])-h([[:space:]]|$)/) { drain = -1; break }
            drain = k; break
          }
        }
        if (drain > 0) {
          hit = ""
          for (k = drain + 1; k <= nseg; k++) {
            w = first_word(segs[k])
            if (is_filter(w)) { hit = w; break }
            t = tee_target(segs[k])
            if (t != "") files[++pending] = t
          }
          if (hit != "") { verdict("filtered", hit, stmt); continue }
          t = redirect_target(segs[drain])
          if (t != "") { files[++pending] = t; verdict("redirect", t, stmt); continue }
          if (pending > 0 && tee_target(segs[nseg]) != "") { verdict("redirect", files[pending], stmt); continue }
          verdict("unfiltered", "", stmt)
          continue
        }
        if (drain == -1 || pending == 0) continue
        # A whole read of a redirected file (cat with no filter after it)
        # clears that file: what followed was read in full.
        if (exec_word(segs[1]) == "cat") {
          hit = ""
          for (k = 2; k <= nseg; k++) { w = first_word(segs[k]); if (is_filter(w)) { hit = w; break } }
          if (hit == "") {
            for (f = 1; f <= pending; f++) if (files[f] != "" && index(stmt, files[f]) > 0) { files[f] = ""; verdict("unfiltered", "", stmt) }
            continue
          }
        }
        hit = ""
        for (k = 1; k <= nseg; k++) { w = first_word(segs[k]); if (is_filter(w)) { hit = w; break } }
        if (hit == "") continue
        for (f = 1; f <= pending; f++) {
          if (files[f] != "" && index(stmt, files[f]) > 0) { verdict("filtered", hit, stmt); break }
        }
      }
    }
    function reset_turn() { ordinal = 0; last_filtered = 0; last_unfiltered = 0; pending = 0; split("", files) }
    BEGIN {
      reset_turn()
      pending = split(pending_files, files, "\n")
      while (pending > 0 && files[pending] == "") pending--
      turn = ""; first = ""; raw = ""
    }
    mode == "classify" { raw = raw $0 "\n"; next }
    /^T / { turn = substr($0, 3); reset_turn(); next }
    /^U / { if (first == "") first = substr($0, 3); next }
    /^C / { classify_command(json_decode(substr($0, 3))); next }
    END {
      if (mode == "classify") { classify_command(raw); exit 0 }
      if (last_filtered == 0 || last_unfiltered >= last_filtered) exit 1
      if (turn == "") turn = "window:" first
      printf "%s\t%s\t%s\n", turn, filter_name, filter_stmt
      exit 0
    }
  '
}

fm_drain_filter_classify() {
  _fm_drain_filter_awk classify
}

fm_drain_filter_scan() {  # <transcript-path> [tail-lines]
  local transcript=$1 lines=${2:-3000} result
  FM_DRAIN_FILTER_TURN=
  FM_DRAIN_FILTER_NAME=
  FM_DRAIN_FILTER_COMMAND=
  case "$lines" in ''|*[!0-9]*|0) lines=3000 ;; esac
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  result=$(tail -n "$lines" -- "$transcript" 2>/dev/null | jq -R -r '
    fromjson? | select(type == "object" and .isSidechain != true)
    | if .type == "user" and .isMeta != true and .isCompactSummary != true
         and (((.message.content | type) == "string")
              or (((.message.content | type) == "array")
                  and all(.message.content[]; .type != "tool_result")))
      then "T " + (.uuid // "")
      elif .type == "assistant" and ((.message.content | type) == "array")
      then ("U " + (.uuid // "")),
           (.message.content[]
            | select(.type == "tool_use" and .name == "Bash")
            | "C " + ((.input.command // "") | tostring | @json))
      elif .type == "user" or .type == "assistant" then "U " + (.uuid // "")
      else empty end' 2>/dev/null | FM_DRAIN_FILTER_PENDING='' _fm_drain_filter_awk scan) || return 1
  [ -n "$result" ] || return 1
  FM_DRAIN_FILTER_TURN=${result%%$'\t'*}
  result=${result#*$'\t'}
  FM_DRAIN_FILTER_NAME=${result%%$'\t'*}
  # shellcheck disable=SC2034
  FM_DRAIN_FILTER_COMMAND=${result#*$'\t'}
  return 0
}

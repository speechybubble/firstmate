#!/usr/bin/env bash
# fm-request-continuity.sh - native request and outcome continuity for a Claude
# Code primary firstmate.
#
# The Pi primary gets the same guarantees from
# .pi/extensions/lib/fm-request-continuity.ts and the branch outcome receipt in
# .pi/extensions/fm-branch-supervision.ts. Claude Code has no extension tool
# surface, so this script is the Claude owner: tracked hooks in
# .claude/settings.json call its hook subcommands, and main calls its
# disposition and acknowledgement subcommands through Bash.
# docs/turnend-guard.md "Native input reconciliation" owns the behavior
# contract and its limits; this header owns the mechanics.
#
# Source of truth. The Claude transcript (the hook payload's transcript_path)
# is the native record of captain input and assistant replies, including
# entries from before a compaction. Nothing here is a task queue: dispositions
# only link handling to existing backlog records or to an actual reply, and no
# task is created, launched, cancelled, or completed.
#
# Receipt log. One append-only JSON line per event in
# <state>/request-intake/<session-id>.jsonl:
#   {"type":"start","after":<line|0>}             activation boundary
#   {"type":"disposition","id":<uuid>,"disposition":"recorded"|"reply",
#    "tasks":[...],"summary":<text>,"at":<line>}   handling link
#   {"type":"recovery","ids":[<uuid>...]}          automatic attempt made
#   {"type":"outcome-stage","through":<seq>,"at":<line>}  staged outcome ack
#   {"type":"outcome-commit","through":<seq>}      marker advanced
# <line> is the transcript's line count when the receipt was written, which
# orders it against transcript entries. <state>/request-intake/<session>.transcript
# holds the transcript path the hooks last saw, so the Bash subcommands can
# find it. The first activation records the current transcript length, so
# chat from before installation is never reinterpreted as new instructions.
#
# Captain input is a transcript `user` entry that is not marked isMeta or
# isCompactSummary, whose origin, when recorded, is human, whose content is
# text (not a tool result), that the operational-input owner
# (bin/fm-operational-input.sh) does not classify as Firstmate's own input,
# and that is either a submitted prompt (it carries promptSource) or a slash
# command echo no local command output answers. Commands Claude Code runs
# itself (/compact, /model) and shell-mode echoes never reach the model.
# A reply is a turn-ending `assistant` entry (stop_reason end_turn) carrying
# nonempty text; narration before a tool call is not a reply. A later captain
# entry, or Claude's interruption marker, invalidates a staged reply or
# acknowledgement; an assistant error entry or Firstmate's own input does the
# same. A request is answered once any reply follows it, and a `reply`
# disposition for an answered request completes at once instead of staging.
#
# Subcommands (hooks read their payload on stdin and never fail the turn):
#   hook stop           Stop: commit staged outcome acknowledgements followed by
#                       a reply, then, at most once per source message, block
#                       the stop with the unresolved-input reconciliation.
#   hook context        SessionStart and UserPromptSubmit: restore unresolved
#                       input as additional context (compaction, resume, and
#                       every new prompt), with a bounded preview.
#   list                print unresolved input ids and full text.
#   dispose <id> recorded <task-id>... --summary <text>
#   dispose <id> reply --summary <text>
#                       record a disposition; `recorded` verifies each task id
#                       through bin/fm-tasks-axi.sh show, and `reply` stays
#                       staged until a reply follows unless one already has.
#   outcome-ack --through <seq>
#                       stage acknowledgement of supervision outcomes up to
#                       <seq>; the next normal reply commits it through
#                       bin/fm-branch-outcome.sh mark-processed.
# Every subcommand is inert outside a genuine primary home whose session lock
# this Claude session owns (bin/fm-session-lock-lib.sh), so dispatched workers
# and competing sessions never record or block anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PREVIEW_LIMIT=8
TEXT_LIMIT=2000

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-request-continuity: %s\n' "$1" >&2; exit "${2:-1}"; }

owns_home() {
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 1
  fm_session_lock_owned_by_self "$STATE"
}

valid_session() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

log_path() { printf '%s/request-intake/%s.jsonl' "$STATE" "$1"; }
transcript_note() { printf '%s/request-intake/%s.transcript' "$STATE" "$1"; }

append_receipt() {  # <session> <json>
  local log
  log=$(log_path "$1")
  mkdir -p "${log%/*}" || return 1
  printf '%s\n' "$2" >> "$log"
}

transcript_lines() {  # <transcript>
  [ -f "$1" ] || { printf '0'; return 0; }
  wc -l < "$1" | tr -d ' '
}

# Ensure the activation boundary exists. A new session's first hook runs before
# any captain entry is written, so its boundary is 0.
activate() {  # <session> <transcript>
  local log
  log=$(log_path "$1")
  if [ -f "$log" ] && grep -q '"type":"start"' "$log"; then
    return 0
  fi
  append_receipt "$1" "{\"type\":\"start\",\"after\":$(transcript_lines "$2")}"
}

# Emit one JSON line per transcript entry the reconciliation needs, after
# line <after>: {"line":N,"kind":"user","id":..,"text":..} for candidate
# captain input, {"line":N,"kind":"command","id":..,"text":..} for a slash
# command echo, {"line":N,"kind":"local","parent":..} for local command output,
# {"line":N,"kind":"reply"} for a turn-ending assistant entry with nonempty
# text, and {"line":N,"kind":"break"} for an assistant error entry or Claude's
# interruption marker, a harness-written user entry the captain never types.
# A byte-level prefilter drops tool results and text-free assistant entries
# before parsing: inside a JSON string a quote is escaped, so these structural
# key/value spellings only match the entry's own fields. One awk and one jq
# process, so a long primary transcript stays cheap on every prompt.
numbered_events() {  # <transcript> <after>
  [ -f "$1" ] || return 0
  awk -v after="$2" '
    NR > after {
      if (index($0, "\"type\":\"user\"")) keep = !index($0, "\"type\":\"tool_result\"")
      else keep = index($0, "\"type\":\"assistant\"") && ((index($0, "\"type\":\"text\"") && index($0, "\"stop_reason\":\"end_turn\"")) || index($0, "\"isApiErrorMessage\":true"))
      if (keep) print NR "\t" $0
    }' "$1" | jq -cR '
    def texts: if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else "" end;
    (index("\t")) as $i | (.[:$i] | tonumber) as $line
    | (.[$i + 1:] | try fromjson catch null) | select(type == "object")
    | .message as $m
    | if .type == "user" and ($m.content | texts | startswith("[Request interrupted by user")) then {line: $line, kind: "break"}
      elif .type == "user" and (.isMeta != true) and (.isCompactSummary != true)
         and (((.origin // {kind: "human"}) | .kind) == "human") then
        ($m.content) as $c
        | if has("promptSource") | not then
            if ($c | type) != "string" then empty
            elif ($c | test("^\\s*<command-(name|message)>")) then
              {line: $line, kind: "command", id: .uuid,
               text: ((($c | capture("<command-name>(?<n>[^<]*)</command-name>").n) // "")
                      + " " + (($c | capture("<command-args>(?<a>[\\s\\S]*)</command-args>").a) // "")
                      | sub("\\s+$"; ""))}
            elif ($c | test("^\\s*<local-command-(stdout|stderr)>")) then {line: $line, kind: "local", parent: .parentUuid}
            else empty end
          elif ($c | type) == "string" then {line: $line, kind: "user", id: .uuid, text: $c}
          elif ($c | type) == "array" and ([$c[] | select(.type == "tool_result")] | length) == 0 then
            {line: $line, kind: "user", id: .uuid,
             text: ([$c[] | if .type == "text" then .text elif .type == "image" then "[attached image]" else empty end] | join("\n"))}
          else empty end
      elif .type == "assistant" and (.isApiErrorMessage == true) then {line: $line, kind: "break"}
      elif .type == "assistant" and ($m.stop_reason == "end_turn") and (($m.content | type) == "array") then
        ([$m.content[] | select(.type == "text") | .text] | join("\n")) as $t
        | if ($t | test("\\S")) then {line: $line, kind: "reply"} else empty end
      else empty end
  ' 2>/dev/null
}

# True when <text> is Firstmate's own operational input rather than the
# captain's: a current envelope, a well-formed doorbell naming <inbox>, this
# home's physical operational inbox, or a steering-inbox doorbell naming
# <steering>, the short name of this session's own $FM_TASK_INBOX (a second
# mate's parent steers it that way). Intake re-reads the whole session on every
# hook, so a doorbell stays Firstmate's after its record is pruned or handled.
is_operational() {  # <text> <inbox> <steering>
  local kind record name
  fm_operational_input_kind "$1" kind && return 0
  if fm_steering_doorbell_inbox "$1" name; then
    [ -n "$3" ] && [ "$name" = "$3" ]
    return
  fi
  fm_operational_doorbell_path "$1" record || return 1
  [ -n "$2" ] && [ "${record%/*}" = "$2" ]
}

# Compute the unresolved state into two globals: PENDING holds one JSON line per
# unresolved request, {"id":..,"text":..,"replyStaged":bool,"attempted":bool},
# and COMMIT_THROUGH the highest staged outcome acknowledgement that a later
# reply has delivered and that is not committed yet (0 for none). Call it
# directly, never in a command substitution, so both survive.
PENDING=""
COMMIT_THROUGH=0
pending_requests() {  # <session> <transcript>
  local session=$1 transcript=$2 log events receipts after
  PENDING=""
  COMMIT_THROUGH=0
  log=$(log_path "$session")
  [ -f "$log" ] || return 0
  receipts=$(cat "$log")
  after=$(printf '%s\n' "$receipts" | jq -r 'select(.type == "start") | .after' 2>/dev/null | head -n 1)
  case "$after" in ''|*[!0-9]*) return 0 ;; esac
  events=$(numbered_events "$transcript" "$after")
  # Classify candidate captain entries with the operational-input owner, then
  # hand the stream and the retagged lines to one jq program. A single jq pass
  # extracts every candidate's line and text, so no process runs per entry.
  # Firstmate's own input is not captain input, and like an interruption it
  # invalidates a staged reply or acknowledgement.
  local user_lines=() user_texts=() retag="" i=0 inbox steering=${FM_TASK_INBOX:-}
  inbox=$(cd -P "$STATE/$FM_OPERATIONAL_RECORD_DIRNAME" 2>/dev/null && pwd -P) || inbox=""
  steering=${steering%/}
  steering=${steering##*/}
  eval "$(printf '%s\n' "$events" | jq -r 'select(.kind == "user") | "user_lines+=(\(.line)); user_texts+=(\(.text | @sh))"' 2>/dev/null)"
  while [ "$i" -lt "${#user_lines[@]}" ]; do
    if is_operational "${user_texts[$i]}" "$inbox" "$steering"; then
      retag="$retag,\"${user_lines[$i]}\":\"break\""
    fi
    i=$((i + 1))
  done
  local result
  result=$(jq -n -c --arg events "$events" --argjson retag "{${retag#,}}" --arg receipts "$receipts" --argjson limit "$TEXT_LIMIT" '
    def lines($s): $s | split("\n") | map(select(length > 0) | (try fromjson catch empty));
    lines($receipts) as $r
    | ([$r[] | select(.type == "start")][0].after // null) as $after
    | if $after == null then {requests: [], commit: 0} else
      (lines($events) | map(select(.line > $after)
                            | if .kind == "user" and $retag[.line | tostring] then {line, kind: $retag[.line | tostring]} else . end)) as $raw
      # A command Claude Code answered locally (/compact, /model, ...) never
      # reached the model; any other command echo is a captain request.
      | ([$raw[] | select(.kind == "local") | .parent] | unique) as $local
      | ($raw | map(if .kind == "command" then (.id as $id | if any($local[]; . == $id) then empty else .kind = "user" end)
                    elif .kind == "local" then empty else . end)) as $ev
      | ([$r[] | select(.type == "disposition") | . + {kind: "disposition", line: .at}]
         + [$r[] | select(.type == "outcome-stage") | . + {kind: "stage", line: .at}]) as $marks
      | ([$r[] | select(.type == "recovery") | .ids[]?] | unique) as $attempted
      | ([$r[] | select(.type == "outcome-commit") | .through] | max // 0) as $committed
      # Receipts written during a turn sort after the entries already present
      # when they were written and before any later entry.
      | ($ev | map(. + {order: (.line * 2)})) + ($marks | map(. + {order: (.line * 2 + 1)}))
      | sort_by(.order)
      # A request is answered once any reply follows it; a reply disposition
      # for it then needs no further reply.
      | reduce .[] as $x ({requests: {}, order: [], replies: [], unanswered: [], answered: [], stage: null, delivered: 0};
          if $x.kind == "user" then
            .replies = [] | .stage = null | .unanswered += [$x.id]
            | .requests[$x.id] = {id: $x.id, text: ($x.text[0:$limit])} | .order += [$x.id]
          elif $x.kind == "break" then .replies = [] | .stage = null
          elif $x.kind == "disposition" then
            if (.requests[$x.id] == null) or (($x.summary // "") | test("\\S") | not) then .
            elif $x.disposition == "recorded" and (($x.tasks // []) | length) > 0 then del(.requests[$x.id])
            elif $x.disposition == "reply" and (.answered | index($x.id)) != null then del(.requests[$x.id])
            elif $x.disposition == "reply" then .replies += [$x.id]
            else . end
          elif $x.kind == "stage" then .stage = $x.through
          elif $x.kind == "reply" then
            reduce .replies[] as $id (.; del(.requests[$id]))
            | .replies = [] | .answered += .unanswered | .unanswered = []
            | if .stage != null then .delivered = ([.delivered, .stage] | max) | .stage = null else . end
          else . end)
      | . as $s
      | {requests: [$s.order[] as $id | $s.requests[$id] | select(. != null)
                    | . + {replyStaged: ($s.replies | index($id) != null), answered: ($s.answered | index($id) != null),
                           attempted: ($attempted | index($id) != null)}]
                   | unique_by(.id),
         commit: (if $s.delivered > $committed then $s.delivered else 0 end)}
      end
  ' 2>/dev/null) || return 1
  COMMIT_THROUGH=$(printf '%s' "$result" | jq -r '.commit')
  PENDING=$(printf '%s' "$result" | jq -c '.requests[]')
}

describe() {  # <requests-jsonl> [stop]
  local requests=$1 event=${2:-} count close
  count=$(printf '%s\n' "$requests" | grep -c . || true)
  printf 'Unreconciled native captain input (not a task list or permission to execute):\n'
  printf '%s\n' "$requests" | head -n "$PREVIEW_LIMIT" | jq -r '
    "[\(.id)] " + (if .replyStaged then "REPLY ALREADY STAGED: answer now; do not record another disposition. "
                    elif .answered then "ALREADY ANSWERED: a reply reached the captain after this message. " else "" end) + .text + "\n"'
  if [ "$count" -gt "$PREVIEW_LIMIT" ]; then
    printf '%s further messages remain; list them with bin/fm-request-continuity.sh list.\n' "$((count - PREVIEW_LIMIT))"
  fi
  cat <<'TEXT'
Reconcile every intent in these messages against later corrections, cancellations, priorities and existing records.
Use existing task IDs and owners; never replay a request merely because it is listed.
Record outliving work and its next action in the backlog, then run bin/fm-request-continuity.sh dispose <id> recorded <task-id>... --summary "<handling>".
TEXT
  if printf '%s\n' "$requests" | jq -e 'select(.answered | not)' >/dev/null 2>&1; then
    printf '%s\n' 'Questions and work fully handled in this reply need no task: run bin/fm-request-continuity.sh dispose <id> reply --summary "<handling>" once, then give the substantive answer.'
  fi
  if printf '%s\n' "$requests" | jq -e 'select(.answered)' >/dev/null 2>&1; then
    close='; the earlier reply stands and needs no repeat.'
    [ "$event" = stop ] && close=', then end the turn with no further text, because the captain already has that reply.'
    printf '%s\n' "An ALREADY ANSWERED message whose reply fully handled it needs no task and no new answer: run bin/fm-request-continuity.sh dispose <id> reply --summary \"<handling>\" once$close"
    printf '%s\n' 'If that reply did not actually address an ALREADY ANSWERED message, answer it now and then dispose it.'
  fi
  printf '%s\n' 'A disposition does not establish task execution, completion or semantic correctness.'
}

payload_field() {  # <payload> <field>
  printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // empty | strings' 2>/dev/null
}

# Bind the payload's session and transcript for the Bash subcommands. Returns 1
# when the payload does not name a usable session.
bind_payload() {  # <payload>
  SESSION=$(payload_field "$1" session_id)
  TRANSCRIPT=$(payload_field "$1" transcript_path)
  valid_session "$SESSION" || return 1
  [ -n "$TRANSCRIPT" ] || return 1
  mkdir -p "$STATE/request-intake" || return 1
  printf '%s\n' "$TRANSCRIPT" > "$(transcript_note "$SESSION")"
}

commit_outcomes() {  # <session>
  [ "$COMMIT_THROUGH" -gt 0 ] 2>/dev/null || return 0
  if "$SCRIPT_DIR/fm-branch-outcome.sh" mark-processed --through "$COMMIT_THROUGH" >/dev/null 2>&1; then
    append_receipt "$1" "{\"type\":\"outcome-commit\",\"through\":$COMMIT_THROUGH}"
  fi
}

hook() {
  local event=${1:-} payload requests fresh ids reason
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  fm_hook_payload_is_foreign_host "$payload" && exit 0
  owns_home || exit 0
  bind_payload "$payload" || exit 0
  activate "$SESSION" "$TRANSCRIPT" || exit 0
  pending_requests "$SESSION" "$TRANSCRIPT" || exit 0
  requests=$PENDING
  commit_outcomes "$SESSION"
  case "$event" in
    stop)
      fresh=$(printf '%s\n' "$requests" | jq -c 'select(.attempted | not)' 2>/dev/null)
      [ -n "$fresh" ] || exit 0
      ids=$(printf '%s\n' "$fresh" | jq -sc 'map(.id)')
      # Persist the attempt before asking, so a lost or ignored follow-up can
      # never become an endless loop; the input stays visible to later turns.
      append_receipt "$SESSION" "{\"type\":\"recovery\",\"ids\":$ids}" || exit 0
      reason=$(describe "$requests" stop)
      jq -n -c --arg reason "$reason" '{decision: "block", reason: $reason}'
      ;;
    context)
      [ -n "$requests" ] || exit 0
      local name
      name=$(payload_field "$payload" hook_event_name)
      [ -n "$name" ] || name=SessionStart
      jq -n -c --arg ctx "$(describe "$requests")" --arg name "$name" \
        '{hookSpecificOutput: {hookEventName: $name, additionalContext: $ctx}}'
      ;;
  esac
  exit 0
}

# Resolve this Claude session for a Bash subcommand.
cli_session() {
  owns_home || die "this session does not own the firstmate home at $FM_HOME"
  SESSION=$(fm_session_lock_trusted_session_id) || die "no trusted Claude session id"
  valid_session "$SESSION" || die "invalid Claude session id"
  [ -f "$(transcript_note "$SESSION")" ] || die "no transcript bound for this session yet; a hook binds it on the next prompt"
  TRANSCRIPT=$(head -n 1 "$(transcript_note "$SESSION")")
  activate "$SESSION" "$TRANSCRIPT" || die "cannot record the activation boundary"
}

cmd_list() {
  local requests
  cli_session
  pending_requests "$SESSION" "$TRANSCRIPT" || die "cannot read native input"
  requests=$PENDING
  if [ -z "$requests" ]; then
    printf 'no unresolved native captain input\n'
    return 0
  fi
  printf '%s\n' "$requests" | jq -r '"[\(.id)]\(if .replyStaged then " (reply staged)" else "" end)\n\(.text)\n"'
}

cmd_dispose() {
  local id=${1:-} disposition=${2:-} summary="" tasks=() task requests
  [ -n "$id" ] && [ -n "$disposition" ] || die "usage: dispose <id> recorded <task-id>... --summary <text> | dispose <id> reply --summary <text>" 2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary) [ "$#" -ge 2 ] || die "--summary needs text" 2; summary=$2; shift 2 ;;
      --*) die "unknown option $1" 2 ;;
      *) tasks+=("$1"); shift ;;
    esac
  done
  printf '%s' "$summary" | grep -q '[^[:space:]]' || die "a handling summary is required" 2
  case "$disposition" in
    recorded) [ "${#tasks[@]}" -gt 0 ] || die "recorded needs at least one existing task id" 2 ;;
    reply) [ "${#tasks[@]}" -eq 0 ] || die "reply takes no task id" 2 ;;
    *) die "disposition must be recorded or reply" 2 ;;
  esac
  cli_session
  pending_requests "$SESSION" "$TRANSCRIPT" || die "cannot read native input"
  requests=$PENDING
  printf '%s\n' "$requests" | jq -e --arg id "$id" 'select(.id == $id)' >/dev/null 2>&1 \
    || die "$id is not unresolved native captain input in this session"
  if [ "$disposition" = reply ] && printf '%s\n' "$requests" | jq -e --arg id "$id" 'select(.id == $id and .replyStaged)' >/dev/null 2>&1; then
    printf 'reply already staged for %s; give the substantive answer now\n' "$id"
    return 0
  fi
  for task in ${tasks[@]+"${tasks[@]}"}; do
    "$SCRIPT_DIR/fm-tasks-axi.sh" show "$task" >/dev/null 2>&1 \
      || die "task $task cannot be read through the backlog owner; record the work first"
  done
  append_receipt "$SESSION" "$(jq -n -c --arg id "$id" --arg d "$disposition" --arg s "$summary" \
    --argjson at "$(transcript_lines "$TRANSCRIPT")" --args '{type: "disposition", id: $id, disposition: $d, tasks: $ARGS.positional, summary: $s, at: $at}' \
    ${tasks[@]+"${tasks[@]}"})" || die "cannot persist the disposition"
  if [ "$disposition" = reply ] && printf '%s\n' "$requests" | jq -e --arg id "$id" 'select(.id == $id and .answered)' >/dev/null 2>&1; then
    printf 'reply recorded for %s; the reply already given after it stands and needs no repeat\n' "$id"
  elif [ "$disposition" = reply ]; then
    printf 'reply staged for %s; it counts only once a normal nonempty reply follows\n' "$id"
  else
    printf 'recorded %s against %s\n' "$id" "${tasks[*]}"
  fi
}

cmd_outcome_ack() {
  local through=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --through) [ "$#" -ge 2 ] || die "--through needs a sequence" 2; through=$2; shift 2 ;;
      *) die "unknown argument $1" 2 ;;
    esac
  done
  case "$through" in ''|*[!0-9]*|0) die "--through must be a positive outcome sequence" 2 ;; esac
  cli_session
  "$SCRIPT_DIR/fm-branch-outcome.sh" unprocessed 2>/dev/null \
    | jq -e --argjson n "$through" 'select(.seq == $n)' >/dev/null 2>&1 \
    || die "seq $through is not an unprocessed captain outcome"
  append_receipt "$SESSION" "{\"type\":\"outcome-stage\",\"through\":$through,\"at\":$(transcript_lines "$TRANSCRIPT")}" \
    || die "cannot persist the staged acknowledgement"
  printf 'acknowledgement staged through seq %s; give the substantive reply. Outcomes stay open until that reply is recorded.\n' "$through"
}

case "${1:-}" in
  hook) shift; hook "$@" ;;
  list) shift; cmd_list "$@" ;;
  dispose) shift; cmd_dispose "$@" ;;
  outcome-ack) shift; cmd_outcome_ack "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

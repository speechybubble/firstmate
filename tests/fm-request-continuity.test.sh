#!/usr/bin/env bash
# tests/fm-request-continuity.test.sh - the Claude primary's native request and
# outcome continuity owner, bin/fm-request-continuity.sh.
#
# Drives the real script, its real hooks, the real outcome store and the real
# operational-input owner in a plain-checkout fixture home. A process named
# like the harness writes its own pid into state/.lock, so the real
# session-lock ownership predicate decides scope. Transcripts are synthetic
# JSONL in the shape Claude Code writes. Cases:
#   1. A session that does not own the home records and blocks nothing.
#   2. Chat from before activation is never reinterpreted as new input.
#   3. An omitted request blocks the stop exactly once, stays visible to later
#      context, and Firstmate's own doorbell input is not captain input.
#   4. `recorded` requires a readable existing task; `reply` stays provisional
#      until a normal nonempty reply, narration before a tool call is not that
#      reply, and interruption or a later captain message invalidates it.
#   5. Compaction keeps unresolved input restorable from the full transcript;
#      a slash skill invocation is captain input, while a command Claude Code
#      answers locally, its output, and a shell-mode echo are not.
#   6. A staged outcome acknowledgement commits only after a turn-ending reply,
#      not narration before a tool call; an intervening captain message
#      invalidates it, and replay is idempotent.
# shellcheck disable=SC2016 # the fake harness's child shell expands FM_HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-request-continuity)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
command -v jq >/dev/null 2>&1 || { printf 'not ok - jq is required\n'; exit 1; }

# A plain checkout whose bin/ links the real scripts, except a backlog stub
# that knows exactly one task, so `recorded` exercises its existence check
# without a real tasks-axi home.
make_home() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/state"
  git -C "$dir" init -q
  : > "$dir/AGENTS.md"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$dir/bin/${f##*/}"; done
  rm "$dir/bin/fm-tasks-axi.sh"
  cat > "$dir/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = show ] && [ "${2:-}" = t-known ]
SH
  chmod +x "$dir/bin/fm-tasks-axi.sh"
  ln -s /bin/bash "$dir/fake-claude"
}

# Run a subcommand as the session that owns the home: the harness-named
# process records itself as the lock owner and as the trusted session.
as_owner() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="" "$home/fake-claude" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "sess-1\n" > "$FM_HOME/state/.lock-session"
    export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=sess-1
    "$FM_HOME/bin/fm-request-continuity.sh" "$@"
  ' fake-claude "$@"
}

hook_payload() {  # <home> <event-name>
  jq -n -c --arg t "$1/transcript.jsonl" --arg e "$2" \
    '{session_id: "sess-1", transcript_path: $t, hook_event_name: $e, stop_hook_active: false}'
}

stop_hook() {  # <home>
  hook_payload "$1" Stop | as_owner "$1" hook stop
}

context_hook() {  # <home> [event-name]
  hook_payload "$1" "${2:-SessionStart}" | as_owner "$1" hook context
}

say() {  # <home> <uuid> <text>
  jq -n -c --arg id "$2" --arg text "$3" \
    '{type: "user", uuid: $id, origin: {kind: "human"}, promptSource: "typed", message: {role: "user", content: $text}}' \
    >> "$1/transcript.jsonl"
}

# Claude Code writes one entry per content block, each carrying the message's
# stop_reason: end_turn for the turn's final text, tool_use for narration and
# calls before a tool result.
reply() {  # <home> <text> [stop-reason]
  jq -n -c --arg text "$2" --arg stop "${3:-end_turn}" \
    '{type: "assistant", message: {role: "assistant", stop_reason: $stop, content: [{type: "text", text: $text}]}}' \
    >> "$1/transcript.jsonl"
}

narrate() {  # <home> <text>
  reply "$1" "$2" tool_use
}

tool_turn() {  # <home>
  printf '%s\n' \
    '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{}}]}}' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]}}' \
    >> "$1/transcript.jsonl"
}

unprocessed_seqs() {  # <home>
  FM_HOME="$1" "$1/bin/fm-branch-outcome.sh" unprocessed | jq -r '.seq' | tr '\n' ' '
}

test_non_owner_is_inert() {
  local home="$TMP_ROOT/inert" out
  make_home "$home"
  say "$home" u-1 "Please rotate the deploy key."
  # A live harness-named process that is not this session holds the lock.
  sleep 300 & local holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  out=$(hook_payload "$home" Stop | FM_HOME="$home" "$home/fake-claude" -c '"$FM_HOME/bin/fm-request-continuity.sh" hook stop')
  kill "$holder" 2>/dev/null
  [ -z "$out" ] || fail "a non-owning session blocked the stop: $out"
  [ ! -e "$home/state/request-intake" ] || fail "a non-owning session wrote receipts"
  pass "a session that does not own the home records and blocks nothing"
}

test_activation_is_not_retroactive() {
  local home="$TMP_ROOT/boundary" out
  make_home "$home"
  say "$home" u-old "An old request from before installation."
  reply "$home" "Old answer."
  out=$(stop_hook "$home")
  [ -z "$out" ] || fail "history before activation was treated as new input: $out"
  say "$home" u-new "Add the release note."
  out=$(stop_hook "$home")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null || fail "new input after activation was not reconciled: $out"
  case "$out" in *u-old*) fail "pre-activation input was replayed: $out" ;; esac
  pass "activation records a boundary, so earlier chat is never reinterpreted as new instructions"
}

test_omission_recovers_once_and_stays_visible() {
  local home="$TMP_ROOT/omission" out doorbell
  make_home "$home"
  : > "$home/transcript.jsonl"
  stop_hook "$home" >/dev/null
  say "$home" u-a "Fix the flaky upload test and tell me when it is merged."
  # Firstmate's own input reaches Claude as a doorbell naming a home record.
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-operational-input.sh"
  fm_operational_record_write "$home/state" away-supervisor "routine digest" doorbell || fail "could not write an operational record"
  say "$home" u-op "$doorbell"
  say "$home" u-b "Unrelated: what is the weather like?"
  reply "$home" "It is sunny."
  out=$(stop_hook "$home")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null || fail "the omitted request did not block the stop: $out"
  case "$out" in *u-a*u-b*) ;; *) fail "the reconciliation did not list both unresolved inputs: $out" ;; esac
  case "$out" in *u-op*) fail "Firstmate's own doorbell input was treated as captain input: $out" ;; esac
  [ "$(grep -c '"type":"recovery"' "$home/state/request-intake/sess-1.jsonl")" = 1 ] || fail "the recovery attempt was not persisted exactly once"
  out=$(stop_hook "$home")
  [ -z "$out" ] || fail "the same input blocked a second stop: $out"
  out=$(context_hook "$home" UserPromptSubmit)
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null || fail "context restoration did not name its event: $out"
  case "$out" in *u-a*) ;; *) fail "unresolved input vanished from later context: $out" ;; esac
  pass "an omitted request blocks the stop once, stays visible afterwards, and Firstmate's doorbells are not captain input"
}

test_dispositions_are_verified_and_reply_is_provisional() {
  local home="$TMP_ROOT/dispose" out
  make_home "$home"
  : > "$home/transcript.jsonl"
  stop_hook "$home" >/dev/null
  say "$home" u-a "Ship the onboarding fix."
  say "$home" u-b "How many workers are running?"
  say "$home" u-c "Also draft the changelog."
  out=$(as_owner "$home" dispose u-a recorded t-missing --summary "filed" 2>&1) && fail "a nonexistent task was accepted: $out"
  out=$(as_owner "$home" dispose u-a recorded --summary "filed" 2>&1) && fail "recorded without a task was accepted: $out"
  out=$(as_owner "$home" dispose u-a recorded t-known --summary "" 2>&1) && fail "an empty summary was accepted: $out"
  as_owner "$home" dispose u-a recorded t-known --summary "Filed as t-known with its next action" >/dev/null || fail "an existing task link was refused"
  tool_turn "$home"
  as_owner "$home" dispose u-b reply --summary "answer the count" >/dev/null || fail "a reply disposition was refused"
  out=$(as_owner "$home" dispose u-b reply --summary "again")
  case "$out" in *"already staged"*) ;; *) fail "a repeated reply stage was not idempotent: $out" ;; esac
  out=$(as_owner "$home" list)
  case "$out" in *u-a*) fail "a recorded request stayed unresolved: $out" ;; esac
  case "$out" in *"[u-b] (reply staged)"*) ;; *) fail "the staged reply was not shown as provisional: $out" ;; esac
  as_owner "$home" dispose u-c reply --summary "will draft now" >/dev/null || fail "second reply stage refused"
  # Narration before a tool call is not the reply, and interruption then
  # invalidates the stage, so the later answer cannot clear u-c.
  narrate "$home" "Counting the workers now."
  tool_turn "$home"
  out=$(as_owner "$home" list)
  case "$out" in *"[u-c] (reply staged)"*) ;; *) fail "narration before a tool call delivered a staged reply: $out" ;; esac
  say "$home" u-int "[Request interrupted by user]"
  reply "$home" "Three workers are running."
  out=$(as_owner "$home" list)
  case "$out" in *u-c*) ;; *) fail "an interrupted reply stage was completed by a later answer: $out" ;; esac
  case "$out" in *"(reply staged)"*) fail "interruption did not invalidate the staged replies: $out" ;; esac
  case "$out" in *u-b*) ;; *) fail "the interrupted stage for u-b was cleared by a later answer: $out" ;; esac
  case "$out" in *u-int*) fail "the harness interruption marker was treated as captain input: $out" ;; esac
  tool_turn "$home"
  as_owner "$home" dispose u-b reply --summary "answer the count" >/dev/null || fail "re-staging after interruption was refused"
  reply "$home" "Three workers are running."
  out=$(as_owner "$home" list)
  case "$out" in *u-b*) fail "a staged reply followed by a normal reply stayed unresolved: $out" ;; esac
  case "$out" in *u-c*) ;; *) fail "an unstaged request was cleared by an unrelated reply: $out" ;; esac
  out=$(as_owner "$home" dispose u-zz reply --summary "x" 2>&1) && fail "a disposition for unknown input was accepted: $out"
  pass "recorded links need a readable task; a reply stays provisional until a turn-ending reply, and interruption invalidates it"
}

test_compaction_keeps_input_restorable() {
  local home="$TMP_ROOT/compaction" out
  make_home "$home"
  : > "$home/transcript.jsonl"
  stop_hook "$home" >/dev/null
  say "$home" u-a "Keep the staging deploy paused until I say otherwise."
  reply "$home" "Noted."
  printf '%s\n' \
    '{"type":"system","subtype":"compact_boundary"}' \
    '{"type":"user","uuid":"u-sum","isCompactSummary":true,"message":{"role":"user","content":"Summary: the captain chatted."}}' \
    '{"type":"user","uuid":"u-cmd","message":{"role":"user","content":"<command-name>/compact</command-name>"}}' \
    '{"type":"user","uuid":"u-out","parentUuid":"u-cmd","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}}' \
    '{"type":"user","uuid":"u-sh","message":{"role":"user","content":"<bash-input>ls</bash-input>"}}' \
    '{"type":"user","uuid":"u-skill","message":{"role":"user","content":"<command-message>stow</command-message>\n<command-name>/stow</command-name>\n<command-args>file the open release work</command-args>"}}' \
    >> "$home/transcript.jsonl"
  out=$(context_hook "$home" SessionStart)
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null || fail "compaction restore did not name SessionStart: $out"
  case "$out" in *u-a*"staging deploy"*) ;; *) fail "an input omitted by the compaction summary was not restored: $out" ;; esac
  case "$out" in *u-sum*) fail "the compaction summary was treated as captain input: $out" ;; esac
  case "$out" in *u-cmd*|*u-out*|*u-sh*) fail "a locally answered command, its output, or a shell-mode echo was treated as captain input: $out" ;; esac
  assert_contains "$out" "/stow file the open release work" "a slash skill invocation the model receives must stay captain input"
  pass "compaction keeps unresolved input restorable from the full transcript, independent of the summary, and only commands the model receives count as input"
}

test_outcome_ack_commits_only_after_reply() {
  local home="$TMP_ROOT/outcome" seq out
  make_home "$home"
  : > "$home/transcript.jsonl"
  stop_hook "$home" >/dev/null
  seq=$(FM_HOME="$home" "$home/bin/fm-branch-outcome.sh" append --task task-9 --verdict captain --summary "PR https://example.com/pr/9 ready for review")
  FM_HOME="$home" "$home/bin/fm-branch-outcome.sh" mark-read --through "$seq" >/dev/null
  FM_HOME="$home" "$home/bin/fm-branch-outcome.sh" processed-init >/dev/null 2>&1 || true
  [ "$(unprocessed_seqs "$home")" = "$seq " ] || fail "fixture outcome is not unprocessed: $(unprocessed_seqs "$home")"
  out=$(as_owner "$home" outcome-ack --through 999 2>&1) && fail "an unlisted sequence was staged: $out"
  as_owner "$home" outcome-ack --through "$seq" >/dev/null || fail "staging a listed outcome was refused"
  stop_hook "$home" >/dev/null
  [ "$(unprocessed_seqs "$home")" = "$seq " ] || fail "a staged acknowledgement with no reply retired the outcome"
  # A captain message before any reply invalidates the stage.
  say "$home" u-x "Different topic: rename the repo."
  reply "$home" "Renaming now."
  stop_hook "$home" >/dev/null
  [ "$(unprocessed_seqs "$home")" = "$seq " ] || fail "a topic switch reused the staged acknowledgement"
  tool_turn "$home"
  as_owner "$home" outcome-ack --through "$seq" >/dev/null || fail "re-staging was refused"
  narrate "$home" "Checking the PR status first."
  tool_turn "$home"
  stop_hook "$home" >/dev/null
  [ "$(unprocessed_seqs "$home")" = "$seq " ] || fail "narration before a tool call committed the staged acknowledgement"
  reply "$home" "The PR https://example.com/pr/9 is green and ready; shall I merge it?"
  stop_hook "$home" >/dev/null
  [ -z "$(unprocessed_seqs "$home")" ] || fail "a reply after the staged acknowledgement did not commit it"
  stop_hook "$home" >/dev/null || fail "replaying the stop after commit failed"
  [ "$(grep -c '"type":"outcome-commit"' "$home/state/request-intake/sess-1.jsonl")" = 1 ] || fail "the commit was not recorded exactly once"
  pass "a staged outcome acknowledgement commits only after a turn-ending reply, a topic switch invalidates it, and replay is idempotent"
}

test_non_owner_is_inert
test_activation_is_not_retroactive
test_omission_recovers_once_and_stays_visible
test_dispositions_are_verified_and_reply_is_provisional
test_compaction_keeps_input_restorable
test_outcome_ack_commits_only_after_reply
printf 'all fm-request-continuity tests passed\n'

#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for native request and outcome
# continuity (bin/fm-request-continuity.sh and its tracked hook registration).
# The portable regression (tests/fm-request-continuity.test.sh) pins the
# reconciliation logic against synthetic transcripts; this guard proves the
# harness facts it depends on against the real installed Claude Code:
#   1. Claude's transcript shape: a typed prompt is captain input, and a reply
#      that omits filing leaves it unresolved.
#   2. The tracked Stop hook's block reaches the model, which then records a
#      disposition through the real command, and the stop is blocked only once.
#   3. The final reply is in the transcript by the time the Stop hook reads it,
#      so a staged outcome acknowledgement commits at that same stop.
#   4. After a real compaction, the SessionStart hook restores input the
#      compaction summary may omit.
# The project, FM_HOME and transcripts are isolated under a private lab; Claude
# keeps its existing managed authentication. No live fleet home, worktree, or
# session is touched. Each session-start acquires the lab's lock through the
# real bin/fm-lock.sh from a lab-local hook; the rest of the tracked session
# machinery (session start digest, watcher arm, supervision host) is left out
# so it spends no tokens here. Run after a Claude upgrade and before trusting
# refreshed evidence in docs/verification/runtime-backends.md.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_REQUEST_CONTINUITY_CLAUDE_LIVE_E2E claude

unset FM_ROOT FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
  FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_BACKEND \
  HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_VERSION=$(claude --version)
LAB="$ROOT/.request-continuity-claude-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
EVIDENCE=${FM_REQUEST_CONTINUITY_CLAUDE_EVIDENCE:-}

fail() {
  printf 'not ok - Claude %s: %s\n' "$CLAUDE_VERSION" "$1" >&2
  exit 1
}

cleanup() {
  if [ -n "$EVIDENCE" ]; then
    mkdir -p "$EVIDENCE" && cp -R "$LAB/." "$EVIDENCE/" 2>/dev/null
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
mkdir -p "$PROJECT/.claude"
# Keep exactly the tracked continuity hook commands.
jq '{hooks: (.hooks | with_entries(.value |= (map(.hooks |= map(select(.command | contains("fm-request-continuity.sh")))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0)))}' \
  "$ROOT/.claude/settings.json" > "$PROJECT/.claude/settings.json" \
  || fail "could not extract the tracked continuity hooks"
[ "$(jq '[.hooks[][].hooks[]] | length' "$PROJECT/.claude/settings.json")" = 3 ] \
  || fail "expected three tracked continuity hook entries"
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/fm-lock.sh >/dev/null 2>&1 || true" } ] }
    ]
  }
}
JSON
# A backlog with exactly one known task, so `recorded` has something real to
# link without a tasks-axi home.
cat > "$PROJECT/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = show ] && [ "${2:-}" = t-relnote ] && { printf 't-relnote - Draft the Q3 release note\n'; exit 0; }
exit 1
SH
chmod +x "$PROJECT/bin/fm-tasks-axi.sh"
cat > "$PROJECT/CLAUDE.md" <<'MD'
# Lab primary
You are a test primary in an isolated lab, not a real Firstmate.
The backlog already holds task t-relnote, "Draft the Q3 release note".
Follow any Stop hook feedback exactly and keep replies to one short sentence.
MD
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"

run_claude() {  # <out> <prompt> [claude args...]
  local out=$1 prompt=$2
  shift 2
  (
    cd "$PROJECT" || exit 1
    FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
      claude -p "$prompt" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
      --setting-sources project,local --effort low --output-format stream-json --verbose "$@"
  ) > "$out" 2>&1 || fail "Claude session failed: $(tail -20 "$out")"
}

receipts() { cat "$HOME_DIR"/state/request-intake/*.jsonl 2>/dev/null; }

# 1-2. An omitted request is reconciled through the real Stop hook.
run_claude "$LAB/turn1.jsonl" 'Later, the Q3 release note needs drafting. For now answer only this: what is 7 times 6?'
SESSION=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$LAB/turn1.jsonl" | head -n 1)
[ -n "$SESSION" ] || fail "no session id in the first turn's stream"
TRANSCRIPT=$(head -n 1 "$HOME_DIR/state/request-intake/$SESSION.transcript" 2>/dev/null)
[ -f "$TRANSCRIPT" ] || fail "the hooks never bound the session transcript"
FIRST=$(jq -r 'select(.type == "user" and has("promptSource") and (.message.content | type) == "string") | .uuid' "$TRANSCRIPT" | head -n 1)
[ -n "$FIRST" ] || fail "the typed prompt is not a string-content user entry in the transcript"
[ "$(receipts | jq -s --arg id "$FIRST" '[.[] | select(.type == "recovery" and (.ids | index($id)))] | length')" = 1 ] \
  || fail "the Stop hook did not request recovery for the omitted input exactly once: $(receipts)"
receipts | jq -e -s --arg id "$FIRST" 'any(.[]; .type == "disposition" and .id == $id)' >/dev/null \
  || fail "the model did not record a disposition after the Stop hook's block: $(receipts)"
STOP_BLOCKS=$(grep -c 'Unreconciled native captain input' "$LAB/turn1.jsonl" || true)
[ "$STOP_BLOCKS" -ge 1 ] || fail "the Stop hook's reconciliation request never reached the conversation"

# 3. A staged outcome acknowledgement commits at the stop that follows its reply.
SEQ=$(FM_HOME="$HOME_DIR" "$PROJECT/bin/fm-branch-outcome.sh" append --task task-9 --verdict captain --summary "PR https://example.com/pr/9 checks green, ready for review")
FM_HOME="$HOME_DIR" "$PROJECT/bin/fm-branch-outcome.sh" mark-read --through "$SEQ" >/dev/null
FM_HOME="$HOME_DIR" "$PROJECT/bin/fm-branch-outcome.sh" processed-init >/dev/null 2>&1 || true
run_claude "$LAB/turn2.jsonl" "Run exactly \`bin/fm-request-continuity.sh outcome-ack --through $SEQ\` with Bash, then tell me in one sentence that PR 9 is ready for review." --resume "$SESSION"
receipts | jq -e -s --argjson n "$SEQ" 'any(.[]; .type == "outcome-stage" and .through == $n)' >/dev/null \
  || fail "the model did not stage the outcome acknowledgement: $(receipts)"
[ -z "$(FM_HOME="$HOME_DIR" "$PROJECT/bin/fm-branch-outcome.sh" unprocessed)" ] \
  || fail "the reply after the staged acknowledgement was not visible to the Stop hook, so the outcome stayed unprocessed"
receipts | jq -e -s --argjson n "$SEQ" '[.[] | select(.type == "outcome-commit" and .through == $n)] | length == 1' >/dev/null \
  || fail "the outcome commit was not recorded exactly once: $(receipts)"

# 4. Input left unresolved survives a real compaction.
run_claude "$LAB/turn3.jsonl" 'Keep the staging deploy paused until I say otherwise. Reply with only OK and run no tools, even if a hook asks you to.' --resume "$SESSION"
THIRD=$(jq -r 'select(.type == "user" and has("promptSource") and (.message.content | type) == "string") | .uuid' "$TRANSCRIPT" | tail -n 1)
if receipts | jq -e -s --arg id "$THIRD" 'any(.[]; .type == "disposition" and .id == $id)' >/dev/null; then
  fail "the model recorded a disposition despite the no-tools instruction, so the compaction case has nothing to restore"
fi
run_claude "$LAB/turn4.jsonl" '/compact' --resume "$SESSION"
jq -e -s --arg id "$THIRD" '
  any(.[]; .type == "system" and .subtype == "hook_response" and .hook_event == "SessionStart"
           and ((.stdout // "") | contains($id)))' "$LAB/turn4.jsonl" >/dev/null \
  || fail "the SessionStart hook after compaction did not restore the unresolved input"
# Claude records /compact and its local output as user entries; neither is
# captain input, so neither may appear in the next restoration.
run_claude "$LAB/turn5.jsonl" 'Reply with only DONE.' --resume "$SESSION"
for id in $(jq -r 'select(.type == "user" and (has("promptSource") | not) and (.isMeta != true) and (.isCompactSummary != true) and (.message.content | type) == "string") | .uuid' "$TRANSCRIPT"); do
  ! grep -q "$id" "$HOME_DIR"/state/request-intake/*.jsonl "$LAB/turn5.jsonl" \
    || fail "Claude's own command entry $id was treated as captain input"
done

printf 'ok - Claude %s: omitted input was reconciled once through the Stop hook, a staged outcome acknowledgement committed at the stop after its reply, and unresolved input was restored after compaction\n' "$CLAUDE_VERSION"

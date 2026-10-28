#!/usr/bin/env bash
# drive.sh <repo-root> <work-dir> : drive fm-request-continuity.sh on main-session-sized transcripts
set -u
ROOT=$1; W=$2; mkdir -p "$W"; W=$(cd "$W" && pwd)
export TMPDIR="$W/tmpdir"; mkdir -p "$TMPDIR"
fail() { printf 'FAIL - %s\n' "$*"; FAILED=1; }
pass() { printf 'PASS - %s\n' "$*"; }
FAILED=0
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3";; esac; }
eval "$(sed -n '/^make_home() {/,/^test_non_owner_is_inert() {/p' "$ROOT/tests/fm-request-continuity.test.sh" | sed '$d')"

echo "=== Scenario A: main session with ~4 MB of events after the activation boundary"
home="$W/main"; make_home "$home"
for i in $(seq 1 10); do say "$home" "pre-$i" "chat before activation $i"; reply "$home" "ok $i"; done
context_hook "$home" SessionStart >/dev/null   # activation boundary after 20 lines
jq -n -c '("BRANCH OUTCOMES row " * 1) as $h | ("lorem ipsum dolor sit amet " * 155) as $pad | range(900) as $i
  | {type:"user",uuid:"u-main-\($i)",origin:{kind:"human"},promptSource:"typed",message:{role:"user",content:"\($h)\(1905+$i): \($pad)"}},
    {type:"assistant",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"tool_use",id:"tu\($i)",name:"Bash",input:{}}]}},
    {type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"tu\($i)",content:("result " * 400)}]}},
    {type:"assistant",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:"Handled row \(1905+$i)."}]}}' >> "$home/transcript.jsonl"
say "$home" u-open "Final open question: did the deploy finish?"
ev=$(awk 'NR>20' "$home/transcript.jsonl" | grep -v tool_result | grep -c . ); printf 'transcript: %s bytes, %s lines\n' "$(wc -c < "$home/transcript.jsonl")" "$(wc -l < "$home/transcript.jsonl")"
# measure the event stream size exactly as the script builds it
evsize=$(FM_HOME="$home" bash -c 'source <(sed -n "/^numbered_events() {/,/^}/p" "$1/bin/fm-request-continuity.sh"); numbered_events "$1/transcript.jsonl" 20 | wc -c' _ "$home")
printf 'event stream after boundary: %s bytes (single-arg limit 131072)\n' "$evsize"
[ "$evsize" -gt 3500000 ] || fail "event stream too small: $evsize"
start=$(date +%s.%N)
out=$(context_hook "$home" UserPromptSubmit); rc=$?
printf 'context hook rc=%s (%.2fs)\n' "$rc" "$(echo "$(date +%s.%N) - $start" | bc)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null && assert_contains "$out" "u-main-0" "context hook did not restore u-main-0" && pass "context hook restores unresolved input on a 4 MB session" || fail "context hook output: ${out:0:300}"
out=$(stop_hook "$home"); printf 'stop hook output: %s\n' "$out"
printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null && pass "stop hook blocks once with a bounded reason on a 4 MB session" || fail "stop hook did not block: $out"
out=$(as_owner "$home" list 2>&1) || fail "list failed: ${out:0:300}"
printf 'list output: %s lines; head:\n%s\n' "$(printf '%s\n' "$out" | wc -l)" "$(printf '%s\n' "$out" | head -c 600)"
assert_contains "$out" "[u-main-0] ALREADY ANSWERED" "list misses u-main-0"
assert_contains "$out" "[u-main-899] ALREADY ANSWERED" "list misses u-main-899"
assert_contains "$out" "[u-open]" "list misses u-open"
[ "$FAILED" = 0 ] && pass "list prints all 901 inputs on a 4 MB session"
seq=$(FM_HOME="$home" "$home/bin/fm-branch-outcome.sh" append --task task-main --verdict captain --summary "PR https://example.com/pr/1905 ready")
FM_HOME="$home" "$home/bin/fm-branch-outcome.sh" mark-read --through "$seq" >/dev/null
FM_HOME="$home" "$home/bin/fm-branch-outcome.sh" processed-init >/dev/null 2>&1 || true
out=$(as_owner "$home" outcome-ack --through "$seq" 2>&1); rc=$?; printf 'outcome-ack rc=%s: %s\n' "$rc" "$out"
[ "$rc" = 0 ] || fail "outcome-ack failed"
printf 'unprocessed before reply: [%s]\n' "$(unprocessed_seqs "$home")"
reply "$home" "PR 1905 is ready; the deploy finished too."
stop_hook "$home" >/dev/null
printf 'unprocessed after reply+stop: [%s]\n' "$(unprocessed_seqs "$home")"
[ -z "$(unprocessed_seqs "$home")" ] && grep -q '"type":"outcome-commit"' "$home/state/request-intake/sess-1.jsonl" && pass "staged outcome acknowledgement commits after the reply on a 4 MB session" || fail "outcome acknowledgement did not commit"
printf 'receipt log:\n'; cat "$home/state/request-intake/sess-1.jsonl"

echo "=== Scenario B1: Firstmate-input retag object over 128 KB (9000 doorbells)"
home="$W/retag"; make_home "$home"; : > "$home/transcript.jsonl"; stop_hook "$home" >/dev/null
. "$ROOT/bin/fm-operational-input.sh"
fm_operational_record_write "$home/state" away-supervisor "routine digest" doorbell || fail "no record"
jq -n -c --arg d "$doorbell" 'range(9000) as $i | {type:"user",uuid:"u-op-\($i)",origin:{kind:"human"},promptSource:"typed",message:{role:"user",content:$d}}' >> "$home/transcript.jsonl"
say "$home" u-real "Real captain request after the doorbells"
t0=$(date +%s); out=$(as_owner "$home" list 2>&1); rc=$?
printf 'list rc=%s (%ss), retag object would be ~%s bytes; output:\n%s\n' "$rc" "$(( $(date +%s) - t0 ))" "$(seq 2 9001 | awk '{n+=length($0)+11} END{print n}')" "$(printf '%s' "$out" | head -c 600)"
[ "$rc" = 0 ] || fail "list failed with retag over 128 KB"
assert_contains "$out" "[u-real]" "the real input is not listed"
case "$out" in *u-op-*) fail "doorbells were treated as captain input";; esac
[ "$FAILED" = 0 ] && pass "9000 Firstmate doorbells stay non-captain input and the one real request is listed"

echo "=== Scenario B2: receipt log over 128 KB (dispositions with long summaries)"
home="$W/receipts"; make_home "$home"; : > "$home/transcript.jsonl"; stop_hook "$home" >/dev/null
for i in $(seq 1 260); do say "$home" "u-r-$i" "Request $i"; done
reply "$home" "Answered everything."
long=$(printf 'summary %.0s' $(seq 1 70))
t0=$(date +%s)
for i in $(seq 1 259); do as_owner "$home" dispose "u-r-$i" reply --summary "$i $long" >/dev/null 2>&1 || { fail "dispose u-r-$i failed"; break; }; done
printf 'dispose x259 took %ss; receipt log: %s bytes\n' "$(( $(date +%s) - t0 ))" "$(wc -c < "$home/state/request-intake/sess-1.jsonl")"
[ "$(wc -c < "$home/state/request-intake/sess-1.jsonl")" -gt 131072 ] || fail "receipt log not over 128 KB"
out=$(as_owner "$home" list 2>&1); rc=$?
printf 'list rc=%s output:\n%s\n' "$rc" "$(printf '%s' "$out" | head -c 600)"
[ "$rc" = 0 ] || fail "list failed with receipt log over 128 KB"
assert_contains "$out" "[u-r-260]" "the one undisposed input is not listed"
case "$out" in *"[u-r-1]"*|*"[u-r-259]"*) fail "disposed inputs still listed";; esac
[ "$FAILED" = 0 ] && pass "with a receipt log over 128 KB, only the undisposed input is listed"

echo "=== Scenario C: temp files are cleaned up"
left=$(find "$TMPDIR" -mindepth 1 | head); [ -z "$left" ] && pass "no fm-request-continuity temp dirs left in TMPDIR" || fail "leftover temp: $left"

echo "=== Scenario D: unwritable TMPDIR - hooks still never fail the turn"
TMPDIR=/nonexistent-dir-xyz; export TMPDIR
out=$(stop_hook "$W/main" 2>&1); rc=$?; printf 'stop hook rc=%s out=[%s]\n' "$rc" "$out"
out=$(as_owner "$W/main" list 2>&1); rc=$?; printf 'list rc=%s out=[%s]\n' "$rc" "$out"
export TMPDIR="$W/tmpdir"
echo "FAILED=$FAILED"

#!/usr/bin/env bash
# Behavior tests for bin/fm-quote-check.sh.
#
# A main home and a registered second mate home get Claude Code transcripts and
# a Lavish session store laid out in the real record shapes: typed prompts, a
# prompt absorbed mid-turn, an accepted suggestion, a paste, tool output, a hook
# injection, assistant text, a supervision wake and Firstmate's own envelope
# and doorbells. The source is built through the public command and pages are
# checked against it, so each case asserts what counts as the captain's words
# and what a check flags. Nothing here reads production state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QC="$ROOT/bin/fm-quote-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-quote-check)
MAIN="$TMP_ROOT/main"
MATE="$TMP_ROOT/mate"
FAKE_HOME="$TMP_ROOT/home"
LAVISH="$TMP_ROOT/lavish"
PAGES="$TMP_ROOT/pages"
SOURCE="$MAIN/data/captain-words/source.json"

slug() { printf '%s' "$1" | tr '/.' '--'; }
mode_of() { stat -c %a "$1" 2>/dev/null || /usr/bin/stat -f %Lp "$1"; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || /usr/bin/stat -f %m "$1"; }
age_by() { fm_touch_epoch "$(( $(date +%s) - $2 * 3600 ))" "$1"; }  # <file> <hours>

seed_fixture() {
  mkdir -p "$MAIN/data" "$MATE/data/board" "$MAIN/data/board" "$LAVISH" "$PAGES" \
    "$FAKE_HOME/.claude/projects/$(slug "$MAIN")" "$FAKE_HOME/.claude/projects/$(slug "$MATE")"
  printf -- '- trelume - Trelume domain (home: %s; scope: Trelume work; projects: Trelume; added 2026-10-01)\n' "$MATE" \
    > "$MAIN/data/secondmates.md"
  python3 -I - "$FAKE_HOME/.claude/projects/$(slug "$MAIN")/main.jsonl" \
    "$FAKE_HOME/.claude/projects/$(slug "$MATE")/mate.jsonl" "$LAVISH/state.json" "$MAIN" "$MATE" "$TMP_ROOT" <<'PY'
import json, sys
main, mate, lavish, main_home, mate_home, root = sys.argv[1:]
human = {"kind": "human"}

def user(text, uuid, **kw):
    e = {"type": "user", "uuid": uuid, "timestamp": "2026-10-20T01:00:00Z", "isSidechain": False,
         "message": {"role": "user", "content": text}}
    e.update(kw)
    return e

rows = [
    user("I probably have a long sentence, then a short one. And then I go back to long sentences",
         "u1", origin=human, promptSource="typed"),
    user("this is a reel i watched:\n\n<pasted_content id=\"0f2f\">\nPasted reel words about cold email domains\n</pasted_content id=\"0f2f\">",
         "u2", origin=human, promptSource="typed"),
    user([{"type": "tool_result", "tool_use_id": "t1", "content": "tool output that nobody typed"}], "u3"),
    user("Stop hook feedback: hook injection text", "u4", isMeta=True),
    user("FIRSTMATE SUPERVISION WAKE: signal: wake text", "u5", promptSource="typed"),
    user("⁣FIRSTMATE_OP: v1 launch-brief: envelope body text", "u6", origin=human, promptSource="typed"),
    user(": Firstmate instruction waiting: list \"$FM_TASK_INBOX\"/*.msg in your 'trelume.inbox' steering inbox, read and act on each in numeric order, then mv each into its handled/.",
         "u7", origin=human, promptSource="typed"),
    user(": Firstmate operational input waiting: read '/x/state/operational-inbox/1793685593-127af4e4.msg' and handle its contents as Firstmate operational input.",
         "u13", origin=human, promptSource="typed"),
    user("B with the allowance, adopt the proposal", "u8", origin=human, promptSource="suggestion_accepted"),
    user("<command-message>deeper</command-message>\n<command-name>/deeper</command-name>\n<command-args>make the brief deeper please</command-args>",
         "u9", origin=human),
    user("sidechain words never typed by the captain", "u10", origin=human, promptSource="typed", isSidechain=True),
    {"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "stop_reason": "end_turn",
     "content": [{"type": "text", "text": "assistant words the captain never typed"}]}},
    {"type": "attachment", "uuid": "q1", "timestamp": "2026-10-20T02:00:00Z", "isSidechain": False,
     "attachment": {"type": "queued_command", "commandMode": "prompt", "origin": human, "source_uuid": "s1",
                    "prompt": "for maintenance i wan to add sentry and posthog"}},
    {"type": "attachment", "uuid": "q2", "isSidechain": False,
     "attachment": {"type": "queued_command", "commandMode": "task-notification",
                    "origin": {"kind": "task-notification"}, "prompt": "task notification words"}},
    user("and how about design as well? I'm still not satisfied with it", "u11", origin=human, promptSource="typed"),
    user("pick the recommended direction", "u12", origin=human, promptSource="queued"),
    user("i do not want to ship it", "u14", origin=human, promptSource="typed"),
    user("i want to ship it", "u15", origin=human, promptSource="typed"),
    user("hmm... let's do it then", "u17", origin=human, promptSource="typed"),
    user("it’s far too loud on the header", "u16", origin=human, promptSource="typed"),
]
with open(main, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r, separators=(",", ":")) + "\n")
with open(mate, "w") as fh:
    fh.write(json.dumps(user("i also want to implement all of these:", "m1", origin=human, promptSource="typed"), separators=(",", ":")) + "\n")
    fh.write(json.dumps(user("⁣FIRSTMATE_OP: v1 branch-outcome: mate envelope", "m2", origin=human, promptSource="typed"), separators=(",", ":")) + "\n")

note = "the ideal offering im aiming for is 15k upfront. this is all usd of course"
annotation = ("R47 (Upsell timing): the captain picks \"Settle the four prices now\". Note, verbatim: \"%s\" Record it.\n\n"
              "Context data:\n%s" % (note, json.dumps({"card": "R47", "answer": "Settle the four prices now", "note": note}, indent=2)))
state = {"sessions": {
    "inmain": {"file": main_home + "/data/board/index.html", "chat": [
        {"role": "user", "kind": "annotation", "text": annotation, "at": "2026-10-18T07:42:00Z", "prompt_id": "p1"},
        {"role": "user", "kind": "message", "text": "theres literally no image", "at": "2026-10-18T07:43:00Z", "prompt_id": "p2"},
        {"role": "agent", "text": "agent reply words in lavish", "at": "2026-10-18T07:44:00Z"},
        {"role": "user", "kind": "layout-warnings", "text": "Fix this layout issue the browser detected", "prompt_id": "p3"}]},
    "inmate": {"file": mate_home + "/data/board/index.html", "chat": [
        {"role": "user", "kind": "annotation", "text": "the heading reads too loud here", "anchor": {"kind": "element"}, "prompt_id": "p4"}]},
    "elsewhere": {"file": root + "/other/index.html", "chat": [
        {"role": "user", "kind": "message", "text": "words typed on a page outside both homes", "prompt_id": "p5"}]},
}}
with open(lavish, "w") as fh:
    json.dump(state, fh)
PY
}

qc() {
  HOME="$FAKE_HOME" FM_HOME="$MAIN" LAVISH_AXI_STATE_DIR="$LAVISH" "$QC" "$@"
}

# check_quote <marker> <page-body> -> prints output; sets RC.
RC=0
check_page() {  # <name> <marker> <html-body>
  printf '<!doctype html><html><body>%s</body></html>\n' "$3" > "$PAGES/$1.html"
  OUT=$(qc check "$PAGES/$1.html" --marker "$2" 2>&1) && RC=0 || RC=$?
}

test_source_holds_only_typed_captain_words_from_both_homes() {
  seed_fixture
  local out
  out=$(qc refresh 2>&1) || fail "refresh failed: $out"
  assert_contains "$out" "refreshed:" "refresh reports what it built"
  assert_present "$SOURCE" "refresh writes the home's source"
  assert_equals 600 "$(mode_of "$SOURCE")" "the source is private to its owner"
  assert_equals 700 "$(mode_of "$(dirname "$SOURCE")")" "the source directory is private to its owner"
  assert_not_contains "$out" "long sentence" "refresh never prints the captain's words"
  python3 -I - "$SOURCE" "$MAIN" "$MATE" <<'PY' || fail "the source holds the wrong messages"
import json, sys
d = json.load(open(sys.argv[1]))
texts = [m["text"] for m in d["messages"]]
blob = "\n".join(texts)
want = ["I probably have a long sentence", "this is a reel i watched:", "B with the allowance",
        "make the brief deeper please", "for maintenance i wan to add sentry and posthog",
        "i also want to implement all of these:", "the ideal offering im aiming for is 15k upfront",
        "theres literally no image", "the heading reads too loud here", "pick the recommended direction"]
for w in want:
    assert w in blob, ("missing", w)
never = ["Pasted reel words", "tool output", "hook injection", "SUPERVISION WAKE", "envelope body",
         "Firstmate instruction waiting", "operational input waiting", "sidechain words", "assistant words", "task notification words",
         "agent reply words", "layout issue", "outside both homes", "mate envelope", "R47 (Upsell timing)",
         "Context data", "<command-"]
for n in never:
    assert n not in blob, ("leaked", n)
homes = {m["home"] for m in d["messages"] if m["channel"] == "claude"}
assert homes == {sys.argv[2], sys.argv[3]}, homes
assert d["excluded_operational"] == 4, d["excluded_operational"]
PY
  out=$(qc status 2>&1) || fail "status failed: $out"
  assert_contains "$out" "fresh: yes" "status reports a fresh source"
  assert_contains "$out" "claude:$MATE: 1" "status counts the second mate home's messages"
  assert_not_contains "$out" "implement all" "status never prints the captain's words"
  pass "the source holds typed captain words from both homes and Lavish notes, and nothing agents wrote or pasted"
}

test_invented_and_altered_quotes_are_flagged_and_real_ones_pass() {
  # The checklist board's F1 card: a paraphrase in quote marks, attributed to the captain.
  check_page f1 attributed "<p><span class=\"why\">Your transcript said 'long, then short, then back to long'. The opening does that.</span></p>"
  expect_code 1 "$RC" "the invented F1 quote is flagged"
  assert_contains "$OUT" 'misquote: "long, then short, then back to long" (attributed' "the flag names the invented quote and its marker"
  assert_contains "$OUT" "1 misquoted" "the count names one misquote"
  # Adjacent labels must not fuse into one word and hide the cue.
  check_page fused attributed "<span>Recommended</span><span>Your words: \"then a short one. And then I go back to long sentences\"</span>"
  expect_code 0 "$RC" "a real attributed quote after an adjacent label passes"
  assert_contains "$OUT" "1 checked, 1 verbatim" "the real attributed quote was found and matched"
  # The decisions board's verbatim boxes: one typed in the second mate's session, one on a board form.
  check_page boxes class:verbatim '<blockquote class="verbatim">i also want to implement all of these</blockquote><blockquote class="verbatim">&ldquo;The ideal offering im aiming for is 15k upfront&rdquo;</blockquote>'
  expect_code 0 "$RC" "real quotes from the second mate's session and a board note pass"
  assert_contains "$OUT" "2 checked, 2 verbatim, 0 misquoted" "both real quotes are verbatim"
  check_page altered class:verbatim '<blockquote class="verbatim">i also want to implement all of those</blockquote>'
  expect_code 1 "$RC" "one changed word is a misquote"
  check_page reordered class:verbatim '<blockquote class="verbatim">I probably have a short sentence, then a long one</blockquote>'
  expect_code 1 "$RC" "reordered words are a misquote"
  # Typeset quotes: a curly apostrophe inside a curly single-quoted span.
  check_page curly attributed '<p>You said &lsquo;it&rsquo;s far too quiet&rsquo;. ok</p>'
  expect_code 1 "$RC" "a curly-quoted misquote holding a curly apostrophe is found and flagged"
  assert_contains "$OUT" "misquote: \"it$(printf '\342\200\231')s far too quiet\"" "the whole curly span is the quote"
  check_page curlyreal attributed '<p>You said &lsquo;it&rsquo;s far too loud&rsquo;. ok</p>'
  expect_code 0 "$RC" "a real curly-quoted quote holding a curly apostrophe passes"
  assert_contains "$OUT" "1 checked, 1 verbatim" "the real curly quote was found and matched"
  pass "an invented or altered quote is flagged while real quotes from both homes and board notes pass"
}

test_words_the_captain_did_not_type_are_flagged() {
  local quote
  for quote in "Pasted reel words about cold email domains" "tool output that nobody typed" \
    "assistant words the captain never typed" "agent reply words in lavish" "R47 (Upsell timing)" \
    "words typed on a page outside both homes"; do
    check_page notcaptain class:verbatim "<blockquote class=\"verbatim\">$quote</blockquote>"
    expect_code 1 "$RC" "a quote of text the captain did not type is flagged: $quote"
  done
  pass "pasted text, tool output, agent text and pages outside both homes never count as the captain's words"
}

test_ellipsis_parts_must_come_from_one_message() {
  check_page within class:verbatim '<blockquote class="verbatim">I probably have a long sentence &hellip; then I go back to long sentences</blockquote>'
  expect_code 1 "$RC" "an ellipsis inside one message is flagged for review"
  assert_contains "$OUT" 'verbatim with omissions: "I probably have a long sentence' "an ellipsis quote has its own status"
  assert_contains "$OUT" "0 misquoted, 1 with omissions" "the count names the omission separately"
  assert_not_contains "$OUT" "short one" "without --verbose the omitted words are not printed"
  local out rc
  printf '<!doctype html><html><body><blockquote class="verbatim">i do ... want to ship it</blockquote></body></html>\n' > "$PAGES/omit.html"
  out=$(qc check "$PAGES/omit.html" --verbose 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "an ellipsis that drops a word is flagged"
  assert_contains "$out" 'verbatim with omissions: "i do ... want to ship it"' "the quote is verbatim with omissions"
  assert_contains "$out" 'omitted: "not"' "--verbose names the omitted word"
  out=$(qc check "$PAGES/omit.html" --json 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "--json exits the same way"
  python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
assert [(r["verdict"], r["omitted"]) for r in d["results"]] == [("verbatim with omissions", ["not"])], d["results"]
assert d["summary"]["omissions"] == 1 and d["summary"]["verbatim"] == 0, d["summary"]
' "$out" || fail "the JSON result lists the omitted words: $out"
  check_page owndots class:verbatim '<blockquote class="verbatim">hmm... let&#39;s do it</blockquote>'
  expect_code 0 "$RC" "a word-for-word quote of a message with the captain's own ellipsis passes"
  assert_contains "$OUT" "1 checked, 1 verbatim, 0 misquoted, 0 with omissions" "the captain's own ellipsis omits nothing"
  check_page cut class:verbatim '<blockquote class="verbatim">&hellip; want to ship it &hellip;</blockquote>'
  expect_code 0 "$RC" "an ellipsis marking a cut at either end passes"
  check_page bracketed class:verbatim '<blockquote class="verbatim">i [don t] want to ship it</blockquote>'
  expect_code 1 "$RC" "bracketed words that are not in the source are a misquote"
  assert_contains "$OUT" 'misquote: "i [don t] want to ship it"' "the bracketed edit is flagged as a misquote"
  check_page bracket class:verbatim '<blockquote class="verbatim">for maintenance i [wan] to add sentry and posthog</blockquote>'
  expect_code 0 "$RC" "bracketed words that match the source are ordinary words"
  check_page spliced class:verbatim '<blockquote class="verbatim">and how about design as well? &hellip; pick the recommended direction</blockquote>'
  expect_code 1 "$RC" "parts spliced from two messages are flagged"
  check_page backwards class:verbatim '<blockquote class="verbatim">then I go back to long sentences ... I probably have a long sentence</blockquote>'
  expect_code 1 "$RC" "parts out of order are flagged"
  pass "an ellipsis joins parts of one message in order and is flagged with its omitted words, and bracketed words must match"
}

test_regex_marker_json_and_markdown_pages() {
  printf '# Notes\n\nCaptain line: <<theres literally no image>> and <<there is no image at all>>\n' > "$PAGES/notes.md"
  local out rc
  out=$(qc check "$PAGES/notes.md" --marker 'regex:<<(?P<q>.*?)>>' --json 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a regex marker on a Markdown page flags the paraphrase"
  python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
v = {r["quote"]: r["verdict"] for r in d["results"]}
assert v == {"theres literally no image": "verbatim", "there is no image at all": "misquote"}, v
assert d["summary"]["misquote"] == 1, d["summary"]
' "$out" || fail "the JSON result names each quote's verdict: $out"
  pass "a regex marker reads the q group, Markdown is read as text, and --json carries every verdict"
}

test_check_refreshes_a_stale_source_and_keeps_a_fresh_one() {
  rm -f "$SOURCE"
  check_page fresh class:verbatim '<blockquote class="verbatim">pick the recommended direction</blockquote>'
  expect_code 0 "$RC" "a check with no source builds one first"
  assert_present "$SOURCE" "the check built the missing source"
  age_by "$SOURCE" 2
  local before
  before=$(mtime_of "$SOURCE")
  check_page fresh class:verbatim '<blockquote class="verbatim">pick the recommended direction</blockquote>'
  assert_equals "$before" "$(mtime_of "$SOURCE")" "a source younger than a day is reused"
  age_by "$SOURCE" 25
  before=$(mtime_of "$SOURCE")
  check_page fresh class:verbatim '<blockquote class="verbatim">pick the recommended direction</blockquote>'
  assert_not_equals "$before" "$(mtime_of "$SOURCE")" "a source older than a day is rebuilt before checking"
  local out rc
  out=$(qc check "$PAGES/fresh.html" --source "$TMP_ROOT/missing.json" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a named source that cannot be read is a usage error"
  out=$(qc check "$TMP_ROOT/no-such-page.html" 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a missing page is a usage error"
  out=$(qc check "$PAGES/fresh.html" --marker shout 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown marker is a usage error"
  out=$(qc check "$PAGES/fresh.html" --marker 'regex:(unclosed' 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an invalid regex marker is a usage error"
  assert_contains "$out" "invalid regex marker" "the invalid regex is named"
  assert_not_contains "$out" "Traceback" "an invalid regex is reported without a traceback"
  pass "a check rebuilds a missing or day-old source, reuses a fresh one, and refuses bad input"
}

test_secondmate_home_resolves_its_parent_and_siblings() {
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
  local out
  out=$(HOME="$FAKE_HOME" FM_HOME="$MATE" LAVISH_AXI_STATE_DIR="$LAVISH" "$QC" refresh 2>&1) || fail "refresh from the second mate home failed: $out"
  python3 -I - "$MATE/data/captain-words/source.json" "$MAIN" "$MATE" <<'PY' || fail "a second mate's source must cover its parent and itself"
import json, sys
d = json.load(open(sys.argv[1]))
assert {h["home"] for h in d["homes"]} == {sys.argv[2], sys.argv[3]}, d["homes"]
PY
  pass "run from a second mate home, the source covers the parent home and every registered mate"
}

fm_test_run \
  test_source_holds_only_typed_captain_words_from_both_homes \
  test_invented_and_altered_quotes_are_flagged_and_real_ones_pass \
  test_words_the_captain_did_not_type_are_flagged \
  test_ellipsis_parts_must_come_from_one_message \
  test_regex_marker_json_and_markdown_pages \
  test_check_refreshes_a_stale_source_and_keeps_a_fresh_one \
  test_secondmate_home_resolves_its_parent_and_siblings

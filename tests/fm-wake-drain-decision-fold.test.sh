#!/usr/bin/env bash
# tests/fm-wake-drain-decision-fold.test.sh - behavior tests for how
# bin/fm-wake-drain.sh repeats what an actor already acknowledged seeing.
# An open decision the actor's last acknowledged drain presented in full, and
# that has not changed since, folds into one line naming it; a new or changed
# decision prints in full; --decisions lists every open decision in full. Once-
# only sections a drain presents under an acknowledgement request are
# re-presented until that acknowledgement lands, so a truncated or filtered
# read loses nothing. Every case drives the real drain over crafted status logs
# and asserts on its printed output.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-decision-fold-tests)

# drain_with_wake <state> <out> <err> <label>: queue one heartbeat-shaped wake so
# the drain asks for an acknowledgement, then drain into <out>/<err>.
drain_with_wake() {
  local state=$1 out=$2 err=$3 label=$4
  append_wake "$state" heartbeat "hb-$label" "heartbeat: $label" \
    || fail "queueing the $label wake failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "the $label drain failed: $(cat "$err")"
  grep -F 'WAKE_ACK_REQUIRED:' "$err" >/dev/null \
    || fail "setup error: the $label drain asked for no acknowledgement"
}

seed_two_decisions() {  # <state>
  printf 'needs-decision [key=seo]: approve the SEO page copy\n' > "$1/trelume.status"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$1/api.status"
}

test_first_presentation_prints_every_decision_in_full() {
  local dir state out err
  dir=$(make_case first)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"
  seed_two_decisions "$state"

  drain_with_wake "$state" "$out" "$err" first

  grep -F 'trelume [key=seo] needs-decision: approve the SEO page copy' "$out" >/dev/null \
    || fail "a never-acknowledged decision was not printed in full: $(cat "$out")"
  grep -F 'api [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "the second never-acknowledged decision was not printed in full: $(cat "$out")"
  if grep -F 'unchanged since' "$out" >/dev/null; then
    fail "a first presentation folded decisions nobody acknowledged: $(cat "$out")"
  fi
  pass "a first presentation prints every open decision in full"
}

test_unacknowledged_repeat_stays_in_full() {
  local dir state out err
  dir=$(make_case unacked)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"
  seed_two_decisions "$state"

  drain_with_wake "$state" "$out" "$err" first
  # No acknowledgement: the handling turn never confirmed it read them.
  drain_with_wake "$state" "$out" "$err" second

  grep -F 'trelume [key=seo] needs-decision: approve the SEO page copy' "$out" >/dev/null \
    || fail "a decision folded although no acknowledgement covered its presentation: $(cat "$out")"
  pass "decisions stay in full until an acknowledgement covers the drain that showed them"
}

test_acknowledged_repeat_folds_into_one_line() {
  local dir state out err lines
  dir=$(make_case folded)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"
  seed_two_decisions "$state"

  drain_with_wake "$state" "$out" "$err" first
  ack_drain_err "$state" "$err" >/dev/null 2>&1 || fail "acknowledging the first drain failed"
  drain_with_wake "$state" "$out" "$err" second

  if grep -F 'approve the SEO page copy' "$out" >/dev/null \
    || grep -F 'pick REST or RPC' "$out" >/dev/null; then
    fail "an acknowledged, unchanged decision was repeated in full: $(cat "$out")"
  fi
  lines=$(grep -c 'OPEN DECISIONS' "$out")
  [ "$lines" -eq 1 ] || fail "the unchanged decisions took $lines OPEN DECISIONS lines, not one: $(cat "$out")"
  grep -F 'OPEN DECISIONS: 2 unchanged since' "$out" | grep -F 'trelume[seo]' | grep -F 'api[api-shape]' \
    | grep -F 'bin/fm-wake-drain.sh --decisions' >/dev/null \
    || fail "the fold line does not count, name, and point to the full list: $(cat "$out")"
  pass "acknowledged, unchanged decisions fold into one line that names them"
}

test_changed_and_new_decisions_print_in_full_beside_the_fold() {
  local dir state out err
  dir=$(make_case changed)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"
  seed_two_decisions "$state"
  printf 'needs-decision [key=rate]: pick a plan tier\n' > "$state/billing.status"

  drain_with_wake "$state" "$out" "$err" first
  ack_drain_err "$state" "$err" >/dev/null 2>&1 || fail "acknowledging the first drain failed"
  # One decision's question changes under the same key, and a new one opens.
  printf 'needs-decision [key=api-shape]: pick REST or GraphQL now\n' >> "$state/api.status"
  printf 'blocked [key=dns]: registrar login expired\n' > "$state/infra.status"
  drain_with_wake "$state" "$out" "$err" second

  grep -F 'api [key=api-shape] needs-decision: pick REST or GraphQL now' "$out" >/dev/null \
    || fail "a changed decision was not printed in full: $(cat "$out")"
  grep -F 'infra [key=dns] blocked: registrar login expired' "$out" >/dev/null \
    || fail "a new decision was not printed in full: $(cat "$out")"
  grep -F 'OPEN DECISIONS: 2 unchanged since' "$out" | grep -F 'trelume[seo]' | grep -F 'billing[rate]' >/dev/null \
    || fail "the unchanged decisions were not folded beside the changed one: $(cat "$out")"
  if grep -F 'approve the SEO page copy' "$out" >/dev/null; then
    fail "an unchanged decision was repeated in full next to a changed one: $(cat "$out")"
  fi
  pass "a changed or new decision prints in full while the unchanged ones stay folded"
}

test_decisions_flag_lists_everything_without_consuming_anything() {
  local dir state out err list queued_before queued_after
  dir=$(make_case list-flag)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"; list="$dir/list.out"
  seed_two_decisions "$state"

  drain_with_wake "$state" "$out" "$err" first
  ack_drain_err "$state" "$err" >/dev/null 2>&1 || fail "acknowledging the first drain failed"
  append_wake "$state" heartbeat hb-pending "heartbeat: pending" || fail "queueing a pending wake failed"
  queued_before=$(cat "$state/.wake-queue")

  FM_STATE_OVERRIDE="$state" "$DRAIN" --decisions > "$list" 2> "$err" \
    || fail "--decisions failed: $(cat "$err")"

  grep -F 'trelume [key=seo] needs-decision: approve the SEO page copy' "$list" >/dev/null \
    || fail "--decisions did not list a folded decision in full: $(cat "$list")"
  grep -F 'api [key=api-shape] needs-decision: pick REST or RPC' "$list" >/dev/null \
    || fail "--decisions did not list every decision in full: $(cat "$list")"
  if grep -F 'heartbeat: pending' "$list" >/dev/null || grep -F 'WAKE_ACK_REQUIRED' "$err" >/dev/null; then
    fail "--decisions presented the wake queue instead of only listing decisions"
  fi
  queued_after=$(cat "$state/.wake-queue")
  [ "$queued_before" = "$queued_after" ] || fail "--decisions changed the wake queue"

  # The listing is not a presentation the fold can count as acknowledged.
  printf 'needs-decision [key=fresh]: a brand new question\n' > "$state/fresh.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --decisions > "$list" 2>/dev/null || fail "second --decisions failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain after --decisions failed"
  grep -F 'fresh [key=fresh] needs-decision: a brand new question' "$out" >/dev/null \
    || fail "a decision seen only through --decisions was folded by the next drain: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --decisions extra > /dev/null 2>&1 \
    && fail "--decisions accepted an unexpected argument"
  pass "--decisions lists every open decision in full and consumes nothing"
}

test_decisions_flag_skips_the_drain_byte_caps() {
  local dir state out err list long i
  dir=$(make_case list-uncapped)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"; list="$dir/list.out"
  long="answer the long question $(printf 'x%.0s' $(seq 1 300)) end-of-question"
  printf 'needs-decision [key=long]: %s\n' "$long" > "$state/long.status"
  for i in $(seq 1 30); do
    printf 'needs-decision [key=k%s]: decision number %s %s\n' "$i" "$i" "$(printf 'y%.0s' $(seq 1 150))" \
      > "$state/many$i.status"
  done

  drain_with_wake "$state" "$out" "$err" capped
  if grep -F 'end-of-question' "$out" >/dev/null; then
    fail "setup error: the drain printed the long decision without its per-item cap"
  fi
  grep -F 'more omitted (byte cap)' "$out" >/dev/null \
    || fail "setup error: the drain printed every decision without its section cap: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --decisions > "$list" 2> "$err" \
    || fail "--decisions failed: $(cat "$err")"
  grep -F "long [key=long] needs-decision: $long" "$list" >/dev/null \
    || fail "--decisions truncated a long decision: $(cat "$list")"
  for i in $(seq 1 30); do
    grep -F "many$i [key=k$i] needs-decision: decision number $i " "$list" >/dev/null \
      || fail "--decisions omitted decision $i: $(cat "$list")"
  done
  if grep -F 'omitted (byte cap)' "$list" >/dev/null; then
    fail "--decisions applied the drain's section byte cap: $(cat "$list")"
  fi
  pass "--decisions prints every open decision untruncated while drains keep their caps"
}

test_new_session_sees_every_decision_in_full_again() {
  local dir state out err
  dir=$(make_case new-session)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"
  seed_two_decisions "$state"
  printf '%s\n' "$$" > "$state/.lock"

  drain_with_wake "$state" "$out" "$err" first
  ack_drain_err "$state" "$err" >/dev/null 2>&1 || fail "acknowledging the first drain failed"
  # A new session takes the lock: its agent never saw the earlier presentation.
  printf '%s\n' "$(dead_pid)" > "$state/.lock"
  drain_with_wake "$state" "$out" "$err" second

  grep -F 'trelume [key=seo] needs-decision: approve the SEO page copy' "$out" >/dev/null \
    || fail "a new session inherited the previous session's fold: $(cat "$out")"
  pass "a new session sees every open decision in full again"
}

test_branch_acknowledgement_does_not_fold_for_main() {
  local dir state out err owner
  dir=$(make_case per-actor)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"
  mkdir -p "$dir/data"
  seed_two_decisions "$state"
  append_wake "$state" signal trelume.status "signal: trelume" || fail "queueing the branch wake failed"
  sleep 30 &
  owner=$!
  if ! FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$owner" fold-owner >/dev/null \
    || ! FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish fold-owner --tasks trelume --rows 1 >/dev/null; then
    kill "$owner" 2>/dev/null || true
    fail "publishing the branch grant failed"
  fi

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err" \
    || { kill "$owner" 2>/dev/null || true; fail "the branch drain failed: $(cat "$err")"; }
  grep -F 'trelume [key=seo] needs-decision: approve the SEO page copy' "$out" >/dev/null \
    || { kill "$owner" 2>/dev/null || true; fail "the branch drain did not show the decision in full: $(cat "$out")"; }
  FM_SUPERVISION_ACTOR=branch ack_drain_err "$state" "$err" >/dev/null 2>&1 \
    || { kill "$owner" 2>/dev/null || true; fail "the branch acknowledgement failed"; }
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true

  drain_with_wake "$state" "$out" "$err" main
  grep -F 'trelume [key=seo] needs-decision: approve the SEO page copy' "$out" >/dev/null \
    || fail "main folded a decision only the supervision branch acknowledged: $(cat "$out")"
  pass "one actor's acknowledgement never folds decisions for another actor"
}

test_truncated_read_re_presents_unread_status_until_acknowledged() {
  local dir state out err
  dir=$(make_case truncated)
  state="$dir/state"; out="$dir/drain.out"; err="$dir/drain.err"
  printf 'working: started\n' > "$state/task1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "priming drain failed"

  printf 'note: captain said ship the REST version\n' >> "$state/task1.status"
  printf 'needs-decision [key=host]: pick the hosting region\n' > "$state/task2.status"
  append_wake "$state" heartbeat hb-truncated "heartbeat: truncated" || fail "queueing the wake failed"
  # The reader consumes every byte but keeps only the first line, as a
  # `| grep -v ...` filter does: the drain's own write succeeds, so only an
  # acknowledgement can prove the hidden lines were read.
  FM_STATE_OVERRIDE="$state" "$DRAIN" 2> "$err" | sed -n 1p > "$out"
  if grep -F 'captain said ship the REST version' "$out" >/dev/null; then
    fail "setup error: the truncated read still showed the note"
  fi

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "re-drain after the truncated read failed"
  grep -F 'task1 note: captain said ship the REST version' "$out" >/dev/null \
    || fail "a truncated read permanently lost the UNREAD STATUS note: $(cat "$out")"
  grep -F 'task2 [key=host] needs-decision: pick the hosting region' "$out" >/dev/null \
    || fail "a truncated read lost the new decision's full text: $(cat "$out")"

  ack_drain_err "$state" "$err" >/dev/null 2>&1 || fail "acknowledging the re-drain failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain after the acknowledgement failed"
  if grep -F 'captain said ship the REST version' "$out" >/dev/null; then
    fail "an acknowledged UNREAD STATUS note was presented again: $(cat "$out")"
  fi
  pass "once-only sections are re-presented until an acknowledgement covers the drain that showed them"
}

test_first_presentation_prints_every_decision_in_full
test_unacknowledged_repeat_stays_in_full
test_acknowledged_repeat_folds_into_one_line
test_changed_and_new_decisions_print_in_full_beside_the_fold
test_decisions_flag_lists_everything_without_consuming_anything
test_decisions_flag_skips_the_drain_byte_caps
test_new_session_sees_every_decision_in_full_again
test_branch_acknowledgement_does_not_fold_for_main
test_truncated_read_re_presents_unread_status_until_acknowledged

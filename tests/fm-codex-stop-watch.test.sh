#!/usr/bin/env bash
# Portable executable tests of the Stop owner, not native-hook acceptance.
# shellcheck disable=SC2016 # Child-shell commands must expand in the fixture.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-stop-watch)
python3 "$ROOT/tests/fm-codex-stop-watch-fixture.py"
fm_git_identity fmtest fmtest@example.invalid
P="$TMP_ROOT/primary"
mkdir -p "$P/bin" "$P/state" "$P/config" "$TMP_ROOT/native" "$TMP_ROOT/cli" "$TMP_ROOT/codex-home"
git init -q "$P"
: > "$P/AGENTS.md"
for script in fm-codex-stop-watch.sh fm-codex-watch-lib.sh fm-primary-scope-lib.sh fm-gate-refuse-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-lock.sh fm-treehouse-slot-lib.sh fm-wake-lib.sh fm-timeout-lib.sh; do
  cp "$ROOT/bin/$script" "$P/bin/"
done
cp "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$P/bin/"
ln -s /bin/bash "$TMP_ROOT/native/codex"
cat > "$P/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "$STATE/arms"
exit 0
SH
cat > "$TMP_ROOT/cli/codex" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = queue ]
[ ! -d "$STATE/.wake-queue.lock" ] || exit 77
printf '%s\n' "$*" >> "$STATE/deliveries"
[ ! -e "$STATE/fail-queue" ] || exit 1
if [ -e "$STATE/late" ]; then
  rm "$STATE/late"
  bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; fm_wake_append check late "check: late"'
fi
if [ -e "$STATE/steal" ]; then printf '99999999\n' > "$STATE/.lock"; fi
printf 'Queued\n'
SH
chmod +x "$P/bin/"*.sh "$TMP_ROOT/cli/codex"
export FM_HOME="$P" FM_ROOT_OVERRIDE="$P" FM_STATE_OVERRIDE="$P/state" STATE="$P/state"
export FM_CONFIG_OVERRIDE="$P/config" CODEX_HOME="$TMP_ROOT/codex-home"
export PATH="$TMP_ROOT/cli:$PATH"
export TEST_NATIVE="$TMP_ROOT/native/codex"
cat > "$TMP_ROOT/scenarios" <<'SH'
set -eu
printf '%s\n' "$$" > "$STATE/.lock"
. "$FM_HOME/bin/fm-wake-lib.sh"
payload='{"hook_event_name":"Stop","session_id":"01a0ed98-600a-7c81-98d6-56affd853dec","stop_hook_active":true}'
hook() { printf '%s\n' "$payload" | "$FM_HOME/bin/fm-codex-stop-watch.sh"; }
count() { wc -l < "$STATE/deliveries" | tr -d ' '; }
fm_wake_append check first 'check: first'
hook
[ "$(count)" = 1 ]
[ -s "$STATE/.wake-queue" ]
hook
[ "$(count)" = 1 ]
touch "$STATE/late"
fm_wake_append check second 'check: second'
hook
[ "$(count)" = 2 ]
hook
[ "$(count)" = 3 ]
[ "$(jq .seq "$STATE/.codex-watch-delivered")" = 3 ]
touch "$STATE/.afk"
fm_wake_append check away 'check: away'
hook
[ "$(count)" = 3 ]
rm "$STATE/.afk"
touch "$STATE/fail-queue"
if hook; then exit 20; fi
[ "$(count)" = 5 ]
[ -s "$STATE/.codex-watch-error" ]
[ "$(jq .seq "$STATE/.codex-watch-delivered")" = 3 ]
[ "$(wc -l < "$STATE/.wake-queue")" = 4 ]
rm "$STATE/fail-queue"
hook
[ "$(count)" = 6 ]
[ ! -e "$STATE/.codex-watch-error" ]
fm_wake_append check gate 'check: gate'
FM_GATE_REFUSE_BYPASS= NO_MISTAKES_GATE=1 hook
[ "$(count)" = 6 ]
"$TEST_NATIVE" -c 'sleep 3; :' &
foreign=$!
printf '%s\n' "$foreign" > "$STATE/.lock"
hook
[ "$(count)" = 6 ]
wait "$foreign"
# The dead numeric owner is recovered through fm-lock, never a raw repair.
hook
[ "$(count)" = 7 ]
fm_wake_append check lost 'check: owner lost during delivery'
touch "$STATE/steal"
hook
[ "$(count)" = 8 ]
[ "$(jq .seq "$STATE/.codex-watch-delivered")" = 5 ]
SH
"$TMP_ROOT/native/codex" "$TMP_ROOT/scenarios"
pass 'Codex owner coalesces, observes late rows, preserves exact-ack custody and fails visibly outside the queue lock'

cat > "$P/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = park ] && [ "$FM_SUPERVISION_HOST_PRIMARY" = codex ] || exit 90
printf 'host\n' >> "$STATE/hosts"
case "$(cat "$STATE/host-mode")" in
  boundary) printf 'supervision-host: cycle boundary - end the turn\n' ;;
  outcome)
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_wake_append check outcome 'check: branch outcome'
    printf 'supervision-host: outcome 1 for task [captain]: review required\n'
    ;;
  failed) exit 7 ;;
  lost)
    printf '99999999\n' > "$STATE/.lock"
    printf 'supervision-host: cycle boundary\n'
    ;;
esac
SH
chmod +x "$P/bin/fm-supervision-host.sh"
cat > "$TMP_ROOT/host-scenarios" <<'SH'
set -eu
printf '%s\n' "$$" > "$STATE/.lock"
rm -f "$STATE/steal" "$STATE/.wake-queue" "$STATE/.codex-watch-delivered" "$STATE/deliveries"
touch "$STATE/host-task.meta"
payload='{"hook_event_name":"Stop","session_id":"01a0ed98-600a-7c81-98d6-56affd853dec"}'
hook() { printf '%s\n' "$payload" | "$FM_HOME/bin/fm-codex-stop-watch.sh"; }
printf 'claude\n' > "$FM_HOME/config/supervision-host"
printf 'boundary\n' > "$STATE/host-mode"
hook
grep -q 'supervision-host: cycle boundary' "$STATE/deliveries"
[ ! -e "$STATE/.codex-watch-delivered" ]
printf 'outcome\n' > "$STATE/host-mode"
hook
grep -q 'review required' "$STATE/deliveries"
[ -s "$STATE/.wake-queue" ]
seq=$(jq .seq "$STATE/.codex-watch-delivered")
printf 'boundary\n' > "$STATE/host-mode"
hook
[ "$(jq .seq "$STATE/.codex-watch-delivered")" = "$seq" ]
[ "$(grep -c '^queue ' "$STATE/deliveries")" = 3 ]
printf 'failed\n' > "$STATE/host-mode"
if hook; then exit 21; fi
[ -s "$STATE/.codex-watch-error" ]
[ "$(grep -c '^queue ' "$STATE/deliveries")" = 3 ]
touch "$FM_HOME/config/supervision-host-off"
hook
[ "$(wc -l < "$STATE/hosts" | tr -d ' ')" = 4 ]
rm "$FM_HOME/config/supervision-host-off"
printf 'lost\n' > "$STATE/host-mode"
hook
[ "$(grep -c '^queue ' "$STATE/deliveries")" = 3 ]
rm "$FM_HOME/config/supervision-host" "$STATE/host-task.meta"
SH
"$TMP_ROOT/native/codex" "$TMP_ROOT/host-scenarios"
pass 'Codex Stop honors host selection, delivers boundaries and outcomes, and suppresses lost-owner handoffs'

# Force a real concurrent Stop while the preceding queue CLI still owns the
# old hook lock. The native CLI is stubbed; drain/ack and lock ownership are real.
cp "$ROOT/bin/"*.sh "$P/bin/"
cat > "$P/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'armed\n' > "$STATE/successor-armed"
while [ ! -e "$STATE/release-arm" ]; do sleep 0.1; done
SH
cat > "$TMP_ROOT/cli/codex" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = queue ]
printf '%s\n' "$*" >> "$STATE/deliveries"
if [ -e "$STATE/overlap" ]; then
  rm "$STATE/overlap"
  touch "$STATE/acceptance-started"
  while [ ! -e "$STATE/release-queue" ]; do sleep 0.1; done
fi
SH
cat > "$TMP_ROOT/overlap-scenario" <<'SH'
set -eu
trap 'touch "$STATE/release-queue" "$STATE/release-arm"; wait' EXIT
printf '%s\n' "$$" > "$STATE/.lock"
. "$FM_HOME/bin/fm-wake-lib.sh"
payload='{"hook_event_name":"Stop","session_id":"01a0ed98-600a-7c81-98d6-56affd853dec","stop_hook_active":true}'
hook() { printf '%s\n' "$payload" | "$FM_HOME/bin/fm-codex-stop-watch.sh"; }
wait_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  [ -e "$1" ]
}
# Need remains after the two events are handled, so the last Stop must watch.
: > "$STATE/task.meta"
touch "$STATE/overlap"
fm_wake_append check first 'handle first'
"$FM_HOME/bin/fm-codex-stop-watch.sh" <<< "$payload" & first=$!
wait_file "$STATE/acceptance-started"
fm_wake_append check successor 'handle successor'
"$FM_HOME/bin/fm-codex-stop-watch.sh" <<< "$payload" & successor=$!
sleep 0.5
# Old nonblocking acquisition drops this successor while first still owns it.
kill -0 "$successor"
touch "$STATE/release-queue"
wait "$first"
wait "$successor"
printf 'overlap deliveries=%s watermark=%s queue_rows=%s\n' "$(wc -l < "$STATE/deliveries")" "$(jq .seq "$STATE/.codex-watch-delivered")" "$(wc -l < "$STATE/.wake-queue")"
[ "$(wc -l < "$STATE/deliveries")" -eq 2 ]
[ "$(jq .seq "$STATE/.codex-watch-delivered")" -eq 2 ]
"$FM_HOME/bin/fm-wake-drain.sh" > "$STATE/presentation" 2>&1
# The fixture's semantic work records the presented event payloads.
awk -F '\t' 'NF >= 5 {print $5}' "$STATE/presentation" > "$STATE/handled"
[ "$(cat "$STATE/handled")" = "handle first
handle successor" ]
ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p' "$STATE/presentation")
[ -n "$ack" ]
(cd "$FM_HOME" && bash -c "$ack")
[ ! -s "$STATE/.wake-queue" ]
"$FM_HOME/bin/fm-codex-stop-watch.sh" <<< "$payload" & watcher=$!
wait_file "$STATE/successor-armed"
[ -s "$STATE/.codex-watch.lock/target.json" ]
owner=$(cat "$STATE/.codex-watch.lock/pid")
kill -0 "$owner"
touch "$STATE/release-arm"
wait "$watcher"
SH
mkdir -p "$P/overlap-state"
FM_STATE_OVERRIDE="$P/overlap-state" STATE="$P/overlap-state" "$TMP_ROOT/native/codex" "$TMP_ROOT/overlap-scenario"
pass 'overlapping Stop waits for delivery, handles both real rows and establishes the next owned cycle'

cat > "$P/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'armed\n' > "$STATE/successor-armed"
if [ -e "$STATE/emit-source" ]; then
  rm "$STATE/emit-source"
  if [ "$CONTENTION_STAGE" = poll ]; then
    touch "$STATE/watcher-returning"
    FM_POLL=1 exec "$FM_HOME/bin/fm-watch.sh"
  fi
  . "$FM_HOME/bin/fm-wake-lib.sh"
  fm_wake_append signal fixture.status 'done: contention event'
  touch "$STATE/watcher-returning"
  while [ ! -e "$STATE/queue-held" ]; do sleep 0.1; done
else
  while [ ! -e "$STATE/release-arm" ]; do sleep 0.1; done
fi
SH
cat > "$TMP_ROOT/cli/codex" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = queue ]
[ ! -e "$STATE/.wake-queue.lock" ]
printf '%s\n' "$*" >> "$STATE/deliveries"
SH
cat > "$TMP_ROOT/contention-scenario" <<'SH'
set -eu
trap 'touch "$STATE/release-queue" "$STATE/release-arm" "$STATE/.afk"; wait' EXIT
printf '%s\n' "$$" > "$STATE/.lock"
. "$FM_HOME/bin/fm-wake-lib.sh"
payload='{"hook_event_name":"Stop","session_id":"01a0ed98-600a-7c81-98d6-56affd853dec"}'
wait_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  [ -e "$1" ]
}
hold_queue() {
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  trap 'fm_lock_release "$FM_WAKE_QUEUE_LOCK"' EXIT
  if [ "$CONTENTION_STAGE" = poll ]; then
    fm_wake_append_locked signal fixture.status 'done: contention event'
  fi
  touch "$STATE/queue-held"
  while [ ! -e "$STATE/release-queue" ]; do sleep 0.1; done
}
: > "$STATE/task.meta"
if [ "$CONTENTION_STAGE" = initial ]; then
  fm_wake_append signal fixture.status 'done: contention event'
  hold_queue & holder=$!
  wait_file "$STATE/queue-held"
else
  touch "$STATE/emit-source"
fi
"$FM_HOME/bin/fm-codex-stop-watch.sh" <<< "$payload" & hook=$!
if [ "$CONTENTION_STAGE" != initial ]; then
  wait_file "$STATE/watcher-returning"
  if [ "$CONTENTION_STAGE" = poll ]; then
    wait_file "$STATE/.last-watcher-beat"
  fi
  hold_queue & holder=$!
  wait_file "$STATE/queue-held"
fi
wait_file "$STATE/.codex-watch.lock/target.json"
sleep 0.5
kill -0 "$hook"
[ "$(cat "$STATE/.codex-watch.lock/pid")" = "$hook" ]
[ "$(cat "$STATE/.wake-queue.lock/pid")" = "$holder" ]
[ ! -e "$STATE/deliveries" ]
[ ! -e "$STATE/.codex-watch-delivered" ]
if [ "$CONTENTION_RESULT" = exhausted ]; then
  if wait "$hook"; then exit 21; fi
  grep -q 'queue snapshot unavailable' "$STATE/.codex-watch-error"
  [ ! -e "$STATE/.codex-watch.lock" ]
  [ ! -e "$STATE/.codex-watch-delivered" ]
  [ ! -e "$STATE/deliveries" ]
  [ "$(cat "$STATE/.wake-queue.lock/pid")" = "$holder" ]
fi
[ "$(wc -l < "$STATE/.wake-queue")" -eq 1 ]
touch "$STATE/release-queue"
wait "$holder"
if [ "$CONTENTION_RESULT" = exhausted ]; then
  "$FM_HOME/bin/fm-codex-stop-watch.sh" <<< "$payload"
else
  wait "$hook"
fi
[ "$(wc -l < "$STATE/deliveries")" -eq 1 ]
[ "$(jq .seq "$STATE/.codex-watch-delivered")" -eq 1 ]
[ ! -e "$STATE/.codex-watch-error" ]
"$FM_HOME/bin/fm-wake-drain.sh" > "$STATE/presentation" 2>&1
awk -F '\t' 'NF >= 5 {print $5}' "$STATE/presentation" > "$STATE/handled"
[ "$(cat "$STATE/handled")" = 'done: contention event' ]
ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p' "$STATE/presentation")
[ -n "$ack" ]
(cd "$FM_HOME" && bash -c "$ack")
[ ! -s "$STATE/.wake-queue" ]
rm -f "$STATE/successor-armed"
"$FM_HOME/bin/fm-codex-stop-watch.sh" <<< "$payload" & successor=$!
wait_file "$STATE/successor-armed"
[ "$(cat "$STATE/.codex-watch.lock/pid")" = "$successor" ]
kill -0 "$successor"
touch "$STATE/release-arm"
wait "$successor"
SH
for stage in initial returned poll; do
  for result in released exhausted; do
    state="$P/contention-$stage-$result"
    mkdir -p "$state"
    FM_STATE_OVERRIDE="$state" STATE="$state" CONTENTION_STAGE="$stage" CONTENTION_RESULT="$result" \
      "$TMP_ROOT/native/codex" "$TMP_ROOT/contention-scenario"
    pass "Codex $stage snapshot contention $result preserves rows, exact ack and successor ownership"
  done
done

# A linked worker must remain inert, even if its native-shaped parent owns .lock.
git -C "$P" add AGENTS.md
git -C "$P" commit -qm fixture
git -C "$P" worktree add -q -b worker "$TMP_ROOT/worker"
mkdir -p "$TMP_ROOT/worker/bin" "$TMP_ROOT/worker/state"
cp "$P/bin/"*.sh "$TMP_ROOT/worker/bin/"
FM_HOME="$TMP_ROOT/worker" FM_ROOT_OVERRIDE="$TMP_ROOT/worker" FM_STATE_OVERRIDE="$TMP_ROOT/worker/state" \
  "$TMP_ROOT/native/codex" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; printf "%s\n" '\''{"hook_event_name":"Stop","session_id":"01a0ed98-600a-7c81-98d6-56affd853dec"}'\'' | "$FM_HOME/bin/fm-codex-stop-watch.sh"'
[ ! -e "$TMP_ROOT/worker/state/.codex-watch-delivered" ] || fail 'worker delivered a native wake'
pass 'linked child worktree remains excluded'

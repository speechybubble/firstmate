#!/usr/bin/env bash
# Scratch live driver: sources a checkout's scan-progress harness (minus its
# case calls) and drives the real bin/fm-watch.sh process for chosen scenarios.
set -u
SRC=$1; shift
harness=$(mktemp); sed '/^test_[a-z_]*$/d' "$SRC/tests/fm-watch-scan-progress.test.sh" > "$harness"
cp "$harness" "$SRC/tests/.nm-drive-harness.sh"; rm -f "$harness"
. "$SRC/tests/.nm-drive-harness.sh"
rm -f "$SRC/tests/.nm-drive-harness.sh"

patch_capture() {  # fakebin: capture prints FM_FAKE_CAPTURE_FILE when set
  sed -i 's|^  display-message) printf .\\n.; exit 0 ;;|  display-message) case "$*" in *cursor_y*) printf "1\\n"; exit 0 ;; esac; printf "\\n"; exit 0 ;;|' "$1/tmux"
  sed -i 's|^    if \[ -n "${FM_FAKE_TMUX_CAPTURE_VARY:-}" \]; then|    if [ -n "${FM_FAKE_CAPTURE_FILE:-}" ]; then cat "$FM_FAKE_CAPTURE_FILE"\n    elif [ -n "${FM_FAKE_TMUX_CAPTURE_VARY:-}" ]; then|' "$1/tmux"
}
due() { local r; r=$(FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_task_inbox_write "$2" "$3" "please continue"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1" "$2"); touch -t 202001010000 "$r"; printf '%s\n' "$r"; }
wait_sent() { local i=0; while [ $i -lt "$2" ] && ! grep -q "$3" "$1" 2>/dev/null; do sleep 0.1; i=$((i+1)); done; }

case_ownership() {
  local dir state fakebin out log slog
  dir=$(make_case own); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; log="$dir/crew.log"; slog="$dir/send.log"
  install_scan_fakes "$fakebin"
  for i in 1 2 3; do add_window "$state" "slow$i" "working: part $i"; done
  add_window "$state" zlate "working: review"
  # 'xshared' records slow1's window; 'nowin' has a meta but no window.
  printf 'window=test:fm-slow1\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/xshared.meta"
  printf 'kind=ship\nharness=grok\nbackend=tmux\n' > "$state/nowin.meta"
  due "$state" xshared >/dev/null; due "$state" nowin >/dev/null; due "$state" zlate >/dev/null
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" FM_FAKE_CREW_STATE_SLEEP=3 \
    FM_FAKE_TMUX_SEND_LOG="$slog" FM_FAKE_TMUX_WINDOWS="$(windows_of "$state" | sed 's/^test://')" FM_TASK_INBOX_RING_MAX=99
  wait_sent "$slog" 150 'zlate.inbox'
  sleep 15   # let the full walk of every window finish
  echo "--- send log (typed doorbells) ---"; cat "$slog" 2>/dev/null
  echo "--- scan reads ---"; cat "$log" 2>/dev/null
  echo "--- ring-state files ---"; ls -la "$state"/*.inbox/.ring-state 2>&1
  echo "--- wake queue ---"; cat "$state/.wake-queue" 2>/dev/null; echo "--- watch.out ---"; cat "$out"
  is_live_non_zombie "$WATCHER_PID" && echo "watcher alive"; reap_watcher
  grep -q "zlate.inbox" "$slog" && ! grep -q "xshared.inbox\|nowin.inbox" "$slog" \
    && [ ! -e "$state/xshared.inbox/.ring-state" ] && [ ! -e "$state/nowin.inbox/.ring-state" ] \
    && echo "RESULT ownership: PASS" || echo "RESULT ownership: FAIL"
}

case_defer() {  # busy|composer
  local kind=$1 dir state fakebin out log slog cap reads
  dir=$(make_case "$kind"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; log="$dir/crew.log"; slog="$dir/send.log"
  install_scan_fakes "$fakebin"; patch_capture "$fakebin"; cap="$dir/capture"
  if [ "$kind" = busy ]; then printf 'BUSYTOKEN esc to interrupt\n> \n' > "$cap"
  else printf '╭──────────────────╮\n│ captain draft    │\n╰──────────────────╯\n' > "$cap"; fi
  for i in 1 2 3 4; do add_window "$state" "slow$i" "working: part $i"; done
  add_window "$state" zlate "working: review"
  due "$state" zlate >/dev/null
  start_watcher "$state" "$fakebin" "$out" FM_FAKE_CREW_STATE_LOG="$log" FM_FAKE_CREW_STATE_SLEEP=3 \
    FM_FAKE_TMUX_SEND_LOG="$slog" FM_FAKE_TMUX_WINDOWS="$(windows_of "$state" | sed 's/^test://')" \
    FM_TASK_INBOX_RING_MAX=99 FM_TASK_INBOX_BUSY_MAX=99 FM_BUSY_REGEX=BUSYTOKEN FM_FAKE_CAPTURE_FILE="$cap"
  local f=ring-state; [ "$kind" = busy ] && f=busy-state
  local i=0; while [ $i -lt 150 ] && [ ! -s "$state/zlate.inbox/.$f" ]; do sleep 0.1; i=$((i+1)); done
  reads=$(line_count "$log")
  echo "--- .$f after $reads of 4 slow scan reads ---"; cat "$state/zlate.inbox/.$f" 2>&1
  sleep 3
  echo "--- send log ---"; cat "$slog" 2>/dev/null; echo "(end)"; echo "--- wake queue ---"; cat "$state/.wake-queue" 2>/dev/null; echo "(end)"
  reap_watcher
  [ -s "$state/zlate.inbox/.$f" ] && [ ! -s "$slog" ] && [ "$reads" -lt 4 ] && echo "RESULT $kind: PASS" || echo "RESULT $kind: FAIL"
}

case_late() { test_due_doorbell_late_in_scan_rings_within_the_cycle; }

for c in "$@"; do echo "===== $c ====="; case $c in defer_*) case_defer "${c#defer_}" ;; *) "case_$c" ;; esac; done

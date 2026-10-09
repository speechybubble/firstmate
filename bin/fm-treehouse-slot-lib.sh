#!/usr/bin/env bash
# Read-only Treehouse slot-claim readers, shared by observation and wake/teardown.
# The writer remains in fm-wake-lib.sh; absence is unverified legacy ownership.

fm_treehouse_slot_owner_marker() {  # <worktree>
  local worktree=$1 slot
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  printf '%s/.fm-slot-owner\n' "$(dirname "$slot")"
}


# Read the claim on a pool slot and compare it with a task id.
# Sets FM_TREEHOUSE_SLOT_OWNER to one of:
#   mine   - the claim names this task
#   other  - the claim names a different task, so the slot was reassigned
#   absent - no claim: the slot was taken before claims existed, or returned since
#   unsafe - a claim file exists but cannot be read as a claim
# FM_TREEHOUSE_SLOT_OWNER_ID and FM_TREEHOUSE_SLOT_OWNER_HOME carry the recorded
# claimant as evidence. The home is reported, never matched: a home that moved
# must not turn a task's own slot into a refusal.
fm_treehouse_slot_owner_state() {  # <worktree> <task-id>
  local worktree=$1 id=$2 marker line owner_id='' owner_home='' task_count=0 home_count=0
  FM_TREEHOUSE_SLOT_OWNER=unsafe
  FM_TREEHOUSE_SLOT_OWNER_ID=
  FM_TREEHOUSE_SLOT_OWNER_HOME=
  marker=$(fm_treehouse_slot_owner_marker "$worktree") || return 0
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    FM_TREEHOUSE_SLOT_OWNER=absent
    return 0
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      task=*) owner_id=${line#task=}; task_count=$((task_count + 1)) ;;
      home=*) owner_home=${line#home=}; home_count=$((home_count + 1)) ;;
    esac
  done < "$marker" || return 0
  [ "$task_count" -eq 1 ] && [ "$home_count" -le 1 ] && [ -n "$owner_id" ] || return 0
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_OWNER_ID=$owner_id
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_OWNER_HOME=$owner_home
  if [ "$owner_id" = "$id" ]; then
    FM_TREEHOUSE_SLOT_OWNER=mine
  else
    # shellcheck disable=SC2034 # Output global consumed by the sourcing caller.
    FM_TREEHOUSE_SLOT_OWNER=other
  fi
}


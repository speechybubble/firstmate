#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables,
# and two named exceptions to that purity - fm_control_endpoint_absence_verdict,
# the single owner of the per-backend endpoint-absence proof, which does run
# backend reads, and the fm_control_claude_session_* checks, which read Claude's
# own session records before an exact-session resume. Everything else has no
# side effects, runs no backend command,
# and reads no state, so sourcing this file is still free and the tables can be
# read by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb: it is not deterministic across the
# verified adapters (docs/agent-control.md owns the per-adapter resume facts).
# `relaunch` uses the brief on disk rather than a harness-private session as
# its durable instruction. The relaunch-time exception is
# fm_control_relaunch_resume_flag below: a reference the endpoint's runtime
# bound as its status authority is returned to a replacement with that adapter,
# and a Claude session id the caller supplied is resumed only after
# fm_control_claude_session_verify proved it.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harnesses() {
  printf '%s\n' claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin
}

fm_control_harness_supported() {  # <harness>
  local harness found=1
  while read -r harness; do
    [ "$harness" = "${1-}" ] && found=0
  done < <(fm_control_harnesses)
  return "$found"
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# `omp` is exact because an `omp*` prefix would claim unrelated commands, `agy`
# is exact for the same reason on an even shorter name, and an
# unrecognized value returns nonzero rather than being guessed into a family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    agy) printf 'agy' ;;
    devin) printf 'devin' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    gemini*) printf 'gemini' ;;
    muse*) printf 'muse' ;;
    rovo*) printf 'rovo' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse, gemini, rovo, agy, and devin
# are crewmate/scout adapters only: none has a primary supervision protocol,
# and bin/fm-spawn.sh refuses a --secondmate launch on any of them. The control
# plane asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|gemini|rovo|agy|devin) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
# gemini names its own key in the running turn's status row
# (`(esc to cancel, <n>s)`), and a single Escape was verified to cancel it.
# rovo cancels on a single Escape too, printing "Agent cancelled" (verified,
# 202609.1.2). agy cancels on a single Escape, printing the Interrupted row
# with an idle composer and no repollution (verified live, agy 1.2.0 through
# Herdr). omp (Oh My Pi) shares Pi's single Escape, empty composer
# afterwards, and /quit exit (verified omp 18.1.2 in a PTY, re-verified 18.1.11
# through Herdr).
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse|rovo|agy|devin) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode and Devin need a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode|devin) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) printf '1' ;;
    *) return 1 ;;
  esac
}

# The rendered proof, read from the visible viewport between presses, that the
# first interrupt press landed on a RUNNING turn; empty when the adapter sends
# its presses blind. Devin needs it because the same fast double Escape that
# cancels a running turn opens its /revert "Revert to step" picker on an idle
# agent, where a later Enter reverts file changes. One Escape on a running turn
# renders `esc again to interrupt` for about three seconds, while an idle agent
# renders nothing, so the second press is sent only after that proof and never
# sooner than fm_control_interrupt_press_gap: an unproven arm sends nothing
# more. Verified live on devin 3000.11.1: an idle pair opened the picker at a
# 0.05-0.1 s gap and did not at 0.15 s or more, and a running turn cancelled
# with a 0.6 s gap.
fm_control_interrupt_arm_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'esc again to interrupt' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) ;;
    *) return 1 ;;
  esac
}

# The minimum seconds between two presses of an armed interrupt: several times
# Devin's observed idle double-tap window, well inside its three-second armed
# window. A turn that ends between the presses therefore cannot pair them.
fm_control_interrupt_press_gap() {  # <harness>
  case "${1-}" in
    devin) printf '0.5' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) printf '0.2' ;;
    *) return 1 ;;
  esac
}

# A rendered surface that a mistimed interrupt press can open and that must be
# dismissed with one more interrupt key before anything else is typed; empty
# when the adapter has none. Devin's revert picker is recognized by either of
# two independent rows, its `Revert to step:` title or its `↵ revert` footer,
# and Escape cancels it without reverting (verified live, devin 3000.11.1).
fm_control_interrupt_hazard_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'Revert to step:|↵ revert' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. gemini was checked the
# same way and also does not repollute: after a single Escape it prints
# `Request cancelled.` and its composer shows only the `Type your message
# or @path/to/file` placeholder. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin) ;;
    *) return 1 ;;
  esac
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    # rovo's TUI prints "Agent cancelled" on Escape, but for parity with
    # claude/cursor this stays 'none': the ack is a rendered string, not a
    # recorded state source, and rovo has no busy wiring to confirm against.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse|rovo) printf '/exit' ;;
    codex|pi|pi-signed|omp|gemini|agy|devin) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# The launch argument that makes a RELAUNCH of <harness> RESUME an exact agent
# session instead of starting a fresh one, printed only when <registered-agent>
# is the label that session reference belongs to; nothing otherwise.
#
# This exists for one runtime failure, not as a general resume feature. Herdr
# gives a pane one status authority, and for Pi with its installed integration
# that authority is the lifecycle hooks, which also suppress Herdr's screen
# detection for the pane. That registration outlives its agent process in the
# crew shape - a nested worktree shell under the pane's top shell - and Herdr
# then applies only reports carrying the session identity it bound. A
# replacement agent started fresh in that same pane reports a NEW session, so
# its state reports are ignored and the pane stays frozen at whatever the
# previous agent last reported: a working crewmate reads idle until its task
# ends (reproduced and fixed live 2026-09-21, herdr 0.9.1; the read that
# supplies the reference is
# bin/backends/herdr.sh's fm_backend_herdr_pane_agent_session_ref).
#
# So the reference is not chosen from what looks recent - it is the exact
# identity the endpoint's own runtime recorded, which is why a matched
# registered-agent label is required: resuming a reference reported by a
# DIFFERENT agent would inject another agent's conversation into this launch.
# `pi` is the label Pi and pi-signed both report, so one entry covers both.
# Every other harness returns nothing and keeps today's fresh-session
# relaunch, which is what the adapter tables above (and the absence of a
# verified resume form for those harnesses) require.
#
# Claude is the one adapter resumed from a CALLER-SUPPLIED reference rather than
# a pane registration: its flag is returned only for the literal source
# `--verified-session`, which bin/fm-spawn.sh passes solely after
# fm_control_claude_session_verify below proved that exact session. A
# registered-agent label never selects it, so an ordinary Claude relaunch stays
# a fresh session.
#
# Prints the flag name only; the caller quotes and appends the reference, since
# shell quoting belongs to the owner of the launch line (bin/fm-spawn.sh).
fm_control_relaunch_resume_flag() {  # <harness> <registered-agent|--verified-session>
  case "${1-}" in
    pi|pi-signed)
      [ "${2-}" = pi ] && printf -- '--session'
      ;;
    claude)
      [ "${2-}" = --verified-session ] && printf -- '--resume'
      ;;
  esac
  return 0
}

# --- Claude exact-session resume (relaunch-only) ----------------------------
#
# A required restart of a Claude agent may have to keep its conversation, which
# the brief on disk cannot reproduce. `fm-control.sh <id> relaunch
# --resume-session <uuid>` carries one exact Claude session id into
# `fm-spawn.sh --relaunch`, and these functions are the single owner of what
# makes that id safe to resume. They are the second named exception to this
# file's purity: they read Claude's own per-process session records and
# transcript store, and nothing else.
#
# Claude Code keeps one record per running interactive process at
# <config-dir>/sessions/<pid>.json ({"pid", "sessionId", "cwd", "procStart",
# ...}; procStart is /proc/<pid>/stat field 22) and the conversation at
# <config-dir>/projects/<cwd with every non-alphanumeric byte as '-'>/<id>.jsonl,
# where <config-dir> is $CLAUDE_CONFIG_DIR or ~/.claude (verified Claude Code
# 2.1.296). The check runs twice:
#   owned     before the old agent is touched: exactly one live record names
#             the id, that record's cwd is the task's working directory, the
#             transcript exists there, and the recording process is THIS
#             task's agent (fm_control_claude_session_owner_bound below). A
#             missing, mismatched, or foreign-owned id refuses while nothing
#             has changed.
#   released  after the old agent is proven stopped, immediately before the
#             launch: no live record names the id any more, so the replacement
#             can never become a second process on one conversation, and the
#             transcript is still there.
# Nothing here ever chooses an id (no newest-file guess, no --continue, no
# --fork-session), and a refusal never degrades to a fresh session.

fm_control_claude_session_id_valid() {  # <session-id>
  [[ "${1-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# The Claude store a launch under <worker-account-selection> uses: the pinned
# root, ~/.claude for a pin naming the ordinary account (which unsets
# CLAUDE_CONFIG_DIR), and otherwise the forwarded $CLAUDE_CONFIG_DIR or
# ~/.claude. <worker-account-selection> is fm_worker_account_select's output.
fm_control_claude_config_dir() {  # [<worker-account-selection>]
  local selection=${1-} root
  if [ -n "$selection" ]; then
    root=${selection#*$'\t'}
    root=${root%%$'\t'*}
    printf '%s' "${root:-${HOME:-}/.claude}"
    return 0
  fi
  printf '%s' "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
}

# Whether the process a session record names is still running: the pid answers,
# and where /proc exposes it, the process is not an exited zombie and its start
# time still equals the record's procStart, so a reused pid is not mistaken for
# the recorded process.
fm_control_claude_session_pid_live() {  # <pid> [<procStart>]
  local pid=${1-} start=${2-} proc_root stat_line
  local -a fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  kill -0 "$pid" 2>/dev/null || [ -d "$proc_root/$pid" ] || return 1
  stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 0
  read -r -a fields <<<"${stat_line##*) }"
  [ "${fields[0]-}" != Z ] || return 1
  [ -n "$start" ] || return 0
  [ "${fields[19]-}" = "$start" ]
}

# One "<pid>\t<cwd>" line per LIVE session record naming <session-id>. Returns
# 2 when the store cannot be read reliably: jq is missing, or a record that
# mentions the id cannot be parsed, which could otherwise hide an owner.
fm_control_claude_session_live_owners() {  # <config-dir> <session-id>
  local dir=${1-}/sessions id=${2-} record row pid cwd start
  command -v jq >/dev/null 2>&1 || return 2
  [ -d "$dir" ] || return 0
  for record in "$dir"/*.json; do
    [ -f "$record" ] || continue
    if ! row=$(jq -r --arg id "$id" \
        'select(.sessionId == $id) | [(.pid // "" | tostring), (.cwd // ""), (.procStart // "" | tostring)] | @tsv' \
        "$record" 2>/dev/null); then
      grep -qF -- "$id" "$record" 2>/dev/null && return 2
      continue
    fi
    [ -n "$row" ] || continue
    IFS=$'\t' read -r pid cwd start <<<"$row"
    [ -n "$pid" ] || pid=$(basename "$record" .json)
    fm_control_claude_session_pid_live "$pid" "$start" || continue
    printf '%s\t%s\n' "$pid" "$cwd"
  done
  return 0
}

# Canonical form of a path whose last component may not exist yet.
fm_control_claude_path_real() {  # <path>
  local dir
  dir=$(cd "$(dirname -- "${1-}")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$dir" "$(basename -- "$1")"
}

# Whether <pid> is <ancestor> or one of its descendants in the process table.
fm_control_claude_pid_descends_from() {  # <pid> <ancestor>
  local pid=${1-} ancestor=${2-} hops=0
  case "$ancestor" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$hops" -lt 64 ]; do
    case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
    [ "$pid" != "$ancestor" ] || return 0
    [ "$pid" != 1 ] || return 1
    pid=$(LC_ALL=C ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
    hops=$((hops + 1))
  done
  return 1
}

# Whether the live process <owner-pid> that records the session is THIS task's
# agent, read from its own environment (<proc-root>/<pid>/environ):
#   - FM_TASK_INBOX present: it must name this task's inbox, the export every
#     Fleet launch carries (bin/fm-spawn.sh).
#   - FM_TASK_INBOX absent (an agent launched before that export existed): the
#     owner must sit in the process tree of the task's recorded endpoint
#     (<endpoint-root-pid>, from fm_backend_pane_root_pid), its FM_HOME must be
#     <task-home>, and a worker's FM_TASK_ID, where present, must be the task id.
# An unreadable environment proves nothing and refuses, so on a platform
# without /proc an exact-session resume always refuses before the stop.
fm_control_claude_session_owner_bound() {  # <owner-pid> <task-id> <kind> <task-inbox> <task-home> <endpoint-root-pid>
  local pid=${1-} task=${2-} kind=${3-} inbox=${4-} home=${5-} root=${6-} environ value home_real
  environ=$(tr '\0' '\n' 2>/dev/null < "${FM_PROC_ROOT_OVERRIDE:-/proc}/$pid/environ") || environ=
  [ -n "$environ" ] || {
    echo "error: the environment of live Claude process $pid cannot be read, so it cannot be proven to be task $task's agent" >&2
    return 1
  }
  if printf '%s\n' "$environ" | grep -q '^FM_TASK_INBOX='; then
    value=$(printf '%s\n' "$environ" | sed -n 's/^FM_TASK_INBOX=//p' | tail -n 1)
    if [ -z "$inbox" ] || [ "$(fm_control_claude_path_real "$value")" != "$(fm_control_claude_path_real "$inbox")" ]; then
      echo "error: live Claude process $pid belongs to the task whose inbox is '$value', not task $task (inbox $inbox)" >&2
      return 1
    fi
    return 0
  fi
  fm_control_claude_pid_descends_from "$pid" "$root" || {
    echo "error: live Claude process $pid carries no FM_TASK_INBOX and is not in task $task's endpoint process tree (root pid ${root:-unreadable}), so it is not task $task's agent" >&2
    return 1
  }
  value=$(printf '%s\n' "$environ" | sed -n 's/^FM_HOME=//p' | tail -n 1)
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || home_real=
  if [ -z "$value" ] || [ -z "$home_real" ] || [ "$(cd "$value" 2>/dev/null && pwd -P)" != "$home_real" ]; then
    echo "error: live Claude process $pid runs with FM_HOME '${value:-unset}', not task $task's home $home, so it is not task $task's agent" >&2
    return 1
  fi
  if [ "$kind" != secondmate ] && printf '%s\n' "$environ" | grep -q '^FM_TASK_ID='; then
    value=$(printf '%s\n' "$environ" | sed -n 's/^FM_TASK_ID=//p' | tail -n 1)
    [ "$value" = "$task" ] || {
      echo "error: live Claude process $pid is marked FM_TASK_ID='$value', not task $task" >&2
      return 1
    }
  fi
  return 0
}

# The refusal-or-success gate described above. Prints the reason on stderr and
# returns nonzero on any refusal. The owned phase also takes the task binding
# fm_control_claude_session_owner_bound checks.
fm_control_claude_session_verify() {  # <owned|released> <config-dir> <session-id> <cwd> [<task-id> <kind> <task-inbox> <task-home> <endpoint-root-pid>]
  local phase=${1-} config=${2-} id=${3-} cwd=${4-} cwd_real owners rc owner_count owner_pid owner_cwd owner_real transcript
  fm_control_claude_session_id_valid "$id" || {
    echo "error: '$id' is not a well-formed Claude session id (lowercase 8-4-4-4-12 hex); refusing to resume" >&2
    return 1
  }
  [ -n "$config" ] || { echo "error: no Claude config directory could be resolved; refusing to resume session $id" >&2; return 1; }
  cwd_real=$(cd "$cwd" 2>/dev/null && pwd -P) || {
    echo "error: working directory '$cwd' cannot be resolved; refusing to resume session $id" >&2
    return 1
  }
  transcript="$config/projects/$(printf '%s' "$cwd_real" | sed 's/[^A-Za-z0-9]/-/g')/$id.jsonl"
  if [ ! -f "$transcript" ] || [ -L "$transcript" ] || [ ! -s "$transcript" ]; then
    echo "error: Claude session $id has no transcript at $transcript, so it is not a conversation of $cwd_real; refusing to resume" >&2
    return 1
  fi
  rc=0
  owners=$(fm_control_claude_session_live_owners "$config" "$id") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: Claude's session records under $config/sessions cannot be read reliably (jq missing or a record naming $id is unreadable), so ownership of session $id cannot be proven; refusing to resume" >&2
    return 1
  fi
  owner_count=0
  [ -z "$owners" ] || owner_count=$(printf '%s\n' "$owners" | wc -l | tr -d ' ')
  case "$phase" in
    owned)
      if [ "$owner_count" -eq 0 ]; then
        echo "error: no live Claude process records session $id under $config/sessions, so it cannot be proven to be this task's running conversation; refusing before anything is stopped" >&2
        return 1
      fi
      if [ "$owner_count" -gt 1 ]; then
        echo "error: Claude session $id is owned by more than one live process ($(printf '%s\n' "$owners" | cut -f1 | tr '\n' ' ')); refusing before anything is stopped" >&2
        return 1
      fi
      IFS=$'\t' read -r owner_pid owner_cwd <<<"$owners"
      owner_real=$(cd "$owner_cwd" 2>/dev/null && pwd -P) || owner_real=$owner_cwd
      [ "$owner_real" = "$cwd_real" ] || {
        echo "error: Claude session $id belongs to live process $owner_pid in '$owner_cwd', not to this task's working directory $cwd_real; refusing before anything is stopped" >&2
        return 1
      }
      fm_control_claude_session_owner_bound "$owner_pid" "${5-}" "${6-}" "${7-}" "${8-}" "${9-}" || {
        echo "error: Claude session $id is not owned by this task's agent; refusing before anything is stopped" >&2
        return 1
      }
      ;;
    released)
      [ "$owner_count" -eq 0 ] || {
        echo "error: Claude session $id is still owned by live process(es) $(printf '%s\n' "$owners" | cut -f1 | tr '\n' ' ')- resuming it would put a second process on one conversation; refusing to launch" >&2
        return 1
      }
      ;;
    *)
      echo "error: internal: unknown Claude session check phase '$phase'" >&2
      return 1
      ;;
  esac
  return 0
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# fm_control_endpoint_absence_verdict: the ONE owner of the per-backend proof
# that an endpoint reading `missing` is actually GONE rather than merely
# unreachable from this seat. Call it only for a `missing` raw state.
#
# Prints "<verdict>\t<reason>" - always exactly one TAB, so a caller splits
# unambiguously with ${raw%%$'\t'*} and ${raw#*$'\t'}. The reason is empty
# except on `unproven`, where it is the concrete sentence the caller's refusal
# message embeds. It is returned on stdout rather than set in a variable
# because every caller reads this through a command substitution, where an
# assignment made here could never reach them.
#
# The verdicts:
#   gone     - absence is PROVEN. There is no endpoint and therefore no agent.
#   dead     - the endpoint is there after all and holds no agent.
#   alive    - the endpoint is there and an agent is running in it.
#   unproven - neither could be established; the caller must refuse.
#
# fm_backend_agent_state's `missing` conflates "the endpoint was DESTROYED"
# with "the endpoint is UNREACHABLE from here right now". An unreachable
# endpoint can still hold a live agent on the task's worktree, so every caller
# that would act on absence - `exit` claiming the agent stopped, `relaunch`
# re-creating the endpoint - must come through here rather than trusting the
# raw verdict.
#
# Whether absence is provable AT ALL is a property of the backend, not of the
# reading:
#   herdr CAN prove it. Every read goes through fm_backend_herdr_cli, which
#     passes `--session <session>`, so the recheck starts and reads the session
#     the RECORD names, through that session's own socket. The answer is about
#     the task's endpoint and nothing else.
#   tmux CANNOT. `list-windows -a` describes only the server the CURRENT
#     process addresses (its TMUX_TMPDIR/socket), and a task's record does not
#     carry the endpoint's socket identity - so a different but running server
#     would answer "not anywhere" about a window it was never able to see.
#     There is no read available here that closes that gap, so tmux always
#     returns `unproven` and both verbs refuse. tmux is left exactly as
#     deadlocked as it was before this change - no worse - but deliberately.
#
# Both control-plane callers share this one implementation so the proof cannot
# drift into two answers for the same endpoint.
fm_control_endpoint_absence_verdict() {  # <backend> <target>
  local backend=${1-} target=${2-}
  fm_backend_source "$backend" \
    || { printf 'unproven\tbackend %s could not be loaded to prove anything about that endpoint' "'$backend'"; return 0; }
  case "$backend" in
    tmux)
      printf 'unproven\ttmux absence cannot be proven from a task record: the record does not carry the endpoint'"'"'s socket identity, and a server-wide window inventory only describes the tmux server this process addresses, so a window absent from it may still be alive on another'
      ;;
    herdr)
      # Start the RECORDED session's server (only the server - nothing is
      # created) and re-read the recorded pane. A pane that comes back with the
      # server was never destroyed.
      case "$(fm_backend_herdr_endpoint_absence_recheck "$target")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing) printf 'gone\t' ;;
        *) printf 'unproven\tthe recorded herdr session'"'"'s server could not be started, or its pane could not be classified once it was running' ;;
      esac
      ;;
    *)
      printf 'unproven\tbackend %s has no recovery-grade classifier, so absence cannot be proven on it at all' "'$backend'"
      ;;
  esac
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # gemini's busy-state and turn-end hooks live in a firstmate-owned
    # settings file the launch reaches through GEMINI_CLI_SYSTEM_SETTINGS_PATH,
    # so retiring that one file retires the whole incarnation's wiring. Nothing
    # is written into the worktree, whose own .gemini/settings.json belongs to
    # the project, and nothing global is installed.
    gemini) printf '%s\n' "$state/$id.gemini-settings.json" ;;
    devin) printf '%s\n' "$state/$id.devin-config.json" ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}

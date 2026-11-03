#!/usr/bin/env bash
# fm-run-budget.sh - the spend line and stop rule for a long scout run.
#
# A long scout declares a run budget at intake (bin/fm-brief.sh --scout
# --run-budget <spec>). This script is the single owner of what that budget
# means: the spec format, the brief section it renders, the run ledger, the
# stop verdicts, and the run-status line at the top of the report. It exists
# because a run that only stops when its allowance runs out leaves nothing
# behind; under a budget the report exists from the run's first minute, every
# finding lands in it as the run goes, and every stop leaves it marked.
#
# Usage:
#   fm-run-budget.sh render <spec> <task-dir>
#   fm-run-budget.sh start <task-dir>
#   fm-run-budget.sh finding <task-dir> <one-line finding>
#   fm-run-budget.sh wait <task-dir> <what the run is waiting on>
#   fm-run-budget.sh resume <task-dir>
#   fm-run-budget.sh check <task-dir>
#   fm-run-budget.sh finish <task-dir> <complete|time|spend|reserve|plateau> [<note>]
#   fm-run-budget.sh salvage <task-dir> [<why>]
#   fm-run-budget.sh status <task-dir>...
#
# <task-dir> is the task's data folder (<home>/data/<task-id>). It holds the
# brief (brief.md), the report (report.md), and the run ledger this script
# writes (run-budget.tsv). The task id is the folder's name.
#
# SPEC is a comma-separated list of key=value pairs:
#   minutes=<N>      wall-clock minutes the run may take, counted from its
#                    first start (a relaunch does not reset it).
#   allowance=<p>    the quota-axi provider whose all_models allowance the run
#                    spends, read with `quota-axi --json --provider <p>
#                    --no-credential-refresh --max-age 120s` (read-only),
#                    bounded to 30 seconds. Firstmate names it at intake; it is
#                    never inferred from the worker's harness or model.
#   spend=<points>   percentage points of that allowance the run may use,
#                    measured as the drop in its remaining percentage since the
#                    start. Anything else spending the same allowance counts
#                    too, so it bounds the run's spend from above.
#   reserve=<points> stop when the allowance's remaining percentage reaches
#                    this floor (default 5 when allowance is set), so the run
#                    stops and writes before the allowance is gone.
#   plateau=<N>      stop after N minutes of work add no new finding (default
#                    60). Declared waits do not count as work, and a relaunch
#                    starts a fresh plateau window.
# A spec needs minutes or spend; spend and reserve need allowance. Values are
# positive integers, and reserve is under 100.
#
# render validates the spec and prints the brief's `# Run budget` section: the
# marker line `<!-- fm-run-budget: <normalized spec> -->` that the other
# subcommands read from <task-dir>/brief.md, and the worker instructions with
# absolute command lines. Exit 2 on an invalid spec.
#
# start records the run's start in the ledger, reads the allowance's headroom,
# and prints a plan:
#   plan: full    the budget fits the allowance as read.
#   plan: short   the allowance's headroom above the reserve is smaller than
#                 the spend line, or its projected runway is shorter than the
#                 time budget; the effective limit shrinks to fit and the run
#                 should cover what matters most first.
#   stop: reserve the allowance is already at or under the reserve; the report
#                 is marked stopped and the command exits 3.
# An allowance quota-axi cannot read (absent, stale, unknown headroom) is
# disclosed in the plan and leaves only the time and plateau rules in force
# until a later check can read it; the first check that reads it records that
# reading as the spend baseline. start writes the report's first checkpoint:
# it creates report.md with the run-status line and a `## Run log` section
# when the report is absent, or marks an existing one in progress when it has
# no status line or a launcher's not-started status. A
# second start, after a relaunch, keeps the first start's clock and plan and
# records a restart.
#
# finding appends a timestamped finding to the ledger and to the report's
# `## Run log` section (recreated at the end of the report when missing), so a
# finding survives a run that dies before its next write. wait and resume
# bracket a long wait on the run's own background job; the plateau clock skips
# that interval.
#
# check prints one verdict line and exits 0 for `continue:` and `wrap-up:`
# (85 percent of the time or spend line is used: write the final report now)
# and 3 for `stop: <reason>: <detail>`, where reason is reserve, spend, time,
# or plateau, tested in that order. A stop verdict records itself in the
# ledger and marks the report's status line stopped at once, before the worker
# writes anything more. finish sets the final status line (complete, or the
# stop reason) with an optional note naming what the run did not reach.
#
# salvage is for whoever finds a run that ended without finishing. When the
# ledger records no finish and the report is in progress, missing, or has lost
# its status line, the report becomes "ended without finishing" with the time
# of the run's last recorded activity, and a report without its run log gets
# the ledger's findings back. A run that recorded a finish, a report already
# marked stopped, and a report a run without a ledger wrote are left alone. A
# task folder with neither a ledger nor a report gets a report saying the run
# did not run, so a launcher can leave a record for a run it could not start.
# bin/fm-teardown.sh calls it for a budgeted scout. It needs no budget
# declaration.
#
# status prints `<task-id><TAB><state>` per folder, where state is the run
# status token (in-progress, complete, stopped-time, stopped-spend,
# stopped-reserve, stopped-plateau, ended-unfinished, not-started), no-status
# for a report without the line, or missing when there is no report.
#
# The report's run-status line is two lines this script owns, at the top of
# the report:
#   <!-- fm-run-budget: run-status=<state> -->
#   Run status: <plain sentence>
# The worker owns the rest of the report. The ledger is tab-separated
# `<epoch><TAB><event><TAB><detail>`, append-only, with the events start,
# restart, baseline, finding, wait, resume, stop, finish, and salvage; a start
# detail is space-separated key=value fields, and a baseline detail is the
# allowance percent the spend line counts from when start could not read it.
#
# FM_RUN_BUDGET_NOW=<epoch> replaces the clock, for tests.
# Exit: 0 success (continue and wrap-up included), 3 stop, 2 usage or invalid
# spec, 1 any other failure.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

MARKER_PREFIX='<!-- fm-run-budget: '
STATUS_PREFIX='<!-- fm-run-budget: run-status='
WRAP_UP_PERCENT=85
QUOTA_TIMEOUT=30

usage() {
  sed -n '/^# Usage:/,/^# <task-dir> is/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 0
}

die() { echo "fm-run-budget: $*" >&2; exit 1; }

now_epoch() {
  case "${FM_RUN_BUDGET_NOW:-}" in
    ''|*[!0-9]*) date -u +%s ;;
    *) printf '%s\n' "$FM_RUN_BUDGET_NOW" ;;
  esac
}

iso() {
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$1"
}

one_line() { printf '%s' "$1" | tr '\t\n\r' '   ' | sed 's/^ *//; s/ *$//'; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---- spec -------------------------------------------------------------------

S_MINUTES='' S_ALLOWANCE='' S_SPEND='' S_RESERVE='' S_PLATEAU='' SPEC_ERR=''

# Parse and validate <spec> into the S_* values, applying defaults. Sets
# SPEC_ERR and returns 1 when the spec is invalid.
parse_spec() {  # <spec>
  local spec=$1 pair key value rest
  S_MINUTES='' S_ALLOWANCE='' S_SPEND='' S_RESERVE='' S_PLATEAU='' SPEC_ERR=''
  [ -n "$spec" ] || { SPEC_ERR="empty run budget; give minutes=<N> or allowance=<provider>,spend=<points>"; return 1; }
  rest=$spec
  while [ -n "$rest" ]; do
    pair=${rest%%,*}
    if [ "$pair" = "$rest" ]; then rest=; else rest=${rest#*,}; fi
    case "$pair" in
      *=*) key=${pair%%=*}; value=${pair#*=} ;;
      *) SPEC_ERR="run budget entry '$pair' is not key=value"; return 1 ;;
    esac
    case "$key" in
      minutes|spend|reserve|plateau)
        is_uint "$value" && [ "$value" -gt 0 ] 2>/dev/null || {
          SPEC_ERR="run budget $key must be a positive whole number (got '$value')"; return 1; }
        value=$((10#$value)) ;;
      allowance)
        printf '%s\n' "$value" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || {
          SPEC_ERR="run budget allowance must be a quota-axi provider id (got '$value')"; return 1; } ;;
      *) SPEC_ERR="unknown run budget key '$key' (known: minutes, allowance, spend, reserve, plateau)"; return 1 ;;
    esac
    case "$key" in
      minutes) [ -z "$S_MINUTES" ] || { SPEC_ERR="run budget repeats minutes"; return 1; }; S_MINUTES=$value ;;
      allowance) [ -z "$S_ALLOWANCE" ] || { SPEC_ERR="run budget repeats allowance"; return 1; }; S_ALLOWANCE=$value ;;
      spend) [ -z "$S_SPEND" ] || { SPEC_ERR="run budget repeats spend"; return 1; }; S_SPEND=$value ;;
      reserve) [ -z "$S_RESERVE" ] || { SPEC_ERR="run budget repeats reserve"; return 1; }; S_RESERVE=$value ;;
      plateau) [ -z "$S_PLATEAU" ] || { SPEC_ERR="run budget repeats plateau"; return 1; }; S_PLATEAU=$value ;;
    esac
  done
  [ -n "$S_MINUTES" ] || [ -n "$S_SPEND" ] || { SPEC_ERR="run budget needs a spend line: minutes=<N> or spend=<points>"; return 1; }
  if [ -z "$S_ALLOWANCE" ]; then
    [ -z "$S_SPEND" ] || { SPEC_ERR="run budget spend needs allowance=<provider>"; return 1; }
    [ -z "$S_RESERVE" ] || { SPEC_ERR="run budget reserve needs allowance=<provider>"; return 1; }
  else
    [ -n "$S_RESERVE" ] || S_RESERVE=5
    [ "$S_RESERVE" -lt 100 ] || { SPEC_ERR="run budget reserve must be under 100"; return 1; }
  fi
  [ -n "$S_PLATEAU" ] || S_PLATEAU=60
  return 0
}

normalized_spec() {
  local out=
  [ -z "$S_MINUTES" ] || out="minutes=$S_MINUTES"
  [ -z "$S_ALLOWANCE" ] || out="${out:+$out,}allowance=$S_ALLOWANCE"
  [ -z "$S_SPEND" ] || out="${out:+$out,}spend=$S_SPEND"
  [ -z "$S_RESERVE" ] || out="${out:+$out,}reserve=$S_RESERVE"
  printf '%s\n' "${out:+$out,}plateau=$S_PLATEAU"
}

# Load the budget the task's brief declares, or fail.
load_brief_spec() {  # <task-dir>
  local brief="$1/brief.md" line
  [ -f "$brief" ] || die "no brief at $brief"
  line=$(fm_brief_heading_body "$brief" "# Run budget" | grep -F -- "$MARKER_PREFIX" | head -1)
  [ -n "$line" ] || die "no run budget declared in $brief (scaffold it with fm-brief.sh --scout --run-budget <spec>)"
  line=${line#"$MARKER_PREFIX"}
  line=${line%" -->"}
  parse_spec "$line" || die "invalid run budget in $brief: $SPEC_ERR"
}

# ---- ledger -----------------------------------------------------------------

ledger() { printf '%s/run-budget.tsv\n' "$1"; }

ledger_append() {  # <task-dir> <epoch> <event> [<detail>]
  printf '%s\t%s\t%s\n' "$2" "$3" "$(one_line "${4:-}")" >> "$(ledger "$1")" \
    || die "cannot append to $(ledger "$1")"
}

# The first start record's detail, or nothing.
start_detail() {  # <task-dir>
  local f
  f=$(ledger "$1")
  [ -f "$f" ] || return 0
  awk -F'\t' '$2 == "start" { print $3; exit }' "$f"
}

start_epoch() {  # <task-dir>
  local f
  f=$(ledger "$1")
  [ -f "$f" ] || return 0
  awk -F'\t' '$2 == "start" { print $1; exit }' "$f"
}

# A start detail is space-separated key=value fields whose last field, note=,
# runs to the end of the line.
detail_value() {  # <detail> <key>
  if [ "$2" = note ]; then
    case "$1" in *" note="*) printf '%s\n' "${1#* note=}" ;; esac
    return 0
  fi
  printf '%s\n' "${1%% note=*}" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }'
}

# The baseline record's allowance percent, or nothing.
baseline_pct() {  # <task-dir>
  awk -F'\t' '$2 == "baseline" { print $3; exit }' "$(ledger "$1")"
}

last_activity_epoch() {  # <task-dir>
  local f
  f=$(ledger "$1")
  [ -f "$f" ] || return 0
  awk -F'\t' '$1 ~ /^[0-9]+$/ && $2 != "salvage" { last = $1 } END { if (last != "") print last }' "$f"
}

finding_count() {  # <task-dir>
  local f
  f=$(ledger "$1")
  [ -f "$f" ] || { echo 0; return 0; }
  awk -F'\t' '$2 == "finding" { n++ } END { print n + 0 }' "$f"
}

# Seconds of work since the plateau baseline (the last finding or restart, else
# the start), not counting declared wait intervals.
plateau_active_seconds() {  # <task-dir> <now>
  awk -F'\t' -v now="$2" '
    $1 !~ /^[0-9]+$/ { next }
    { n++; ts[n] = $1; ev[n] = $2 }
    $2 == "start" && base == "" { base = $1 }
    $2 == "finding" || $2 == "restart" { base = $1 }
    END {
      if (base == "") { print 0; exit }
      waited = 0; waiting = 0
      for (i = 1; i <= n; i++) {
        if (ev[i] == "wait" && !waiting) { waiting = 1; ws = ts[i] }
        else if ((ev[i] == "resume" || ev[i] == "restart") && waiting) {
          waiting = 0
          lo = (ws > base) ? ws : base
          if (ts[i] > lo) waited += ts[i] - lo
        }
      }
      if (waiting) { lo = (ws > base) ? ws : base; if (now > lo) waited += now - lo }
      active = now - base - waited
      print (active < 0) ? 0 : active
    }' "$(ledger "$1")"
}

# ---- quota ------------------------------------------------------------------

Q_PCT='' Q_RUNWAY='' Q_WHY=''

# Read <provider>'s all_models allowance into Q_PCT (whole percent remaining)
# and Q_RUNWAY (seconds, or empty), or leave Q_PCT empty with Q_WHY set.
read_allowance() {  # <provider>
  local provider=$1 out verdict
  Q_PCT='' Q_RUNWAY='' Q_WHY=''
  if ! command -v quota-axi >/dev/null 2>&1; then
    Q_WHY="quota-axi is not installed"
    return 0
  fi
  out=$(fm_run_timed "$QUOTA_TIMEOUT" quota-axi --json --provider "$provider" --no-credential-refresh --max-age 120s 2>/dev/null) || out=
  if [ -z "$out" ]; then
    Q_WHY="quota-axi returned no reading for $provider"
    return 0
  fi
  verdict=$(printf '%s' "$out" | jq -r --arg p "$provider" "$FM_QUOTA_ROW_JQ"'
    quota_row(.; $p; "") as $row
    | if $row == null then "unknown no reading for this provider"
      elif ($row.state.stale // false) then "unknown the reading is stale"
      else ([$row.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")] | first) as $a
        | if $a == null or (($a.effectivePercentRemaining | type) != "number") then "unknown headroom is not measurable"
          else "known \($a.effectivePercentRemaining | floor) \($a.runway.usableRunwaySeconds // "" | if type == "number" then floor else "" end)"
          end
      end' 2>/dev/null) || verdict="unknown the reading could not be parsed"
  case "$verdict" in
    known\ *)
      # shellcheck disable=SC2086 # Deliberate split of "known <pct> [<runway>]".
      set -- $verdict
      Q_PCT=$2 Q_RUNWAY=${3:-}
      is_uint "$Q_PCT" || { Q_PCT=; Q_WHY="the reading could not be parsed"; }
      is_uint "$Q_RUNWAY" || Q_RUNWAY=
      ;;
    *) Q_WHY=${verdict#unknown } ;;
  esac
  return 0
}

# ---- report -----------------------------------------------------------------

report() { printf '%s/report.md\n' "$1"; }

# Replace the two-line run-status block, or insert it at the top.
set_status() {  # <task-dir> <state> <sentence>
  local file tmp
  file=$(report "$1")
  tmp="$file.run-budget.$$"
  if [ -f "$file" ] && grep -qF -- "$STATUS_PREFIX" "$file"; then
    awk -v prefix="$STATUS_PREFIX" -v marker="$STATUS_PREFIX$2 -->" -v line="Run status: $3" '
      skip { skip = 0; if (index($0, "Run status:") == 1) next }
      !done && index($0, prefix) == 1 { print marker; print line; done = 1; skip = 1; next }
      { print }' "$file" > "$tmp" || { rm -f "$tmp"; die "cannot rewrite $file"; }
  else
    {
      printf '%s\nRun status: %s\n' "$STATUS_PREFIX$2 -->" "$3"
      if [ -s "$file" ]; then printf '\n'; cat "$file"; fi
    } > "$tmp" || { rm -f "$tmp"; die "cannot write $file"; }
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; die "cannot replace $file"; }
}

report_state() {  # <task-dir>
  local file line
  file=$(report "$1")
  [ -f "$file" ] || { echo missing; return 0; }
  line=$(grep -F -m1 -- "$STATUS_PREFIX" "$file" || true)
  [ -n "$line" ] || { echo no-status; return 0; }
  line=${line#"$STATUS_PREFIX"}
  printf '%s\n' "${line%% -->*}"
}

# Append "- <time> <text>" at the end of the report's `## Run log` section,
# adding the section at the end when the report has none.
append_run_log() {  # <task-dir> <entry>
  local file tmp
  file=$(report "$1")
  tmp="$file.run-budget.$$"
  [ -f "$file" ] || : > "$file"
  awk -v entry="$2" '
    $0 == "## Run log" { insec = 1; found = 1; print; next }
    insec && /^#{1,2} / { print entry; print ""; insec = 0; placed = 1 }
    { print }
    END {
      if (insec) { print entry; placed = 1 }
      if (!found) { print ""; print "## Run log"; print "Findings the run recorded as it went, oldest first."; print ""; print entry }
    }' "$file" > "$tmp" || { rm -f "$tmp"; die "cannot rewrite $file"; }
  mv -f "$tmp" "$file" || { rm -f "$tmp"; die "cannot replace $file"; }
}

ensure_report() {  # <task-dir> <start-epoch>
  local dir=$1 file id
  file=$(report "$dir")
  id=$(basename "$dir")
  if [ ! -f "$file" ]; then
    {
      printf '%s\n' "${STATUS_PREFIX}in-progress -->"
      printf 'Run status: %s\n' "$(in_progress_sentence "$2")"
      printf '\n# %s\n\n' "$id"
      printf '## Run log\nFindings the run recorded as it went, oldest first.\n'
    } > "$file" || die "cannot write $file"
  else
    case "$(report_state "$dir")" in
      no-status|not-started) set_status "$dir" in-progress "$(in_progress_sentence "$2")" ;;
    esac
  fi
}

in_progress_sentence() {  # <start-epoch>
  printf 'in progress since %s. The run writes this report as it goes, so until this line changes it holds what the run had found at its last checkpoint.\n' "$(iso "$1")"
}

stop_sentence() {  # <reason> <task-dir> <now> [<note>]
  local reason=$1 dir=$2 now=$3 note=${4:-} detail what
  detail=$(start_detail "$dir")
  case "$reason" in
    time) what="stopped at its $(detail_value "$detail" eff_minutes)-minute time budget" ;;
    spend) what="stopped after using its $(detail_value "$detail" eff_spend)-point share of the $(detail_value "$detail" allowance) allowance" ;;
    reserve) what="stopped with the $(detail_value "$detail" allowance) allowance at its $(detail_value "$detail" reserve) percent reserve" ;;
    plateau) what="stopped after $(detail_value "$detail" plateau) minutes of work found nothing new" ;;
  esac
  printf '%s at %s. This report holds what the run found before it stopped.%s\n' "$what" "$(iso "$now")" "${note:+ $note}"
}

# ---- subcommands --------------------------------------------------------------

task_dir_arg() {  # <path>
  [ -n "${1:-}" ] || usage
  [ -d "$1" ] || die "no task folder at $1"
  (cd "$1" && pwd -P)
}

cmd_render() {
  local spec=${1:-} dir=${2:-} root cmd limits
  [ -n "$spec" ] && [ -n "$dir" ] || usage
  case "$dir" in /*) ;; *) die "render needs the task folder as an absolute path (got $dir)" ;; esac
  parse_spec "$spec" || { echo "fm-run-budget: $SPEC_ERR" >&2; exit 2; }
  root=$(cd "$SCRIPT_DIR/.." && pwd)
  cmd="'$root/bin/fm-run-budget.sh'"
  limits=
  [ -z "$S_MINUTES" ] || limits="$S_MINUTES minutes of wall-clock time"
  [ -z "$S_SPEND" ] || limits="${limits:+$limits, }$S_SPEND percentage points of the $S_ALLOWANCE allowance"
  [ -z "$S_ALLOWANCE" ] || limits="${limits:+$limits, }a stop when the $S_ALLOWANCE allowance falls to $S_RESERVE percent"
  limits="$limits, and a plateau rule: stop when $S_PLATEAU minutes of work, not counting declared waits, add no new finding"
  cat <<EOF
# Run budget
$MARKER_PREFIX$(normalized_spec) -->
This is a long run with a spend line and a stop rule: $limits.
A run that reaches its budget or plateau writes what it has and stops; it never runs on until it dies with no report.
$cmd owns the run-status line at the top of your report, the run ledger \`$dir/run-budget.tsv\`, and every stop verdict; you may write that ledger only through it.
1. Right after setup, run \`$cmd start '$dir'\`. It records the start, reads the allowance's headroom, writes the report's first checkpoint, and prints the plan. On \`plan: short\`, cover what matters most first and expect to stop early. On \`stop:\` the report is already marked: add what you can and report done. After a relaunch, run it again; it keeps the original start.
2. Write the report as you go, never only at the end. Each time you establish a new finding, add it to the report and record it with \`$cmd finding '$dir' '<one line>'\`, which also writes it into the report's run log so it survives a run that dies before your next write.
3. Before waiting on your own long background job, run \`$cmd wait '$dir' '<what you wait on>'\`, and \`$cmd resume '$dir'\` when it returns, so the wait does not count as work that found nothing.
4. Run \`$cmd check '$dir'\` after each finding, after each wait, and at least every 30 minutes of work. \`continue\` means carry on. \`wrap-up\` means write the final report now. \`stop\` means the budget or plateau rule fired and the report is already marked stopped: finish the write-up with what you have, say what the run did not reach, run \`$cmd finish '$dir' <reason> '<what it did not reach>'\` with the reason the verdict named, and report done.
5. When the work is complete inside the budget, run \`$cmd finish '$dir' complete\` before reporting done.
EOF
}

cmd_start() {
  local dir now detail plan eff_minutes eff_spend headroom runway_min note reason
  dir=$(task_dir_arg "${1:-}") || exit 1
  load_brief_spec "$dir"
  now=$(now_epoch)
  detail=$(start_detail "$dir")
  if [ -n "$detail" ]; then
    ledger_append "$dir" "$now" restart
    ensure_report "$dir" "$(start_epoch "$dir")"
    echo "restart: keeping the run's first start at $(iso "$(start_epoch "$dir")")"
    echo "plan: $(detail_value "$detail" plan) - $(detail_value "$detail" note)"
    case "$(report_state "$dir")" in
      stopped-*) echo "stop: $(report_state "$dir" | sed 's/^stopped-//'): this run already stopped; finish the write-up and report done"; exit 3 ;;
    esac
    return 0
  fi
  plan=full eff_minutes=$S_MINUTES eff_spend=$S_SPEND note="budget fits as read"
  Q_PCT='' Q_RUNWAY='' Q_WHY=''
  if [ -n "$S_ALLOWANCE" ]; then
    read_allowance "$S_ALLOWANCE"
    if [ -z "$Q_PCT" ]; then
      note="$S_ALLOWANCE allowance headroom unknown ($Q_WHY); time and plateau rules apply until a check can read it, and the spend line counts from that reading"
    else
      headroom=$((Q_PCT - S_RESERVE))
      if [ "$headroom" -le 0 ]; then
        plan=stop
        note="$S_ALLOWANCE allowance at $Q_PCT percent, at or under its $S_RESERVE percent reserve"
      else
        note="$S_ALLOWANCE allowance at $Q_PCT percent, $headroom points above the reserve"
        if [ -n "$S_SPEND" ] && [ "$headroom" -lt "$S_SPEND" ]; then
          plan=short eff_spend=$headroom
          note="$note, under the $S_SPEND-point spend line, so the spend line shrinks to $headroom"
        fi
        if [ -n "$S_MINUTES" ] && [ -n "$Q_RUNWAY" ] && [ "$Q_RUNWAY" -lt $((S_MINUTES * 60)) ]; then
          runway_min=$((Q_RUNWAY / 60))
          [ "$runway_min" -gt 0 ] || runway_min=1
          plan=short eff_minutes=$runway_min
          note="$note; projected runway $runway_min minutes is under the $S_MINUTES-minute budget, so the time budget shrinks to $runway_min"
        fi
      fi
    fi
  fi
  ledger_append "$dir" "$now" start "plan=$plan minutes=$S_MINUTES eff_minutes=$eff_minutes allowance=$S_ALLOWANCE spend=$S_SPEND eff_spend=$eff_spend reserve=$S_RESERVE plateau=$S_PLATEAU start_pct=$Q_PCT runway_s=$Q_RUNWAY note=$note"
  ensure_report "$dir" "$now"
  if [ "$plan" = stop ]; then
    reason=reserve
    ledger_append "$dir" "$now" stop "reserve at start: $note"
    set_status "$dir" "stopped-$reason" "$(stop_sentence "$reason" "$dir" "$now" "It stopped before doing any work.")"
    echo "stop: reserve: $note; the report is marked stopped, so record what you can and report done"
    exit 3
  fi
  echo "plan: $plan - $note"
  [ -z "$eff_minutes" ] || echo "time budget: $eff_minutes minutes, until $(iso $((now + eff_minutes * 60)))"
  [ -z "$eff_spend" ] || echo "spend line: $eff_spend points of the $S_ALLOWANCE allowance"
  [ -z "$S_ALLOWANCE" ] || echo "reserve: stop when the $S_ALLOWANCE allowance falls to $S_RESERVE percent"
  echo "plateau: stop after $S_PLATEAU minutes of work with no new finding"
  echo "report checkpoint: $(report "$dir")"
}

require_started() {  # <task-dir>
  [ -n "$(start_detail "$1")" ] || die "run not started; run fm-run-budget.sh start $1 first"
}

cmd_finding() {
  local dir text now
  dir=$(task_dir_arg "${1:-}") || exit 1
  text=$(one_line "${2:-}")
  [ -n "$text" ] || usage
  require_started "$dir"
  now=$(now_epoch)
  ledger_append "$dir" "$now" finding "$text"
  append_run_log "$dir" "- $(iso "$now") $text"
  echo "finding $(finding_count "$dir") recorded"
}

cmd_wait() {
  local dir text
  dir=$(task_dir_arg "${1:-}") || exit 1
  text=$(one_line "${2:-}")
  [ -n "$text" ] || usage
  require_started "$dir"
  ledger_append "$dir" "$(now_epoch)" wait "$text"
  echo "wait recorded; run resume when it returns"
}

cmd_resume() {
  local dir
  dir=$(task_dir_arg "${1:-}") || exit 1
  require_started "$dir"
  ledger_append "$dir" "$(now_epoch)" resume
  echo "resume recorded"
}

cmd_check() {
  local dir now detail start elapsed eff_minutes eff_spend allowance reserve plateau start_pct
  local spent='' active reason='' stop_detail='' parts='' wrap=0 state
  dir=$(task_dir_arg "${1:-}") || exit 1
  require_started "$dir"
  state=$(report_state "$dir")
  case "$state" in
    stopped-*) echo "stop: ${state#stopped-}: this run already stopped; finish the write-up and report done"; exit 3 ;;
  esac
  now=$(now_epoch)
  detail=$(start_detail "$dir")
  start=$(start_epoch "$dir")
  eff_minutes=$(detail_value "$detail" eff_minutes)
  eff_spend=$(detail_value "$detail" eff_spend)
  allowance=$(detail_value "$detail" allowance)
  reserve=$(detail_value "$detail" reserve)
  plateau=$(detail_value "$detail" plateau)
  start_pct=$(detail_value "$detail" start_pct)
  [ -n "$start_pct" ] || start_pct=$(baseline_pct "$dir")
  elapsed=$((now - start))
  if [ -n "$allowance" ]; then
    read_allowance "$allowance"
    if [ -z "$Q_PCT" ]; then
      parts="$allowance allowance unknown ($Q_WHY)"
    else
      if [ -z "$start_pct" ]; then
        start_pct=$Q_PCT
        ledger_append "$dir" "$now" baseline "$start_pct"
      fi
      spent=$((start_pct - Q_PCT))
      [ "$spent" -ge 0 ] || spent=0
      if [ "$Q_PCT" -le "$reserve" ]; then
        reason=reserve stop_detail="$allowance allowance at $Q_PCT percent, at or under its $reserve percent reserve"
      elif [ -n "$eff_spend" ] && [ -n "$spent" ] && [ "$spent" -ge "$eff_spend" ]; then
        reason=spend stop_detail="$spent of $eff_spend allowance points used"
      fi
      if [ -n "$eff_spend" ] && [ -n "$spent" ]; then
        parts="$spent of $eff_spend allowance points used ($allowance at $Q_PCT percent, reserve $reserve)"
        [ $((spent * 100)) -lt $((eff_spend * WRAP_UP_PERCENT)) ] || wrap=1
      else
        parts="$allowance at $Q_PCT percent, reserve $reserve"
      fi
    fi
  fi
  if [ -n "$eff_minutes" ]; then
    parts="$((elapsed / 60)) of $eff_minutes minutes used${parts:+; $parts}"
    if [ -z "$reason" ] && [ "$elapsed" -ge $((eff_minutes * 60)) ]; then
      reason=time stop_detail="$((elapsed / 60)) of $eff_minutes minutes used"
    fi
    [ $((elapsed * 100)) -lt $((eff_minutes * 60 * WRAP_UP_PERCENT)) ] || wrap=1
  fi
  active=$(plateau_active_seconds "$dir" "$now")
  parts="$parts; $((active / 60)) of $plateau plateau minutes since the last finding"
  if [ -z "$reason" ] && [ "$active" -ge $((plateau * 60)) ]; then
    reason=plateau stop_detail="$((active / 60)) minutes of work since the last new finding"
  fi
  if [ -n "$reason" ]; then
    ledger_append "$dir" "$now" stop "$reason: $stop_detail"
    set_status "$dir" "stopped-$reason" "$(stop_sentence "$reason" "$dir" "$now")"
    echo "stop: $reason: $stop_detail; the report is marked stopped, so finish the write-up with what you have and run: fm-run-budget.sh finish $dir $reason '<what the run did not reach>'"
    exit 3
  fi
  if [ "$wrap" = 1 ]; then
    echo "wrap-up: $parts; write the final report now, then finish"
  else
    echo "continue: $parts"
  fi
}

cmd_finish() {
  local dir outcome note now start
  dir=$(task_dir_arg "${1:-}") || exit 1
  outcome=${2:-}
  note=$(one_line "${3:-}")
  require_started "$dir"
  now=$(now_epoch)
  start=$(start_epoch "$dir")
  case "$outcome" in
    complete)
      set_status "$dir" complete "complete at $(iso "$now"), $(((now - start) / 60)) minutes after it started.${note:+ $note}" ;;
    time|spend|reserve|plateau)
      set_status "$dir" "stopped-$outcome" "$(stop_sentence "$outcome" "$dir" "$now" "$note")" ;;
    *) usage ;;
  esac
  ledger_append "$dir" "$now" finish "$outcome${note:+: $note}"
  echo "run status: $(report_state "$dir")"
}

cmd_salvage() {
  local dir why now last state count
  dir=$(task_dir_arg "${1:-}") || exit 1
  why=$(one_line "${2:-the run ended without recording a finish}")
  now=$(now_epoch)
  state=$(report_state "$dir")
  if [ ! -f "$(ledger "$dir")" ]; then
    if [ "$state" = missing ]; then
      set_status "$dir" not-started "did not run ($why), recorded at $(iso "$now"). No findings were recorded."
      echo "run status: not-started"
    else
      echo "run status: $state (no run ledger; left alone)"
    fi
    return 0
  fi
  if awk -F'\t' '$2 == "finish" { found = 1; exit } END { exit !found }' "$(ledger "$dir")"; then
    echo "run status: $state (the run recorded a finish; left alone)"
    return 0
  fi
  case "$state" in
    in-progress|missing|no-status) ;;
    *) echo "run status: $state (left alone)"; return 0 ;;
  esac
  last=$(last_activity_epoch "$dir")
  count=$(finding_count "$dir")
  if [ ! -f "$(report "$dir")" ] || ! grep -qx '## Run log' "$(report "$dir")"; then
    awk -F'\t' '$2 == "finding" { print $1 "\t" $3 }' "$(ledger "$dir")" | while IFS="$(printf '\t')" read -r ts text; do
      append_run_log "$dir" "- $(iso "$ts") $text"
    done
  fi
  set_status "$dir" ended-unfinished "ended without finishing ($why), recorded at $(iso "$now"). Its last recorded activity was at $(iso "${last:-$now}") with $count findings recorded; this report is that checkpoint and may be partial."
  ledger_append "$dir" "$now" salvage "$why"
  echo "run status: ended-unfinished"
}

cmd_status() {
  local d
  [ "$#" -gt 0 ] || usage
  for d in "$@"; do
    [ -d "$d" ] || { printf '%s\tmissing\n' "$(basename "$d")"; continue; }
    printf '%s\t%s\n' "$(basename "$d")" "$(report_state "$d")"
  done
}

sub=${1:-}
[ "$#" -eq 0 ] || shift
case "$sub" in
  render) cmd_render "$@" ;;
  start) cmd_start "$@" ;;
  finding) cmd_finding "$@" ;;
  wait) cmd_wait "$@" ;;
  resume) cmd_resume "$@" ;;
  check) cmd_check "$@" ;;
  finish) cmd_finish "$@" ;;
  salvage) cmd_salvage "$@" ;;
  status) cmd_status "$@" ;;
  -h|--help|help) help ;;
  *) usage ;;
esac

#!/usr/bin/env bash
# fm-check-results.sh - the two daily check-result lines the nightly Backpass
# reports, computed only from durable records, so a change in what the fleet
# catches can be attributed to the intake checks that caught it.
#
# Usage:
#   fm-check-results.sh --since <time> [--until <time>] [--json <file>]
#   fm-check-results.sh --help
#
# <time> is a UTC timestamp YYYY-MM-DDTHH:MM:SSZ or a date YYYY-MM-DD (UTC
# midnight); --until defaults to now. The window is since <= time < until.
#
# Records read, all from this home (FM_DATA_OVERRIDE, else $FM_HOME/data):
#   skill-fires.tsv  the append-only skill-fire log (bin/fm-dod-lib.sh's
#                    fm_skill_fire_append owns its format). bin/fm-spawn.sh
#                    writes checks-admitted, checks-invalid, and checks-exempt
#                    at launch; bin/fm-crew-state.sh writes checks-refused when
#                    a done is refused by a failing intake check and
#                    checks-passed when every admitted check passes on a done.
#   the backlog      Done rows of kind ship or scout, read through tasks-axi
#                    from the live backlog and, on the markdown backend, from
#                    the Done archive retention moves closed rows into.
# Nothing is written except the optional --json file.
#
# Line 1, refusals: the done claims the checks refused in the window and how
# each was settled by the first checks-passed the same task records after it in
# the log. Both fires carry the checked deliverable state (`head=<token>; `, a
# ship's HEAD commit or a scout's digest of the files its checks read), and a
# refusal is recorded once per done status line (`line=<key>; `), so a done
# claim refused while the work changes under it counts once, with the head its
# first refusal checked. A
# refusal is confirmed by a later pass on changed work when both heads are
# recorded and differ: the admitted checks cannot change after launch, so the
# work was changed until the check that refused it passed. A first later pass
# on the same head (or with a head missing) is counted as later passed on
# unchanged work, which a transient check failure or a fixed evidence path
# produces, so it never counts as a confirmation. A refusal with no later pass
# is still open. Refusals recorded before the window whose first later pass
# falls in it and confirms them are counted separately, so a refusal is never
# confirmed twice. "by check"
# names each refused check as <task>/<check-id> with its refusals,
# confirmations, and unchanged passes, matching the ids the task's checks-admitted lines name
# and the standing- ids of the standing checks validate adds; a
# refusal of a missing or altered checks record is attributed to <task>/record,
# and one naming no such check to <task>/unattributed. The line also counts the
# tasks whose checks passed in the window. Captain send-backs after the checks
# passed have no durable record yet, so the line prints them as not recorded
# rather than estimating a number.
#
# Line 2, intake: the checks written at launch in the window (distinct task and
# check id pairs with an admitted or invalid verdict; a malformed slot counts
# as one written check, <task>/slot), how many failed validation (any invalid
# verdict, even when a later launch admitted the corrected check), and the
# tasks whose latest launch in the window took the no-checks exemption out of
# all tasks launched with an intake verdict.
#
# Both lines end with the deliverables shipped: Done ship and scout rows whose
# closed day begins inside the window. tasks-axi records closed as a local
# calendar day, so a day counts when its local midnight is at or after since
# and before until; a nightly window therefore counts each day once.
#
# Shares print as whole percents, or n/a when nothing was counted. A night with
# no checked task prints zero counts. A missing skill-fire log is a home that
# has recorded no fire yet and also prints zeros.
#
# --json <file> writes the same figures as one object with schema
# fm-check-results.v1: window, refusals{refused,tasks,confirmed,unchanged,open,
# earlier_confirmed,passed_tasks,captain_send_backs,by_check[]}, intake{
# written,invalid,tasks,exempt_tasks}, shipped, and sources.
#
# Exit codes: 0 printed; 1 a record could not be read (named on stderr);
# 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"  # FM_DOD_CHECKS_REFUSAL_PREFIX, the refusal text the log records

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-check-results: %s\n' "$1" >&2
  echo "run 'fm-check-results.sh --help' for usage" >&2
  exit 2
}

die() {
  printf 'fm-check-results: %s\n' "$1" >&2
  exit 1
}

# Epoch seconds of a UTC timestamp or date, or nothing when it is neither.
to_epoch() {  # <time>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) set -- "${1}T00:00:00Z" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 0 ;;
  esac
  jq -nr --arg t "$1" 'try ($t | fromdateiso8601) catch empty' 2>/dev/null
}

SINCE='' UNTIL='' JSON_OUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --since|--until|--json)
      [ $# -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --since) SINCE=$2 ;;
        --until) UNTIL=$2 ;;
        --json) JSON_OUT=$2 ;;
      esac
      shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$SINCE" ] || die_usage "--since is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
SINCE_EPOCH=$(to_epoch "$SINCE")
[ -n "$SINCE_EPOCH" ] || die_usage "--since must be YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD, not $SINCE"
if [ -n "$UNTIL" ]; then
  UNTIL_EPOCH=$(to_epoch "$UNTIL")
  [ -n "$UNTIL_EPOCH" ] || die_usage "--until must be YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD, not $UNTIL"
else
  UNTIL_EPOCH=$(date -u +%s)
fi
[ "$UNTIL_EPOCH" -gt "$SINCE_EPOCH" ] || die_usage "--until must be later than --since"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-check-results.XXXXXX") || die "cannot create a scratch directory"
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { rm -rf -- "$SCRATCH"; }
trap cleanup EXIT

FIRES="$DATA/skill-fires.tsv"
if [ -e "$FIRES" ] && { [ ! -f "$FIRES" ] || [ ! -r "$FIRES" ]; }; then
  die "the skill-fire log $FIRES is not a readable file"
fi

# Done rows as "<id>\t<kind>\t<closed day>" from tasks-axi list output: every
# row line is "  <id>,<state>,<kind>,<repo>,<title>,<closed>", and only the
# title can hold commas, so the kind is the third field and closed the last.
done_rows() {  # reads tasks-axi list output on stdin
  LC_ALL=C awk -F',' '
    /^  [^ ]/ && $2 == "done" {
      id = substr($1, 3)
      if ($NF ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) printf "%s\t%s\t%s\n", id, $3, $NF
    }
  '
}

DONE_ROWS="$SCRATCH/done.tsv"
: > "$DONE_ROWS"
LIVE_OUT=$(fm_backlog_row_list "$DATA" --state "done" --fields closed --limit 1000000) \
  || die "the backlog's Done rows could not be read: $(printf '%s' "$LIVE_OUT" | head -1)"
printf '%s\n' "$LIVE_OUT" | done_rows >> "$DONE_ROWS"
ARCHIVE_SOURCE=none
if ARCHIVE=$(fm_backlog_markdown_archive_path "$DATA") && [ -f "$ARCHIVE" ]; then
  [ -r "$ARCHIVE" ] || die "the Done archive $ARCHIVE is not readable"
  ARCHIVE_SOURCE=$ARCHIVE
  # tasks-axi never lists the archive, so its rows are replayed under one
  # scratch Done section (the same replay bin/fm-captain-hold.sh reads with).
  mkdir -p "$SCRATCH/archive"
  printf 'backend = "markdown"\n' > "$SCRATCH/archive/.tasks.toml"
  { printf '## Done\n'; grep -v '^## ' "$ARCHIVE"; } > "$SCRATCH/archive/backlog.md"
  ARCHIVE_OUT=$(cd "$SCRATCH/archive" && TASKS_AXI_BACKEND=markdown fm_tasks_axi list --state "done" --fields closed --limit 1000000 --file "$SCRATCH/archive/backlog.md" 2>&1) \
    || die "the Done archive $ARCHIVE could not be read: $(printf '%s' "$ARCHIVE_OUT" | head -1)"
  printf '%s\n' "$ARCHIVE_OUT" | done_rows >> "$DONE_ROWS"
fi

# Skill-fire rows as JSON, numbered in append order, which is the order the
# confirmation rule reads.
FIRES_JSON="$SCRATCH/fires.json"
if [ -f "$FIRES" ]; then
  jq -Rn '[inputs | split("\t") | select(length >= 5 and (.[2] | startswith("checks-")))
    | {ts: .[0], task: .[1], rule: .[2], ref: (.[4:] | join(" "))}
    | if .rule == "checks-refused" or .rule == "checks-passed" then
        .ref as $ref | (($ref | capture("^head=(?<head>[^;]*); (line=[^;]*; )?(?<rest>.*)$")) // {head: "", rest: $ref}) as $h
        | . + {head: $h.head, ref: $h.rest}
      else . end]
    | to_entries | map(.value + {n: .key})' "$FIRES" > "$FIRES_JSON" \
    || die "the skill-fire log $FIRES could not be parsed"
else
  printf '[]\n' > "$FIRES_JSON"
fi
DONE_JSON="$SCRATCH/done.json"
jq -Rn '[inputs | split("\t") | select(length == 3) | {id: .[0], kind: .[1], closed: .[2]}]' "$DONE_ROWS" > "$DONE_JSON" \
  || die "the backlog's Done rows could not be parsed"

RESULT=$(jq -n \
  --slurpfile fires "$FIRES_JSON" --slurpfile closed_rows "$DONE_JSON" \
  --argjson since "$SINCE_EPOCH" --argjson until "$UNTIL_EPOCH" \
  --arg fires_path "$FIRES" --arg archive "$ARCHIVE_SOURCE" --arg prefix "$FM_DOD_CHECKS_REFUSAL_PREFIX" '
  def iso: strftime("%Y-%m-%dT%H:%M:%SZ");
  def epoch: try fromdateiso8601 catch null;
  def inwin: (.ts | epoch) as $t | $t != null and $t >= $since and $t < $until;
  def beforeend: (.ts | epoch) as $t | $t != null and $t < $until;
  def share($a; $b): if $b == 0 then "n/a" else "\(($a * 100 / $b) | round)%" end;
  ($fires[0]) as $all
  # Admitted check ids per task, from every launch before the window ends.
  | ([$all[] | select(.rule == "checks-admitted" and beforeend)] | group_by(.task)
      | map({key: .[0].task, value: [.[].ref] | unique}) | from_entries) as $admitted
  # The ids of the admitted and standing checks a refusal names, or its one
  # fallback label. Standing checks are added to the record by validate, not
  # logged at launch, so they are read from their reserved standing- prefix.
  | def refused_ids($r):
      ($r.ref | ltrimstr($prefix) | sub("^ +"; "")) as $why
      | ([($admitted[$r.task] // [])[] as $id
          | select($why | test("(^|; )" + $id + ": ")) | $id]
        + [$why | scan("(?:^|; )(standing-[a-z0-9-]+): ") | .[0]]
        | unique)
      | if length > 0 then .
        elif ($why | startswith("the admitted checks record ")) then ["record"]
        else ["unattributed"] end;
  ([$all[] | select(.rule == "checks-passed" and beforeend)]) as $passes
  # The first pass of the same task after a refusal settles it: confirmed when
  # both carry a checked head and the heads differ (the work changed), else
  # unchanged (the same work later passed, so the refusal did not catch work
  # that needed changing).
  | def first_pass($r): [$passes[] | select(.task == $r.task and .n > $r.n)] | first;
  def verdict($r; $p):
      if $p == null then "open"
      elif ($r.head != "" and $p.head != "" and $r.head != $p.head) then "confirmed"
      else "unchanged" end;
  ([$all[] | select(.rule == "checks-refused" and inwin)]
    | map(. + {ids: refused_ids(.), verdict: verdict(.; first_pass(.))})) as $refusals
  | ([$all[] | select(.rule == "checks-refused" and ((.ts | epoch) // 0) < $since)]
    | map(. as $r | first_pass($r) as $p | select($p != null and ($p | inwin) and verdict($r; $p) == "confirmed"))
    | length) as $earlier
  | ([$refusals[] | .ids[] as $id | {check: "\(.task)/\($id)", verdict}]
    | group_by(.check)
    | map({check: .[0].check, refused: length,
           confirmed: ([.[] | select(.verdict == "confirmed")] | length),
           unchanged: ([.[] | select(.verdict == "unchanged")] | length)})) as $by_check
  | ([$all[] | select(.rule == "checks-passed" and inwin) | .task] | unique | length) as $passed_tasks
  # Intake verdicts in the window.
  | ([$all[] | select((.rule == "checks-admitted" or .rule == "checks-invalid" or .rule == "checks-exempt") and inwin)]) as $intake
  | ([$intake[] | select(.rule != "checks-exempt")
      | {task, id: (if .rule == "checks-admitted" then .ref
                    elif (.ref | startswith("## Checks")) then "slot"
                    else (.ref | sub(":.*$"; "")) end),
         invalid: (.rule == "checks-invalid")}]
    | group_by([.task, .id])
    | map({task: .[0].task, id: .[0].id, invalid: any(.[]; .invalid)})) as $written
  | ($intake | group_by(.task) | map(max_by(.n))) as $latest
  # Shipped: Done ship and scout rows whose closed day begins in the window,
  # that is after the local day since falls in (or on it when since is that
  # day at local midnight) and no later than the local day before until.
  | ($since | strflocaltime("%Y-%m-%d")) as $since_day
  | (($since | strflocaltime("%H:%M:%S")) == "00:00:00") as $since_midnight
  | (($until - 1) | strflocaltime("%Y-%m-%d")) as $last_day
  | ([$closed_rows[0][] | select((.kind == "ship" or .kind == "scout")
        and (.closed > $since_day or (.closed == $since_day and $since_midnight))
        and .closed <= $last_day) | .id]
    | unique | length) as $shipped
  | {
      schema: "fm-check-results.v1",
      window: {since: ($since | iso), until: ($until | iso)},
      refusals: {
        refused: ($refusals | length),
        tasks: ([$refusals[] | .task] | unique | length),
        confirmed: ([$refusals[] | select(.verdict == "confirmed")] | length),
        unchanged: ([$refusals[] | select(.verdict == "unchanged")] | length),
        open: ([$refusals[] | select(.verdict == "open")] | length),
        earlier_confirmed: $earlier,
        passed_tasks: $passed_tasks,
        captain_send_backs: null,
        by_check: $by_check
      },
      intake: {
        written: ($written | length),
        invalid: ([$written[] | select(.invalid)] | length),
        tasks: ($latest | length),
        exempt_tasks: ([$latest[] | select(.rule == "checks-exempt")] | length)
      },
      shipped: $shipped,
      sources: {skill_fires: $fires_path, done_archive: $archive}
    }
  | . as $o
  | $o + {lines: [
      ("check refusals \($o.window.since) to \($o.window.until): \($o.refusals.refused) done claims refused on \($o.refusals.tasks) tasks, \($o.refusals.confirmed) confirmed by a later pass on changed work (\(share($o.refusals.confirmed; $o.refusals.refused))), \($o.refusals.unchanged) later passed on unchanged work, \($o.refusals.open) still open; earlier refusals confirmed in this window: \($o.refusals.earlier_confirmed); tasks whose checks passed: \($o.refusals.passed_tasks); captain send-backs after checks passed: not recorded; by check: "
        + (if ($o.refusals.by_check | length) == 0 then "none"
           else ($o.refusals.by_check | map("\(.check) \(.refused) refused \(.confirmed) confirmed \(.unchanged) unchanged") | join(", ")) end)
        + "; deliverables shipped: \($o.shipped)"),
      ("check intake \($o.window.since) to \($o.window.until): \($o.intake.written) checks written, \($o.intake.invalid) failed validation (\(share($o.intake.invalid; $o.intake.written))); \($o.intake.exempt_tasks) of \($o.intake.tasks) launched tasks exempt (\(share($o.intake.exempt_tasks; $o.intake.tasks))); deliverables shipped: \($o.shipped)")
    ]}
  ') || die "the check results could not be computed"

if [ -n "$JSON_OUT" ]; then
  if ! { printf '%s\n' "$RESULT" | jq 'del(.lines)' > "$JSON_OUT.tmp.$$" && mv -f "$JSON_OUT.tmp.$$" "$JSON_OUT"; }; then
    rm -f "$JSON_OUT.tmp.$$"
    die "cannot write $JSON_OUT"
  fi
fi
printf '%s\n' "$RESULT" | jq -r '.lines[]'

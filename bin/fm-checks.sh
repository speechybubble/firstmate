#!/usr/bin/env bash
# fm-checks.sh - single owner of task intake checks: the check format a brief's
# `## Checks` slot carries, the validator that admits a check only when it
# passes its known-good example and fails its known-bad one, the runner the
# done gate uses on the actual deliverable, the drive assertion-results
# format a page deliverable's drive= evidence must hold, and the no-mistakes
# gate that runs a ship's admitted checks inside its validation pipeline.
#
# Usage:
#   fm-checks.sh validate <brief> --kind <ship|scout> [--root <dir>] [--admit <file>]
#                         [--deliverable page [--base <branch>]]
#   fm-checks.sh run <admitted-file> (--head <worktree> | --dir <dir>) [--drive <file>] [--cache <file>]
#   fm-checks.sh drive-results <file>
#   fm-checks.sh register <state-dir> <task-id>
#   fm-checks.sh unregister <state-dir> <task-id>
#   fm-checks.sh gate
#   fm-checks.sh --help
#
# Firstmate writes `## Checks` at intake, from the captain's words, before any
# work exists (AGENTS.md section 11). The slot body is exactly one line
# `routine: no checks - <reason>`, or exactly one fenced ```json block holding a
# non-empty JSON array of check objects and nothing else. Each check object has:
#   id         lowercase letters, digits, and dashes, unique in the brief
#   source     the captain's words, report line, or rule the check comes from
#   type       one of the closed set below
#   target     the file the check reads: a path relative to the ship's
#              committed tree (HEAD of its worktree) or to a scout's task data
#              directory, where it defaults to report.md; never absolute and
#              never through `..`. The assertions type takes no target: it
#              reads the drive run's results named by the done line's drive=.
#   good       the text of a known-good target, or good_file: an absolute path
#              to a real past file that should pass
#   bad        the text of a known-bad target, or bad_file: an absolute path
#              to a real past file that should fail
# plus the fields its type needs. The closed set of types:
#   contains      pattern (extended regex): passes when some line matches
#   not-contains  pattern (extended regex): passes when no line matches
#   command       run (bash source): passes when it exits 0 within 60 seconds.
#                 It reads the target through $FM_CHECK_TARGET and runs in an
#                 empty scratch directory with stdin closed, so it judges the
#                 target's content and never runs the deliverable's own code.
#   json-field    path (a jq filter such as .result.status) and equals: passes
#                 when `jq -r <path>` on the target prints exactly equals
#   tsv-field     key, field (1-based column), equals, and optional key_field
#                 (1-based column, default 1): passes when the first row whose
#                 key_field column is key has equals in column field
#   assertions    assertions (array of assertion ids): passes when the drive
#                 results file holds every named assertion with pass
#   quotes        optional markers (an array of bin/fm-quote-check.sh markers,
#                 default ["attributed"]) and optional base (a branch name): passes
#                 when every quote the page presents as the captain's words is
#                 verbatim in what the captain typed; bin/fm-quote-check.sh
#                 owns that source, its freshness, each marker, and the match.
#                 A quotes check may omit target: a ship's then reads every
#                 page (.html, .htm, .xhtml) its branch changed since it left
#                 base (origin/<base>, else <base>; without base, origin's
#                 default branch, else main or master), and a scout's every
#                 page under its data directory. No page to read passes, and a
#                 base that cannot be found fails. Its verdict also depends on
#                 the source, so run first brings the source up to date under
#                 its own longer bound and keys its cache on the source's
#                 build stamp (bin/fm-quote-check.sh ensure): a result reruns
#                 when a page or the source changes, or when the source ages
#                 past the window after which a miss rebuilds it, and a run where a quotes
#                 check could not run or finish is never cached.
# Unknown fields are refused, so a misspelled field is never silently ignored.
# Ids starting with standing- are reserved for the standing checks below.
#
# validate reads the brief's `## Checks` slot and runs every check against its
# own good and bad examples, with no deliverable involved. A check is admitted
# only when its good example passes and its bad example fails; one that fails
# its good example, passes its bad example, or cannot run (an invalid regex or
# jq filter, an unreadable example file) is invalid, and so is a check that
# breaks the schema. It prints one `admitted <id>` or `invalid <id>: <why>`
# line per check, then a `checks: <n> admitted, <m> invalid` summary, or one
# `exempt: <reason>` line for the exemption. Exit 0 when the slot is exempt or
# every check is admitted, 1 when the slot is malformed or any check is
# invalid, 2 on a usage error. --admit <file> writes the admitted record (the
# normalized checks plus kind and, for a scout, the --root data directory)
# atomically to <file> on success and removes <file> on exemption, so a stale
# record never outlives the brief that replaced it. bin/fm-spawn.sh is the
# caller that refuses a launch on exit 1 and admits into state/<id>.checks.json.
#
# --deliverable page appends the standing checks every page deliverable
# carries, which Firstmate never writes per task, to the admitted record: one
# today, standing-captain-quotes, a target-less quotes check with the attributed
# marker, so a page that presents as the captain's words anything the
# captain never typed is refused at done. --base records the ship's base
# branch in it. Standing checks have no examples to validate, since their
# behavior is this script's own, and they are admitted whatever the slot
# holds: beside admitted checks, with an exempt slot, and with no slot at all,
# which without --deliverable is invalid. Each prints one `standing <id>`
# line, before the summary or after the exemption line. bin/fm-spawn.sh
# passes it for a ship brief declared a page deliverable, unless the brief
# declares the page client-facing (bin/fm-brief.sh --client-facing): a client's
# visitors are addressed there, never the captain, so it carries none.
#
# run executes an admitted record on the deliverable: with --head the target is
# read from the committed HEAD of that worktree (a ship's done claims committed
# work), with --dir from that directory (a scout's data directory; symlinked
# targets are refused). A missing target fails its check, so a check never
# passes on evidence it could not observe. --drive names the drive results file
# for assertions checks. It prints one `pass <id>` or `fail <id>: <why>` line per
# check and a `checks: <n> passed, <m> failed` summary. Exit 0 when every check
# passes, 1 when any fails, 2 on a usage error or an unreadable record.
# --cache <file> reuses the printed result while the record, every
# materialized target, and the drive path are unchanged, so a supervisor read
# repeated on every heartbeat runs each command once per deliverable state.
# bin/fm-dod-lib.sh's fm_dod_task_checks_reason is the done-time caller, which
# refuses before run when the record no longer matches the checks_sha= spawn
# recorded.
#
# drive-results checks that <file> is a drive run's assertion results: an
# absolute path to a regular file whose every line other than blank lines and
# `#` comments is `<assertion-id><TAB><pass|fail>[<TAB><detail>]`, with at least
# one assertion, no assertion repeated, and none failed. It prints the problem
# and exits 1 otherwise, 0 when the file shows every assertion passing.
# bin/fm-dod-lib.sh's fm_dod_page_evidence_reason applies it to drive=.
#
# The ship checks registry lets a no-mistakes pipeline find the ship it is
# validating. The daemon runs a gate command in a detached run worktree with no
# Firstmate home in view, so each no-mistakes ship with admitted checks leaves
# one pointer file, <registry>/<git object hash of "<state-dir>/<task-id>">.ship, holding
# state=<absolute state dir> and id=<task id>. The registry is machine-wide so
# every home on the machine shares the one daemon's view:
# $FM_SHIP_CHECKS_REGISTRY, else ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/ship-checks.
# register writes the pointer atomically and exits 1 when it cannot;
# bin/fm-spawn.sh calls it at admission and refuses the launch on failure, so a
# no-mistakes ship never runs with checks its pipeline cannot find. unregister
# removes it; bin/fm-teardown.sh calls it at cleanup. A pointer whose task meta
# is gone, or has no checks= line (the done gate's rule for a task with no
# admitted checks), is ignored, so a leftover one never gates anything.
#
# gate is the command this repository's .no-mistakes.yaml declares as a gate
# after the test step; it runs only in this repository's pipelines, so the
# registration of a ship in another project has no reader. Run from the run
# worktree, it binds the run to every registered ship whose branch is in
# the gate repository with commits of its own that the run carries, as the same
# commits or, after a pipeline rebase, as commits with the same author email,
# author date, and subject, or the same patches. For each bound ship
# it refuses a record whose digest is not the checks_sha= spawn recorded in the
# task meta, then runs the admitted checks against the run's committed HEAD, so
# pipeline fix commits are checked too. An assertions check reads a drive run
# that only the worker's done line names, so the gate prints a `skip` line for
# it and leaves it to the done gate. Output is the run's `pass`/`fail` lines,
# each failure followed by a `  from: <source>` line so a pipeline fix turn
# works toward the words the check came from, under a
# `task-checks: task <id> (<branch>)` heading, which the pipeline keeps
# as the gate step's log; a run that binds no ship says so and passes. Exit 1
# when any bound ship's record is untrusted or any check fails, 0 otherwise.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

FM_CHECKS_COMMAND_TIMEOUT=60
# The bound on bringing the captain-words source up to date before quotes checks.
FM_CHECKS_QUOTES_SOURCE_TIMEOUT=600
FM_CHECKS_EXEMPTION='routine: no checks'
# The standing checks validate --deliverable page appends (see --help).
FM_CHECKS_STANDING_PAGE='[{"id": "standing-captain-quotes", "source": "standing check on every captain-facing page deliverable: words a page presents as the captain'"'"'s must be words the captain typed (bin/fm-checks.sh)", "type": "quotes", "markers": ["attributed"]}]'

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  echo "run 'fm-checks.sh --help' for usage" >&2
  exit 2
}

SCRATCH=
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"; }
trap cleanup EXIT
scratch() {
  [ -n "$SCRATCH" ] || SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-checks.XXXXXX") || exit 2
}

# One line, at most 160 characters, for a reason printed inside a status line.
one_line() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-160
}

# The problem with <file> as drive assertion results, or nothing when it is
# well formed. With <want> (space-separated ids) it reports named assertions
# that are missing or not passing; without it, any failed assertion.
drive_results_problem() {  # <file> [<want>]
  local file=$1 want=${2:-}
  case "$file" in
    /*) ;;
    *) echo "drive results path $file is not absolute"; return 0 ;;
  esac
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    echo "$file is not a regular file of drive assertion results"
    return 0
  fi
  if [ ! -r "$file" ]; then
    echo "$file is not readable"
    return 0
  fi
  awk -F'\t' -v want="$want" -v file="$file" '
    /^[[:space:]]*$/ || /^#/ { next }
    !bad {
      if (NF < 2 || $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || ($2 != "pass" && $2 != "fail")) {
        printf "%s line %d is not an <assertion><TAB><pass|fail> result, so it is not a drive run'\''s assertion results\n", file, NR
        bad = 1
        next
      }
      if ($1 in result) {
        printf "%s reports assertion %s twice\n", file, $1
        bad = 1
        next
      }
      result[$1] = $2
      order[++n] = $1
    }
    END {
      if (bad) exit
      if (n == 0) { printf "%s holds no assertion results\n", file; exit }
      if (want != "") {
        k = split(want, ids, " ")
        for (i = 1; i <= k; i++) {
          if (!(ids[i] in result)) missing = missing (missing ? ", " : "") ids[i]
          else if (result[ids[i]] != "pass") failed = failed (failed ? ", " : "") ids[i]
        }
        if (missing != "") { printf "the drive results lack assertion %s\n", missing; exit }
        if (failed != "") { printf "the drive results show assertion %s failing\n", failed; exit }
        exit
      }
      for (i = 1; i <= n; i++) if (result[order[i]] != "pass") failed = failed (failed ? ", " : "") order[i]
      if (failed != "") printf "the drive results show assertion %s failing\n", failed
    }
  ' "$file"
}

# Bring the captain-words source up to date under its own bound and print its
# build stamp, or `unknown` when that cannot be done.
quotes_source_stamp() {
  local stamp
  stamp=$(fm_nm_bounded "$SCRIPT_DIR" "$FM_CHECKS_QUOTES_SOURCE_TIMEOUT" "$SCRIPT_DIR/fm-quote-check.sh" ensure </dev/null 2>/dev/null) || stamp=
  printf '%s\n' "${stamp:-unknown}"
}

# Run a quotes check on <target>: a materialized page, or a directory holding
# the materialized pages at their relative paths. Same contract as run_check.
run_quotes_check() {  # <check-json> <target>
  local check=$1 target=$2 dir rc out flagged marker margs=() pages=()
  while IFS= read -r marker; do
    margs+=(--marker "$marker")
  done < <(jq -r '(.markers // ["attributed"])[]' <<<"$check")
  if [ -d "$target" ]; then
    dir=$target
    while IFS= read -r -d '' marker; do
      pages+=("${marker#./}")
    done < <(cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z)
  else
    dir=$(dirname -- "$target")
    pages=("$(basename -- "$target")")
  fi
  [ "${#pages[@]}" -gt 0 ] || return 0
  quotes_source_stamp >/dev/null
  out=$(fm_nm_bounded "$dir" "$FM_CHECKS_COMMAND_TIMEOUT" "$SCRIPT_DIR/fm-quote-check.sh" check "${pages[@]}" "${margs[@]}" </dev/null 2>&1)
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      flagged=$(printf '%s\n' "$out" | grep -E '^(misquote|verbatim with omissions): ')
      echo "$(printf '%s\n' "$flagged" | grep -c .) quote(s) presented as the captain's words are not what the captain typed: $(one_line "$(printf '%s\n' "$flagged" | paste -s -d ';' - | sed 's/;/; /g')")"
      return 1 ;;
    124)
      echo "the quote check did not finish within ${FM_CHECKS_COMMAND_TIMEOUT}s"
      return 2 ;;
  esac
  echo "the quote check could not run (exit $rc)${out:+: $(one_line "$(printf '%s\n' "$out" | tail -n 1)")}"
  return 2
}

# Run one check (compact JSON) on <target>, a materialized file or, for an
# assertions check, the drive results path (possibly empty), or for a quotes
# check a directory of materialized pages. Prints the reason on failure.
# Exit 0 pass, 1 fail, 2 the check itself cannot run.
run_check() {  # <check-json> <target>
  local check=$1 target=$2 type pattern rc out run path equals key field key_field want work
  type=$(jq -r '.type' <<<"$check")
  case "$type" in
    quotes)
      run_quotes_check "$check" "$target"
      return
      ;;
    contains|not-contains)
      pattern=$(jq -r '.pattern' <<<"$check")
      out=$(grep -E -m 1 -e "$pattern" -- "$target" 2>/dev/null)
      rc=$?
      if [ "$rc" -ge 2 ]; then
        echo "pattern /$pattern/ is not a valid extended regular expression"
        return 2
      fi
      if [ "$type" = contains ]; then
        [ "$rc" -eq 0 ] && return 0
        echo "no line matches /$pattern/"
        return 1
      fi
      [ "$rc" -eq 1 ] && return 0
      echo "a line matches /$pattern/: $(one_line "$out")"
      return 1
      ;;
    command)
      run=$(jq -r '.run' <<<"$check")
      work=$(mktemp -d "$SCRATCH/cmd.XXXXXX") || return 2
      out=$(fm_nm_bounded "$work" "$FM_CHECKS_COMMAND_TIMEOUT" env FM_CHECK_TARGET="$target" bash -c "$run" </dev/null 2>&1)
      rc=$?
      rm -rf "$work"
      [ "$rc" -eq 0 ] && return 0
      if [ "$rc" -eq 124 ]; then
        echo "the command did not finish within ${FM_CHECKS_COMMAND_TIMEOUT}s"
      else
        echo "the command exited $rc${out:+: $(one_line "$(printf '%s\n' "$out" | tail -n 1)")}"
      fi
      return 1
      ;;
    json-field)
      path=$(jq -r '.path' <<<"$check")
      equals=$(jq -r '.equals' <<<"$check")
      out=$(jq -r "$path" -- "$target" 2>&1)
      rc=$?
      if [ "$rc" -eq 3 ]; then
        echo "path $path is not a valid jq filter"
        return 2
      fi
      if [ "$rc" -ne 0 ]; then
        echo "the target is not JSON that $path can read"
        return 1
      fi
      [ "$out" = "$equals" ] && return 0
      echo "$path is $(one_line "$out"), not $equals"
      return 1
      ;;
    tsv-field)
      key=$(jq -r '.key' <<<"$check")
      field=$(jq -r '.field' <<<"$check")
      key_field=$(jq -r '.key_field' <<<"$check")
      equals=$(jq -r '.equals' <<<"$check")
      out=$(awk -F'\t' -v kf="$key_field" -v k="$key" -v f="$field" '
        $kf == k { found = 1; print "row\t" $f; exit }
        END { if (!found) print "none" }
      ' "$target")
      case "$out" in
        none) echo "no row has $key in column $key_field"; return 1 ;;
      esac
      out=${out#row$'\t'}
      [ "$out" = "$equals" ] && return 0
      echo "row $key has $(one_line "$out") in column $field, not $equals"
      return 1
      ;;
    assertions)
      want=$(jq -r '.assertions | join(" ")' <<<"$check")
      if [ -z "$target" ]; then
        echo "the done line names no drive= results for assertions $want"
        return 1
      fi
      out=$(drive_results_problem "$target" "$want")
      [ -z "$out" ] && return 0
      echo "$out"
      return 1
      ;;
  esac
  echo "unknown check type $type"
  return 2
}

# Schema problems, one `bad<TAB>index<TAB>label<TAB>problem` line per problem,
# then one `ok<TAB>index<TAB>id` line per sound check; reads the checks array.
schema_lines() {  # <kind> <array-json-file>
  jq -r --arg kind "$1" '
    def need($t):
      {"contains": ["pattern"], "not-contains": ["pattern"], "command": ["run"],
       "json-field": ["path", "equals"], "tsv-field": ["key", "field", "equals"],
       "assertions": ["assertions"], "quotes": []}[$t];
    def may($t): need($t) + (if $t == "tsv-field" then ["key_field"] elif $t == "quotes" then ["markers", "base"] else [] end);
    def common: ["id", "source", "type", "target", "good", "good_file", "bad", "bad_file"];
    def nonempty: type == "string" and test("\\S");
    def problems($c):
      if ($c | type) != "object" then ["is not a JSON object"]
      else
        ($c.type // "") as $t
        | [
          (if ($c.id | type) == "string" and ($c.id | test("^[a-z0-9][a-z0-9-]*$")) then
             (if $c.id | startswith("standing-") then "id \($c.id) is reserved: ids starting with standing- name standing checks" else empty end)
           else "id must be lowercase letters, digits, and dashes" end),
          (if ($c.source | nonempty) then empty else "source must name the words or rule the check comes from" end),
          (if need($t) == null then "type must be one of contains, not-contains, command, json-field, tsv-field, assertions, quotes"
           else
             (($c | keys) - common - may($t) | if length > 0 then "unknown field \(join(", "))" else empty end),
             (need($t)[] as $f | if $c | has($f) then empty else "type \($t) needs \($f)" end),
             (if $t == "assertions" then
                (if $c | has("target") then "an assertions check reads the drive results, so it takes no target" else empty end),
                (if ($c.assertions | type) == "array" and ($c.assertions | length) > 0
                    and all($c.assertions[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
                 then empty else "assertions must be a non-empty array of assertion ids" end)
              elif $c | has("target") then
                (if ($c.target | nonempty) and ($c.target | startswith("/") | not)
                    and ($c.target | split("/") | index("..") == null)
                 then empty else "target must be a relative path without .." end)
              elif $kind == "ship" and $t != "quotes" then "a ship check needs a target path in the committed tree"
              else empty end),
             (if $t == "quotes" then
                (if ($c | has("markers") | not) or (($c.markers | type) == "array" and ($c.markers | length) > 0
                    and all($c.markers[]; type == "string" and test("^\\S") and (test("\n") | not)))
                 then empty else "markers must be a non-empty array of quote-check markers" end),
                (if ($c | has("base") | not) or (($c.base | type) == "string" and ($c.base | test("^[^\\s]+$")))
                 then empty else "base must be a branch name" end)
              else empty end),
             (if $t == "contains" or $t == "not-contains" then (if ($c.pattern | nonempty) then empty else "pattern must be a non-empty string" end) else empty end),
             (if $t == "command" then (if ($c.run | nonempty) then empty else "run must be a non-empty string" end) else empty end),
             (if $t == "json-field" then
                (if ($c.path | type) == "string" and ($c.path | startswith(".")) then empty else "path must be a jq filter starting with ." end),
                (if ($c.equals | type) == "string" then empty else "equals must be a string" end)
              else empty end),
             (if $t == "tsv-field" then
                (if ($c.key | type) == "string" then empty else "key must be a string" end),
                (if ($c.equals | type) == "string" then empty else "equals must be a string" end),
                ([$c.field, ($c.key_field // 1)][] | if type == "number" and . >= 1 and . == floor then empty else "field and key_field must be 1-based column numbers" end)
              else empty end)
           end),
          ("good", "bad" | . as $e
           | if ($c | has($e)) and ($c | has($e + "_file")) then "give \($e) or \($e)_file, not both"
             elif $c | has($e) then (if ($c[$e] | type) == "string" then empty else "\($e) must be a string" end)
             elif $c | has($e + "_file") then (if ($c[$e + "_file"] | type) == "string" and ($c[$e + "_file"] | startswith("/")) then empty else "\($e)_file must be an absolute path" end)
             else "needs a known-\($e) example (\($e) or \($e)_file)" end)
        ]
      end;
    [.[] | if type == "object" then .id else null end] as $ids
    | to_entries[]
    | .key as $i | .value as $c
    | (if ($c | type) == "object" and ($c.id | type) == "string" then $c.id else "#\($i + 1)" end) as $label
    | (problems($c) + (if ($c | type) == "object" and ($c.id | type) == "string" and ([$ids[] | select(. == $c.id)] | length) > 1 then ["id \($c.id) is used by more than one check"] else [] end)) as $p
    | if ($p | length) > 0 then "bad\t\($i)\t\($label)\t\($p | join("; "))" else "ok\t\($i)\t\($c.id)" end
  ' "$2"
}

# Print the body of the one ```json block a `## Checks` body holds, or the
# problem prefixed with "!" when it holds anything else.
checks_json_block() {  # <body>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*$/ && state != 1 { next }
    state == 0 {
      if ($0 ~ /^(```|~~~)[[:space:]]*json[[:space:]]*$/) { fence = substr($0, 1, 3); state = 1; next }
      print "!holds text outside one fenced json block"; bad = 1; exit
    }
    state == 1 {
      if ($0 ~ /^(```|~~~)[[:space:]]*$/ && substr($0, 1, 3) == fence) { state = 2; next }
      block = block $0 "\n"; next
    }
    state == 2 { print "!holds text after its fenced json block"; bad = 1; exit }
    END {
      if (bad) exit
      if (state == 0) print "!is empty"
      else if (state == 1) print "!has an unclosed fenced json block"
      else printf "%s", block
    }
  '
}

materialize_example() {  # <check-json> <good|bad> <out-file>
  local check=$1 which=$2 out=$3 file
  if jq -e --arg w "$which" 'has($w)' <<<"$check" >/dev/null; then
    jq -j --arg w "$which" '.[$w]' <<<"$check" > "$out"
    return 0
  fi
  file=$(jq -r --arg w "${which}_file" '.[$w]' <<<"$check")
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "${which}_file $file is not a readable regular file"
    return 1
  fi
  cp -- "$file" "$out"
}

# Write the admitted record <checks-json> to <admit> atomically, or remove
# <admit> when <checks-json> is empty. Prints the problem and returns 1 when
# it cannot be written.
write_admitted() {  # <admit> <kind> <root> <checks-json>
  local admit=$1 kind=$2 root=$3 checks=$4 tmp
  [ -n "$admit" ] || return 0
  if [ "$(jq 'length' <<<"$checks")" -eq 0 ]; then
    rm -f -- "$admit"
    return 0
  fi
  tmp="$admit.tmp.$$"
  if ! jq -n --arg kind "$kind" --arg root "$root" --argjson checks "$checks" \
    '{version: 1, kind: $kind, checks: $checks} + (if $kind == "scout" then {root: $root} else {} end)' > "$tmp" \
    || ! mv -f -- "$tmp" "$admit"; then
    rm -f -- "$tmp"
    echo "invalid: the admitted checks could not be written to $admit"
    return 1
  fi
}

cmd_validate() {
  local brief='' kind='' root='' admit='' deliverable='' base='' body block array lines line tag idx label why check id
  local admitted=0 invalid=0 out rc good bad admitted_json='[]' standing_json='[]'
  [ "$#" -gt 0 ] || die_usage "validate needs a brief"
  brief=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || die_usage "--kind needs a value"; kind=$2; shift 2 ;;
      --root) [ "$#" -ge 2 ] || die_usage "--root needs a value"; root=$2; shift 2 ;;
      --admit) [ "$#" -ge 2 ] || die_usage "--admit needs a file"; admit=$2; shift 2 ;;
      --deliverable) [ "$#" -ge 2 ] || die_usage "--deliverable needs a value"; deliverable=$2; shift 2 ;;
      --base) [ "$#" -ge 2 ] || die_usage "--base needs a branch"; base=$2; shift 2 ;;
      *) die_usage "unknown validate argument $1" ;;
    esac
  done
  case "$kind" in ship|scout) ;; *) die_usage "--kind must be ship or scout" ;; esac
  case "$deliverable" in
    '') [ -z "$base" ] || die_usage "--base applies only with --deliverable page" ;;
    page) standing_json=$(jq -c --arg base "$base" 'map(if $base != "" then .base = $base else . end)' <<<"$FM_CHECKS_STANDING_PAGE") ;;
    *) die_usage "--deliverable must be page" ;;
  esac
  [ -f "$brief" ] && [ -r "$brief" ] || die_usage "brief $brief is not a readable file"
  if ! fm_brief_task_heading_present "$brief" "## Checks"; then
    if [ -z "$deliverable" ]; then
      echo "invalid: $brief has no ## Checks subsection"
      return 1
    fi
    write_admitted "$admit" "$kind" "$root" "$standing_json" || return 1
    jq -r '.[] | "standing \(.id)"' <<<"$standing_json"
    return 0
  fi
  body=$(fm_brief_task_heading_body "$brief" "## Checks")
  if printf '%s\n' "$body" | grep -q "^[[:space:]]*$FM_CHECKS_EXEMPTION"; then
    lines=$(printf '%s\n' "$body" | grep -c -v -e '^[[:space:]]*$')
    why=$(printf '%s\n' "$body" | sed -n "s/^[[:space:]]*$FM_CHECKS_EXEMPTION - //p" | head -n 1)
    if [ "$lines" -ne 1 ] || [ -z "$(printf '%s' "$why" | tr -d '[:space:]')" ]; then
      echo "invalid: ## Checks must be exactly one line \`$FM_CHECKS_EXEMPTION - <reason>\` when it is exempt"
      return 1
    fi
    write_admitted "$admit" "$kind" "$root" "$standing_json" || return 1
    echo "exempt: $why"
    jq -r '.[] | "standing \(.id)"' <<<"$standing_json"
    return 0
  fi
  block=$(checks_json_block "$body")
  case "$block" in
    '!'*)
      echo "invalid: ## Checks ${block#!}; write one fenced json block holding the checks, or one line \`$FM_CHECKS_EXEMPTION - <reason>\`"
      return 1 ;;
  esac
  scratch
  array="$SCRATCH/checks.json"
  printf '%s\n' "$block" > "$array"
  if ! jq -e 'type == "array" and length > 0' "$array" >/dev/null 2>&1; then
    echo "invalid: ## Checks json block is not a non-empty JSON array of checks"
    return 1
  fi
  lines=$(schema_lines "$kind" "$array") || {
    echo "invalid: ## Checks could not be read"
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tag=${line%%	*}
    line=${line#*	}
    idx=${line%%	*}
    line=${line#*	}
    if [ "$tag" = bad ]; then
      label=${line%%	*}
      why=${line#*	}
      # One line per check: its schema problems arrive joined, so it counts once.
      echo "invalid $label: $why"
      invalid=$((invalid + 1))
      continue
    fi
    id=$line
    check=$(jq -c --argjson i "$idx" --arg kind "$kind" '
      .[$i]
      | if .type != "assertions" and .type != "quotes" and (has("target") | not) and $kind == "scout" then .target = "report.md" else . end
      | if .type == "tsv-field" and (has("key_field") | not) then .key_field = 1 else . end
      | if .type == "quotes" and (has("markers") | not) then .markers = ["attributed"] else . end
    ' "$array")
    good="$SCRATCH/$idx.good"
    bad="$SCRATCH/$idx.bad"
    if ! why=$(materialize_example "$check" good "$good") || ! why=$(materialize_example "$check" bad "$bad"); then
      echo "invalid $id: $why"
      invalid=$((invalid + 1))
      continue
    fi
    out=$(run_check "$check" "$good")
    rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "invalid $id: $out"
      invalid=$((invalid + 1))
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      echo "invalid $id: fails its good example ($out)"
      invalid=$((invalid + 1))
      continue
    fi
    out=$(run_check "$check" "$bad")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "invalid $id: passes its bad example, so it cannot tell bad work from good"
      invalid=$((invalid + 1))
      continue
    fi
    if [ "$rc" -eq 2 ]; then
      echo "invalid $id: $out"
      invalid=$((invalid + 1))
      continue
    fi
    echo "admitted $id"
    admitted=$((admitted + 1))
    admitted_json=$(jq -c --argjson c "$check" '. + [$c]' <<<"$admitted_json")
  done <<EOF
$lines
EOF
  [ "$invalid" -ne 0 ] || jq -r '.[] | "standing \(.id)"' <<<"$standing_json"
  echo "checks: $admitted admitted, $invalid invalid"
  [ "$invalid" -eq 0 ] || return 1
  write_admitted "$admit" "$kind" "$root" "$(jq -c --argjson s "$standing_json" '. + $s' <<<"$admitted_json")"
}

hash_file() {  # <file>
  git hash-object --no-filters -- "$1" 2>/dev/null || echo missing
}

# The first ref a ship's quotes check finds its base at in <worktree>, or
# nothing: origin/<base> then <base>, or without a base origin's default
# branch, then main, then master.
quotes_base_ref() {  # <worktree> <base>
  local wt=$1 base=$2 ref
  if [ -n "$base" ]; then
    set -- "refs/remotes/origin/$base" "refs/heads/$base"
  else
    set -- refs/remotes/origin/HEAD refs/heads/main refs/heads/master
  fi
  for ref in "$@"; do
    if git -C "$wt" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# Materialize the pages a target-less quotes check reads into the directory
# <out>, at their relative paths: with <worktree>, every page its committed
# HEAD changed since it left <base>; with <dir>, every page file under it.
# Prints the reason and returns 1 when the base cannot be found.
quotes_pages() {  # <out> <worktree> <dir> <base>
  local out=$1 wt=$2 dir=$3 base=$4 ref mb rel
  mkdir -p -- "$out" || return 1
  if [ -n "$wt" ]; then
    if ! ref=$(quotes_base_ref "$wt" "$base") || ! mb=$(git -C "$wt" merge-base HEAD "$ref" 2>/dev/null); then
      [ -n "$base" ] || base="origin's default branch"
      echo "the base $base the ship branched from cannot be found, so its changed pages cannot be read"
      return 1
    fi
    while IFS= read -r -d '' rel; do
      if ! { mkdir -p -- "$out/$(dirname -- "$rel")" && git -C "$wt" show "HEAD:$rel" > "$out/$rel" 2>/dev/null; }; then
        rm -f -- "$out/$rel"
      fi
    done < <(git -C "$wt" -c core.quotePath=false diff --name-only -z --no-renames --diff-filter=d "$mb" HEAD -- '*.html' '*.htm' '*.xhtml')
  else
    while IFS= read -r -d '' rel; do
      rel=${rel#./}
      if ! { mkdir -p -- "$out/$(dirname -- "$rel")" && cp -- "$dir/$rel" "$out/$rel" 2>/dev/null; }; then
        rm -f -- "$out/$rel"
      fi
    done < <(cd "$dir" 2>/dev/null && find . -type f \( -name '*.html' -o -name '*.htm' -o -name '*.xhtml' \) -print0)
  fi
}

cmd_run() {
  local record='' head='' dir='' drive='' cache='' root n i check id target type path out rc
  local passed=0 failed=0 result fingerprint uncacheable=0 page
  [ "$#" -gt 0 ] || die_usage "run needs an admitted checks file"
  record=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) [ "$#" -ge 2 ] || die_usage "--head needs a worktree"; head=$2; shift 2 ;;
      --dir) [ "$#" -ge 2 ] || die_usage "--dir needs a directory"; dir=$2; shift 2 ;;
      --drive) [ "$#" -ge 2 ] || die_usage "--drive needs a file"; drive=$2; shift 2 ;;
      --cache) [ "$#" -ge 2 ] || die_usage "--cache needs a file"; cache=$2; shift 2 ;;
      *) die_usage "unknown run argument $1" ;;
    esac
  done
  if [ -n "$head" ] && [ -n "$dir" ]; then die_usage "give --head or --dir, not both"; fi
  if [ -z "$head" ] && [ -z "$dir" ]; then die_usage "run needs --head <worktree> or --dir <dir>"; fi
  if ! [ -f "$record" ] || ! jq -e '.version == 1 and (.checks | type) == "array"' "$record" >/dev/null 2>&1; then
    echo "the admitted checks record $record is missing or unreadable"
    return 2
  fi
  root=$(jq -r '.root // ""' "$record")
  n=$(jq '.checks | length' "$record")
  scratch
  i=0
  fingerprint="$SCRATCH/fingerprint"
  { hash_file "$record"; printf 'drive %s\n' "$drive"; } > "$fingerprint"
  if jq -e 'any(.checks[]; .type == "quotes")' "$record" >/dev/null; then
    printf 'quotes-source %s\n' "$(quotes_source_stamp)" >> "$fingerprint"
  fi
  while [ "$i" -lt "$n" ]; do
    check=$(jq -c --argjson i "$i" '.checks[$i]' "$record")
    type=$(jq -r '.type' <<<"$check")
    target="$SCRATCH/target.$i"
    if [ "$type" = assertions ]; then
      [ -z "$drive" ] || hash_file "$drive" >> "$fingerprint"
    elif [ "$type" = quotes ] && ! jq -e 'has("target")' <<<"$check" >/dev/null; then
      rm -rf -- "$target"
      if quotes_pages "$target" "$head" "$dir" "$(jq -r '.base // ""' <<<"$check")" > "$target.why"; then
        rm -f -- "$target.why"
        while IFS= read -r -d '' page; do
          printf '%s %s\n' "$(hash_file "$target/$page")" "$page" >> "$fingerprint"
        done < <(cd "$target" && find . -type f -print0 | LC_ALL=C sort -z)
      else
        rm -rf -- "$target"
        echo missing >> "$fingerprint"
      fi
    else
      path=$(jq -r '.target' <<<"$check")
      rm -f -- "$target"
      if [ -n "$head" ]; then
        git -C "$head" show "HEAD:$path" > "$target" 2>/dev/null || rm -f -- "$target"
      elif [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ]; then
        cp -- "$dir/$path" "$target" 2>/dev/null || rm -f -- "$target"
      fi
      if [ -f "$target" ]; then hash_file "$target" >> "$fingerprint"; else echo missing >> "$fingerprint"; fi
    fi
    i=$((i + 1))
  done
  if [ -n "$cache" ] && [ -f "$cache" ] && [ "$(head -n 1 "$cache")" = "fingerprint $(hash_file "$fingerprint")" ]; then
    rc=$(sed -n '2s/^exit //p' "$cache")
    case "$rc" in
      0|1)
        sed -n '3,$p' "$cache"
        return "$rc" ;;
    esac
  fi
  result="$SCRATCH/result"
  : > "$result"
  i=0
  while [ "$i" -lt "$n" ]; do
    check=$(jq -c --argjson i "$i" '.checks[$i]' "$record")
    id=$(jq -r '.id' <<<"$check")
    type=$(jq -r '.type' <<<"$check")
    if [ "$type" = assertions ]; then
      out=$(run_check "$check" "$drive")
      rc=$?
    elif [ -f "$SCRATCH/target.$i.why" ]; then
      out=$(cat "$SCRATCH/target.$i.why")
      rc=1
    elif [ -f "$SCRATCH/target.$i" ] || [ -d "$SCRATCH/target.$i" ]; then
      out=$(run_check "$check" "$SCRATCH/target.$i")
      rc=$?
    else
      path=$(jq -r '.target' <<<"$check")
      if [ -n "$head" ]; then
        out="target $path is not in the committed tree at HEAD"
      else
        out="target $path is missing from ${root:-$dir}"
      fi
      rc=1
    fi
    if [ "$rc" -eq 0 ]; then
      echo "pass $id" >> "$result"
      passed=$((passed + 1))
    else
      echo "fail $id: $out" >> "$result"
      failed=$((failed + 1))
      [ "$type" != quotes ] || [ "$rc" -ne 2 ] || uncacheable=1
    fi
    i=$((i + 1))
  done
  echo "checks: $passed passed, $failed failed" >> "$result"
  rc=0
  [ "$failed" -eq 0 ] || rc=1
  if [ -n "$cache" ] && [ "$uncacheable" -eq 1 ]; then
    rm -f -- "$cache"
  elif [ -n "$cache" ]; then
    if ! { { echo "fingerprint $(hash_file "$fingerprint")"; echo "exit $rc"; cat "$result"; } > "$cache.tmp.$$" 2>/dev/null \
      && mv -f -- "$cache.tmp.$$" "$cache" 2>/dev/null; }; then
      rm -f -- "$cache.tmp.$$"
    fi
  fi
  cat "$result"
  return "$rc"
}

cmd_drive_results() {
  local problem
  [ "$#" -eq 1 ] || die_usage "drive-results needs exactly one file"
  problem=$(drive_results_problem "$1")
  if [ -n "$problem" ]; then
    echo "$problem"
    return 1
  fi
  return 0
}

ship_registry_dir() {
  printf '%s\n' "${FM_SHIP_CHECKS_REGISTRY:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/ship-checks}"
}

# The registry pointer path for <state-dir> <task-id>, keyed on the physical
# state directory so two spellings of one home share one pointer.
ship_registry_entry() {  # <state-dir> <task-id>
  local state key
  state=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  key=$(printf '%s/%s' "$state" "$2" | git hash-object --stdin 2>/dev/null) || return 1
  [ -n "$key" ] || return 1
  printf '%s/%s.ship\n' "$(ship_registry_dir)" "$key"
}

cmd_register() {
  local entry state dir
  [ "$#" -eq 2 ] || die_usage "register needs <state-dir> <task-id>"
  state=$(cd "$1" 2>/dev/null && pwd -P) || { echo "state directory $1 does not exist"; return 1; }
  entry=$(ship_registry_entry "$state" "$2") || { echo "cannot name a registry entry for $2"; return 1; }
  dir=${entry%/*}
  if ! mkdir -p "$dir" 2>/dev/null \
    || ! printf 'state=%s\nid=%s\n' "$state" "$2" > "$entry.tmp.$$" 2>/dev/null \
    || ! mv -f -- "$entry.tmp.$$" "$entry" 2>/dev/null; then
    rm -f -- "$entry.tmp.$$"
    echo "cannot write the ship checks registry entry $entry"
    return 1
  fi
  return 0
}

cmd_unregister() {
  local entry
  [ "$#" -eq 2 ] || die_usage "unregister needs <state-dir> <task-id>"
  entry=$(ship_registry_entry "$1" "$2") || return 0
  rm -f -- "$entry"
}

# 0 when the run at <head> carries the ship branch <tip>'s own commits: the
# commits <tip> has beyond every origin remote-tracking ref except the branch's
# own, present as the same commits (<tip> is an ancestor of <head>) or, after a
# pipeline rebase, each as a run-own commit with the same author email, author
# date, and subject, or with the same patch. A rebase keeps the first even when
# it shifts a patch's context or resolves a conflict. A branch with no commits of its own never binds, so a long-merged
# branch whose tip sits in the base cannot claim an unrelated run.
run_carries_ship() {  # <worktree> <head> <tip> <branch>
  local wt=$1 head=$2 tip=$3 branch=$4 own run_own pids keys key c pid matched=0
  own=$(git -C "$wt" rev-list --no-merges "$tip" --not --exclude="refs/remotes/origin/$branch" --remotes=origin 2>/dev/null) || return 1
  [ -n "$own" ] || return 1
  git -C "$wt" merge-base --is-ancestor "$tip" "$head" 2>/dev/null && return 0
  [ "$(printf '%s\n' "$own" | wc -l)" -le 200 ] || return 1
  run_own=$(git -C "$wt" rev-list --no-merges --max-count=400 "$head" --not --exclude="refs/remotes/origin/$branch" --remotes=origin 2>/dev/null) || return 1
  [ -n "$run_own" ] || return 1
  pids=$(printf '%s\n' "$run_own" | while IFS= read -r c; do
    git -C "$wt" diff-tree -p "$c" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}'
  done)
  keys=$(printf '%s\n' "$run_own" | while IFS= read -r c; do
    git -C "$wt" show -s --format='%ae %at %s' "$c" 2>/dev/null
  done)
  while IFS= read -r c; do
    key=$(git -C "$wt" show -s --format='%ae %at %s' "$c" 2>/dev/null)
    if [ -n "$key" ] && printf '%s\n' "$keys" | grep -qxF -- "$key"; then
      matched=1
      continue
    fi
    pid=$(git -C "$wt" diff-tree -p "$c" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')
    [ -n "$pid" ] || continue
    printf '%s\n' "$pids" | grep -qxF -- "$pid" || return 1
    matched=1
  done <<EOF
$own
EOF
  [ "$matched" -eq 1 ]
}

cmd_gate() {
  local registry wt head entry state id meta branch tip admitted actual record filtered out rc
  local bound=0 failed=0 skipped sid line
  [ "$#" -eq 0 ] || die_usage "gate takes no arguments"
  # shellcheck source=bin/fm-dod-lib.sh
  . "$SCRIPT_DIR/fm-dod-lib.sh"
  registry=$(ship_registry_dir)
  if ! wt=$(git rev-parse --show-toplevel 2>/dev/null) || ! head=$(git -C "$wt" rev-parse --verify -q 'HEAD^{commit}'); then
    echo "task-checks: $(pwd) is not a git worktree with a commit, so no run can be bound to a ship"
    return 1
  fi
  scratch
  for entry in "$registry"/*.ship; do
    [ -f "$entry" ] || continue
    state=$(sed -n 's/^state=//p' "$entry" | head -n 1)
    id=$(sed -n 's/^id=//p' "$entry" | head -n 1)
    meta="$state/$id.meta"
    [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || continue
    [ -n "$(fm_dod_meta_value "$meta" checks)" ] || continue
    branch=$(fm_dod_meta_value "$meta" branch)
    [ -n "$branch" ] || continue
    tip=$(git -C "$wt" rev-parse --verify -q "refs/heads/$branch^{commit}" 2>/dev/null) || continue
    run_carries_ship "$wt" "$head" "$tip" "$branch" || continue
    bound=$((bound + 1))
    echo "task-checks: task $id ($branch)"
    record="$state/$id.checks.json"
    admitted=$(fm_dod_meta_value "$meta" checks_sha)
    actual=$(fm_dod_file_sha256 "$record")
    if [ -z "$admitted" ] || [ -z "$actual" ] || [ "$actual" != "$admitted" ]; then
      echo "fail admitted-record: $record has digest ${actual:-<missing>}, not the checks_sha=${admitted:-<none>} spawn recorded, so its checks are not the ones admitted at launch"
      failed=$((failed + 1))
      continue
    fi
    filtered="$SCRATCH/gate.$bound.json"
    if ! jq '.checks |= map(select(.type != "assertions"))' "$record" > "$filtered" 2>/dev/null; then
      echo "fail admitted-record: $record cannot be read"
      failed=$((failed + 1))
      continue
    fi
    skipped=$(jq -r '.checks[] | select(.type == "assertions") | .id' "$record")
    while IFS= read -r sid; do
      [ -z "$sid" ] || echo "skip $sid: an assertions check reads the drive run the worker's done line names, so the done gate runs it"
    done <<EOF
$skipped
EOF
    rc=0
    out=$(bash "$SCRIPT_DIR/fm-checks.sh" run "$filtered" --head "$wt" 2>&1) || rc=$?
    while IFS= read -r line; do
      printf '%s\n' "$line"
      case "$line" in
        'fail '*:*)
          sid=${line#fail }
          sid=${sid%%:*}
          jq -r --arg id "$sid" '.checks[] | select(.id == $id) | "  from: " + .source' "$filtered" 2>/dev/null ;;
      esac
    done <<EOF
$out
EOF
    [ "$rc" -eq 0 ] || failed=$((failed + 1))
  done
  if [ "$bound" -eq 0 ]; then
    echo "task-checks: no registered Firstmate ship matches this run, so there are no task checks to run"
    return 0
  fi
  if [ "$failed" -gt 0 ]; then
    echo "task-checks: the change fails its task's admitted checks; they were written from the captain's words before the work began and are fixed, so change the work until they pass"
    return 1
  fi
  return 0
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  validate) shift; cmd_validate "$@"; exit $? ;;
  run) shift; cmd_run "$@"; exit $? ;;
  drive-results) shift; cmd_drive_results "$@"; exit $? ;;
  register) shift; cmd_register "$@"; exit $? ;;
  unregister) shift; cmd_unregister "$@"; exit $? ;;
  gate) shift; cmd_gate "$@"; exit $? ;;
  '') die_usage "missing command" ;;
  *) die_usage "unknown command $1" ;;
esac

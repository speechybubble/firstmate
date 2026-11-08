#!/usr/bin/env bash
# fm-checks.sh - single owner of task intake checks: the check format a brief's
# `## Checks` slot carries, the validator that admits a check only when it
# passes its known-good example and fails its known-bad one, the runner the
# done gate uses on the actual deliverable, and the drive assertion-results
# format a page deliverable's drive= evidence must hold.
#
# Usage:
#   fm-checks.sh validate <brief> --kind <ship|scout> [--root <dir>] [--admit <file>]
#   fm-checks.sh run <admitted-file> (--head <worktree> | --dir <dir>) [--drive <file>] [--digest <sha256>] [--cache <file>]
#   fm-checks.sh drive-results <file>
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
# Unknown fields are refused, so a misspelled field is never silently ignored.
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
# --digest <sha256> is the admitted record's digest the caller verified; it
# keys the cache too, so a result written for any other record is never reused.
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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

FM_CHECKS_COMMAND_TIMEOUT=60
FM_CHECKS_EXEMPTION='routine: no checks'

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

# Run one check (compact JSON) on <target>, a materialized file or, for an
# assertions check, the drive results path (possibly empty). Prints the reason
# on failure. Exit 0 pass, 1 fail, 2 the check itself cannot run.
run_check() {  # <check-json> <target>
  local check=$1 target=$2 type pattern rc out run path equals key field key_field want work
  type=$(jq -r '.type' <<<"$check")
  case "$type" in
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
       "assertions": ["assertions"]}[$t];
    def may($t): need($t) + (if $t == "tsv-field" then ["key_field"] else [] end);
    def common: ["id", "source", "type", "target", "good", "good_file", "bad", "bad_file"];
    def nonempty: type == "string" and test("\\S");
    def problems($c):
      if ($c | type) != "object" then ["is not a JSON object"]
      else
        ($c.type // "") as $t
        | [
          (if ($c.id | type) == "string" and ($c.id | test("^[a-z0-9][a-z0-9-]*$")) then empty
           else "id must be lowercase letters, digits, and dashes" end),
          (if ($c.source | nonempty) then empty else "source must name the words or rule the check comes from" end),
          (if need($t) == null then "type must be one of contains, not-contains, command, json-field, tsv-field, assertions"
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
              elif $kind == "ship" then "a ship check needs a target path in the committed tree"
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

cmd_validate() {
  local brief='' kind='' root='' admit='' body block tmp array lines line tag idx label why check id
  local admitted=0 invalid=0 out rc good bad admitted_json='[]'
  [ "$#" -gt 0 ] || die_usage "validate needs a brief"
  brief=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || die_usage "--kind needs a value"; kind=$2; shift 2 ;;
      --root) [ "$#" -ge 2 ] || die_usage "--root needs a value"; root=$2; shift 2 ;;
      --admit) [ "$#" -ge 2 ] || die_usage "--admit needs a file"; admit=$2; shift 2 ;;
      *) die_usage "unknown validate argument $1" ;;
    esac
  done
  case "$kind" in ship|scout) ;; *) die_usage "--kind must be ship or scout" ;; esac
  [ -f "$brief" ] && [ -r "$brief" ] || die_usage "brief $brief is not a readable file"
  if ! fm_brief_task_heading_present "$brief" "## Checks"; then
    echo "invalid: $brief has no ## Checks subsection"
    return 1
  fi
  body=$(fm_brief_task_heading_body "$brief" "## Checks")
  if printf '%s\n' "$body" | grep -q "^[[:space:]]*$FM_CHECKS_EXEMPTION"; then
    lines=$(printf '%s\n' "$body" | grep -c -v -e '^[[:space:]]*$')
    why=$(printf '%s\n' "$body" | sed -n "s/^[[:space:]]*$FM_CHECKS_EXEMPTION - //p" | head -n 1)
    if [ "$lines" -ne 1 ] || [ -z "$(printf '%s' "$why" | tr -d '[:space:]')" ]; then
      echo "invalid: ## Checks must be exactly one line \`$FM_CHECKS_EXEMPTION - <reason>\` when it is exempt"
      return 1
    fi
    [ -z "$admit" ] || rm -f -- "$admit"
    echo "exempt: $why"
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
      | if .type != "assertions" and (has("target") | not) and $kind == "scout" then .target = "report.md" else . end
      | if .type == "tsv-field" and (has("key_field") | not) then .key_field = 1 else . end
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
  echo "checks: $admitted admitted, $invalid invalid"
  [ "$invalid" -eq 0 ] || return 1
  if [ -n "$admit" ]; then
    tmp="$admit.tmp.$$"
    if ! jq -n --arg kind "$kind" --arg root "$root" --argjson checks "$admitted_json" \
      '{version: 1, kind: $kind, checks: $checks} + (if $kind == "scout" then {root: $root} else {} end)' > "$tmp" \
      || ! mv -f -- "$tmp" "$admit"; then
      rm -f -- "$tmp"
      echo "invalid: the admitted checks could not be written to $admit"
      return 1
    fi
  fi
  return 0
}

hash_file() {  # <file>
  git hash-object --no-filters -- "$1" 2>/dev/null || echo missing
}

cmd_run() {
  local record='' head='' dir='' drive='' digest='' cache='' root n i check id target type path out rc
  local passed=0 failed=0 result fingerprint
  [ "$#" -gt 0 ] || die_usage "run needs an admitted checks file"
  record=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) [ "$#" -ge 2 ] || die_usage "--head needs a worktree"; head=$2; shift 2 ;;
      --dir) [ "$#" -ge 2 ] || die_usage "--dir needs a directory"; dir=$2; shift 2 ;;
      --drive) [ "$#" -ge 2 ] || die_usage "--drive needs a file"; drive=$2; shift 2 ;;
      --digest) [ "$#" -ge 2 ] || die_usage "--digest needs a sha256"; digest=$2; shift 2 ;;
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
  { printf 'admitted %s\n' "$digest"; hash_file "$record"; printf 'drive %s\n' "$drive"; } > "$fingerprint"
  while [ "$i" -lt "$n" ]; do
    check=$(jq -c --argjson i "$i" '.checks[$i]' "$record")
    type=$(jq -r '.type' <<<"$check")
    target="$SCRATCH/target.$i"
    if [ "$type" = assertions ]; then
      [ -z "$drive" ] || hash_file "$drive" >> "$fingerprint"
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
    elif [ -f "$SCRATCH/target.$i" ]; then
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
    fi
    i=$((i + 1))
  done
  echo "checks: $passed passed, $failed failed" >> "$result"
  rc=0
  [ "$failed" -eq 0 ] || rc=1
  if [ -n "$cache" ]; then
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

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  validate) shift; cmd_validate "$@"; exit $? ;;
  run) shift; cmd_run "$@"; exit $? ;;
  drive-results) shift; cmd_drive_results "$@"; exit $? ;;
  '') die_usage "missing command" ;;
  *) die_usage "unknown command $1" ;;
esac

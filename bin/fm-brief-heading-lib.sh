# shellcheck shell=bash
# Brief heading reader.
# Usage: . bin/fm-brief-heading-lib.sh
#
# This file is the single owner of how a brief's sections are read: the
# `# Task` subsections bin/fm-brief.sh scaffolds feed the no-mistakes
# `--intent` contract in bin/fm-dod-lib.sh, spawn and promotion validation,
# and the task text bin/fm-dispatch-resolve.sh sends to the router, so every
# consumer sees the same section bodies.

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; own mode stops at the
# next unfenced heading of any level, leaving out nested subsections; present
# mode reports whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|own|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" != present ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && (level <= target_level || mode == "own") && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" body <<<"$task"
}

# Like fm_brief_task_heading_body, without nested subsections.
fm_brief_task_heading_own_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" own <<<"$task"
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" present >/dev/null <<<"$task"
}

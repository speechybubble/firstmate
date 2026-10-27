#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--json]

Render a human fleet view from fm-fleet-snapshot.sh.
Use --json to print the underlying snapshot.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; exit $? ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq not found" >&2; exit 1; }

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?

printf '%s\n' "$SNAPSHOT" | jq -r '
  def dash($v): if $v == null or $v == "" then "-" else $v end;
  def endpoint_exists($t):
    if $t.endpoint.exists == null then "unknown"
    elif $t.endpoint.exists then "present"
    else "absent" end;
  def endpoint_of($t):
    if $t.kind == "secondmate" then "\(endpoint_exists($t)) / \($t.endpoint.agent_alive)"
    else endpoint_exists($t) end;
  def artifact($t):
    if $t.pr.url != null then $t.pr.url
    elif $t.paths.report.present then $t.paths.report.path
    else "-" end;
  def path_of($t):
    if $t.paths.home.present then $t.paths.home.path
    elif $t.paths.home.path != null then $t.paths.home.path + " (absent)"
    elif $t.paths.worktree.present then $t.paths.worktree.path
    elif $t.paths.worktree.path != null then $t.paths.worktree.path + " (absent)"
    else "-" end;
  def action_of($t):
    if $t.kind == "secondmate" then "\($t.actions.send) - \($t.actions.watch)"
    else $t.actions.watch end;
  def task_row($t):
    "| \($t.id) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
  def blocker($r):
    if ($r.blocked_by // "") == "" then "-"
    elif ($r.blocked_reason // "") == "" then $r.blocked_by
    else "\($r.blocked_by) - \($r.blocked_reason)" end;
  def age_text($s):
    if $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 86400 then "\($s / 3600 | floor)h"
    else "\($s / 86400 | floor)d \(($s % 86400) / 3600 | floor)h" end;
  def helper_cleanup($h):
    if $h.scope == "orphan" then "bin/fm-browser-sessions.sh stop \($h.task_id)"
    elif $h.scope == "other_home" then "owned by \(dash($h.fm_home)); left alone"
    else "no task id; left alone" end;
  def helper_row($h):
    "| \(dash($h.task_id)) | \($h.scope) | \($h.session) | \(age_text($h.age_seconds)) | \($h.rss_kb / 1024 | floor) MB | \($h.pid) | \(helper_cleanup($h)) |";
  def backlog_row($r):
    "| \($r.id // "-") | \(dash($r.title // $r.raw)) | \(dash($r.repo)) | \(dash($r.kind)) | \(blocker($r)) | \(dash($r.pr_url // $r.report_path // $r.local_note)) |";

  ([.tasks[] | select(.lifecycle.state == "completed_retained")]) as $retained
  | .tasks |= map(select(.lifecycle.state != "completed_retained"))
  | "# Fleet View",
  "",
  "Schema: \(.schema)",
  "Home: \(.fm_home)",
  "",
  "## Under Way",
  (if (.tasks | length) == 0 then
    "No live task metadata found."
   else
    "| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | task_row(.))
   end),
  "",
  "## Completed retained",
  ($retained[] | "- \(.id): \(.lifecycle.source)"),
  "",
  "## Queued",
  (if ([.backlog.records[]? | select(.state == "queued")] | length) == 0 then
    "No queued backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "queued") | backlog_row(.))
   end),
  "",
  "## Done",
  (if ([.backlog.records[]? | select(.state == "done")] | length) == 0 then
    "No done backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "done") | backlog_row(.))
   end),
  "",
  "## Browser helpers",
  (.browser_helpers // {supported:null,helpers:[]}) as $bh
  | ([$bh.helpers[]? | select(.scope != "live_task")]) as $stray
  | ([$bh.helpers[]? | select(.scope == "live_task")] | length) as $live
  | if $bh.supported == null then
      "Browser helper listing unavailable."
    elif $bh.supported == false then
      "Browser helpers cannot be listed on this platform."
    elif ($stray | length) == 0 then
      "No orphaned browser helpers (\($live) in use by live tasks)."
    else
      "\($live) in use by live tasks; these belong to no live task of this home:",
      "",
      "| Task | Scope | Session | Age | Memory | PID | Cleanup |",
      "| --- | --- | --- | --- | --- | --- | --- |",
      ($stray[] | helper_row(.))
    end,
  "",
  "## Secondmates",
  .secondmate_guidance.note
'

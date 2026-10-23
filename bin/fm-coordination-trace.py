#!/usr/bin/env python3
# fm-coordination-trace.py - the read-only engine behind bin/fm-coordination-trace.sh.
#
# Reconstructs, from raw records only, how each piece of routed work travelled
# between the captain, this (main) firstmate home, one second mate and that
# mate's workers, and how many copies of each result came back to main. Every
# input is read and nothing is written except the optional --json dump. The
# second mate's home is another firstmate's private state and is only read.
#
# Records read (main state dir = $FM_STATE_OVERRIDE or $FM_HOME/state):
#   <mate>.status                  parent channel the mate and its scripts append to
#   <mate>.inbox/handled/*.msg     every main->mate steer; mv into handled/ is the
#                                  mate's acknowledgement (file ctime = ack time)
#   <mate>.inbox/*.msg             steers not yet acknowledged
#   pending-replies/<corr>         parent-owned marked-request records
#   branch-outcomes.jsonl          one row per wake the supervision host handled;
#                                  statusEndpoint dates untimestamped status lines
#   request-intake/<session>.jsonl native captain-input dispositions (task ids and
#                                  the captain message uuid) and outcome-stage acks
#   <task>.status                  main's own workers (duplicate-result count)
#   <mate-home>/state/<task>.status, <task>.meta   the mate's workers
#   <mate-home>/state/branch-outcomes.jsonl        wakes the mate handled
#   <mate-home>/data/<task>/brief.md               spawn-time fallback (mtime)
#   <transcript-dir>/<session>.jsonl               timestamps for captain uuids and
#                                                  transcript line numbers that the
#                                                  intake record points at, and the
#                                                  primary's completed replies
#
# Hop definitions (all epochs UTC):
#   ask        captain message (uuid from the intake disposition -> transcript ts);
#              a steer belongs to the captain input whose handling window holds
#              it, from that message until the next captain input (two hours at
#              most)
#   main_reply the primary's first completed reply after the ask (captain-visible
#              wait)
#   route      first main->mate steer about the task (inbox record at=)
#   mate_ack   that steer moved into handled/ (ctime)
#   spawn      worker's first status line [at=]; fallback brief.md mtime (the mate
#              writes the brief seconds before spawning, but a later edit moves
#              it), then the mate's first wake row for the task
#   worker_end worker's last done/failed line [at=]; fallback the mate's last
#              wake row for the worker's status (the file is gone after cleanup)
#   fact_line  the last child-outcome line scripts append to main's parent
#              channel for the task [at=]
#   fact_row   the main wake row that presented fact_line (epoch)
#   fact_ack   main's outcome-ack covering fact_row (intake outcome-stage -> ts),
#              only when the row's verdict was captain and within a day
#   mate_line  the mate's own done/failed [key=<task>] judgement line following
#              fact_line, dated by the main wake row that presented it
# Note that mate_ack is the mate's acknowledgement of the steer, which the mate
# records at the end of its handling turn, so spawn normally precedes it.
# A result event is one child-outcome line (one worker done or failed line).
# Copies per result = parent-channel lines about the task's results that reached
# main (child-outcome lines, the mate's own done/failed judgement lines and
# PR-ready lines) divided by result events; supervision turns per result is the
# number of distinct main wake rows that presented those lines divided by result
# events (each row is one supervision turn).
# A captain change is one captain input whose handling turn (from the captain
# message to the intake disposition record) sent at least one steer about the
# task; messages per change = steers attributed to the task divided by changes.
# route_burst counts the steers about the task sent within ten minutes of its
# first steer, which is where a second message about the same handoff shows.
#
# Attribution of a steer to a task: the mate's parent-channel line carrying the
# steer's corr= id names the task in [key=<task>]; failing that the steer body
# names a task that has a brief or status file in the mate home. Unattributed
# steers are counted separately.
#
# Output: text (default), --json <file> dumps everything, --markdown prints the
# per-task and per-edge tables as Markdown. Fallbacks actually used are listed
# at the end of every run so a reader knows which numbers rest on mtimes.
"""Read-only coordination trace between main firstmate, one second mate and workers."""

from __future__ import annotations

import argparse
import bisect
import calendar
import json
import os
import re
import statistics
import sys
import time
from collections import defaultdict
from pathlib import Path

CORR_RE = re.compile(r"corr=([0-9a-f]{16})")
KEY_RE = re.compile(r"^(done|failed|working|paused|needs-decision|blocked|resolved|note|ready)"
                    r" \[key=([a-z0-9][a-z0-9-]*)\]")
AT_RE = re.compile(r"\[at=(\d{9,11})\]")
FACT_RE = re.compile(r"^(done|failed) \[key=child-outcome-([a-z0-9][a-z0-9-]*)-(done|failed)-[0-9a-f]{8}\]")
PR_READY_RE = re.compile(r"^(ready|done) \[key=(?:child-pr|merged)-([a-z0-9][a-z0-9-]*)\]")
TERMINAL_RE = re.compile(r"^(done|failed)\b")
HANDOFF_TEXT = "New routed work is in your backlog"
REPOST_TEXT = "REPOST REQUIRED"


def iso(epoch):
    if epoch is None:
        return "-"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(epoch))


def hms(seconds):
    if seconds is None:
        return "-"
    seconds = int(seconds)
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    if seconds < 60:
        return f"{sign}{seconds}s"
    if seconds < 3600:
        return f"{sign}{seconds // 60}m{seconds % 60:02d}s"
    return f"{sign}{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


def parse_ts(ts):
    """ISO-8601 Z timestamp -> epoch seconds (float)."""
    if not ts:
        return None
    try:
        base, _, frac = ts.replace("Z", "").partition(".")
        epoch = calendar.timegm(time.strptime(base, "%Y-%m-%dT%H:%M:%S"))
        return epoch + (float("0." + frac) if frac else 0.0)
    except ValueError:
        return None


class Fallbacks:
    def __init__(self):
        self.notes = []

    def add(self, note):
        if note not in self.notes:
            self.notes.append(note)


# --- record loaders ---------------------------------------------------------

def load_outcome_rows(path):
    rows = []
    if not path.is_file():
        return rows
    with path.open("rb") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                rows.append(json.loads(raw))
            except ValueError:
                continue
    rows.sort(key=lambda r: r.get("seq", 0))
    return rows


def load_status_lines(path, rows, status_name):
    """Return list of dicts {end, text, at, row_epoch, row_seq} for one status
    file, dating untimestamped lines by the first wake row whose statusEndpoint
    reaches past the line's end and whose wake named this status file."""
    out = []
    if not path.is_file():
        return out
    data = path.read_bytes()
    wake_rows = [r for r in rows
                 if status_name in str(r.get("wake", "")) and isinstance(r.get("statusEndpoint"), int)]
    wake_rows.sort(key=lambda r: (r["statusEndpoint"], r.get("seq", 0)))
    endpoints = [r["statusEndpoint"] for r in wake_rows]
    offset = 0
    for raw in data.split(b"\n"):
        end = offset + len(raw) + 1
        offset = end
        if not raw:
            continue
        text = raw.decode("utf-8", "replace")
        m = AT_RE.search(text)
        at = int(m.group(1)) if m else None
        idx = bisect.bisect_left(endpoints, end)
        row = wake_rows[idx] if idx < len(wake_rows) else None
        out.append({
            "end": end,
            "text": text,
            "at": at,
            "row_epoch": row.get("epoch") if row else None,
            "row_seq": row.get("seq") if row else None,
            "row_verdict": row.get("verdict") if row else None,
        })
    return out


def load_inbox(state, mate, since_epoch):
    """All main->mate steer records, handled or pending."""
    recs = []
    base = state / f"{mate}.inbox"
    for sub, acked in ((base / "handled", True), (base, False)):
        if not sub.is_dir():
            continue
        for f in sorted(sub.glob("*.msg")):
            try:
                text = f.read_text("utf-8", "replace")
            except OSError:
                continue
            header, _, body = text.partition("\n--\n")
            fields = dict(line.split("=", 1) for line in header.splitlines() if "=" in line)
            at_field = fields.get("at", "")
            written = parse_ts(at_field) if at_field else None
            st = f.stat()
            if written is None:
                written = st.st_mtime
            if written < since_epoch:
                continue
            corrs = CORR_RE.findall(body)
            kind = "ordinary"
            if HANDOFF_TEXT in body:
                kind = "handoff-wake"
            elif REPOST_TEXT in body:
                kind = "repost"
            elif fields.get("delivery") == "fire-and-forget" or "delivery=" in body.split("\n", 1)[0]:
                kind = "fire-and-forget"
            recs.append({
                "id": f.stem,
                "written": written,
                "acked": st.st_ctime if acked else None,
                "pending": not acked,
                "kind": kind,
                "corrs": corrs,
                "body": body.strip(),
            })
    recs.sort(key=lambda r: r["written"])
    return recs


def load_pending_replies(state):
    out = {}
    d = state / "pending-replies"
    if not d.is_dir():
        return out
    for f in d.iterdir():
        if not f.is_file():
            continue
        rec = {}
        for line in f.read_text("utf-8", "replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                rec[k] = v
        out[f.name] = rec
    return out


def load_intake(state):
    """All request-intake records across sessions: dispositions and outcome stages."""
    dispositions, stages = [], []
    d = state / "request-intake"
    if not d.is_dir():
        return dispositions, stages
    for f in sorted(d.glob("*.jsonl")):
        session = f.stem
        for raw in f.read_text("utf-8", "replace").splitlines():
            try:
                rec = json.loads(raw)
            except ValueError:
                continue
            rec["session"] = session
            if rec.get("type") == "disposition":
                dispositions.append(rec)
            elif rec.get("type") == "outcome-stage":
                stages.append(rec)
    return dispositions, stages


class Transcript:
    """uuid -> timestamp and line -> timestamp for one primary session."""

    def __init__(self, path):
        self.by_uuid = {}
        self.by_line = {}
        self.replies = []
        self.first_ts = None
        self.ok = path.is_file()
        if not self.ok:
            return
        with path.open("rb") as fh:
            for n, raw in enumerate(fh, 1):
                m = re.search(rb'"timestamp":"([0-9T:.Z-]+)"', raw)
                if not m:
                    continue
                ts = parse_ts(m.group(1).decode())
                if self.first_ts is None:
                    self.first_ts = ts
                self.by_line[n] = ts
                u = re.search(rb'"uuid":"([0-9a-f-]{36})"', raw)
                if u and b'"type":"user"' in raw:
                    self.by_uuid[u.group(1).decode()] = ts
                elif b'"stop_reason":"end_turn"' in raw and b'"type":"assistant"' in raw:
                    self.replies.append(ts)

    def reply_after(self, epoch):
        """The primary's first completed reply after an epoch."""
        i = bisect.bisect_right(self.replies, epoch)
        return self.replies[i] if i < len(self.replies) else None

    def line_ts(self, line):
        """Timestamp at or just after a transcript line number."""
        if line in self.by_line:
            return self.by_line[line]
        later = [n for n in self.by_line if n >= line]
        return self.by_line[min(later)] if later else None


# --- tracing ----------------------------------------------------------------

def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def worst(values):
    values = [v for v in values if v is not None]
    return max(values) if values else None


def trace(args):
    fb = Fallbacks()
    state = Path(args.state)
    mate = args.mate
    mate_home = Path(args.mate_home)
    since_epoch = parse_ts(args.since + "T00:00:00Z")

    main_rows = load_outcome_rows(state / "branch-outcomes.jsonl")
    mate_rows = load_outcome_rows(mate_home / "state" / "branch-outcomes.jsonl")
    channel = load_status_lines(state / f"{mate}.status", main_rows, f"{mate}.status")
    inbox = load_inbox(state, mate, since_epoch)
    pending = load_pending_replies(state)
    dispositions, stages = load_intake(state)

    transcripts = {}
    tdir = Path(args.transcript_dir) if args.transcript_dir else None
    if tdir and tdir.is_dir():
        for session in {d["session"] for d in dispositions} | {s["session"] for s in stages}:
            transcripts[session] = Transcript(tdir / f"{session}.jsonl")
    else:
        fb.add("no transcript directory: captain ask times and main ack times unavailable")

    # Known mate tasks: data/<task>/brief.md directories plus status files.
    named = set()
    for p in (mate_home / "data").glob("*/brief.md"):
        named.add(p.parent.name)
    for p in (mate_home / "state").glob("*.status"):
        named.add(p.stem)
    known = set(named)
    for r in mate_rows:
        t = r.get("task")
        if t and f"{t}.status" in str(r.get("wake", "")):
            known.add(t)

    # corr -> task via the mate's keyed parent-channel lines.
    corr_task = {}
    for ln in channel:
        km = KEY_RE.match(ln["text"])
        if not km:
            continue
        for c in CORR_RE.findall(ln["text"]):
            corr_task.setdefault(c, km.group(2))

    # Attribute steers.
    steers_by_task = defaultdict(list)
    unattributed = []
    for rec in inbox:
        task = None
        for c in rec["corrs"]:
            if c in corr_task:
                task = corr_task[c]
                break
        if task is None:
            names = [t for t in named if re.search(r"(?<![a-z0-9-])" + re.escape(t) + r"(?![a-z0-9-])", rec["body"])]
            if len(names) == 1:
                task = names[0]
            elif names:
                task = max(names, key=len)
        rec["task"] = task
        if task:
            steers_by_task[task].append(rec)
        else:
            unattributed.append(rec)

    # Captain inputs: each disposition gives a handling window from the captain
    # message (uuid timestamp) to the disposition record (transcript line); a
    # steer written inside that window was sent while handling that input.
    windows = []
    for d in dispositions:
        tr = transcripts.get(d["session"])
        if not (tr and tr.ok):
            continue
        start = tr.by_uuid.get(d.get("id"))
        end = tr.line_ts(d["at"]) if isinstance(d.get("at"), int) else None
        if start is None or end is None or end < start:
            continue
        windows.append({"start": start, "end": end, "id": d.get("id"), "tasks": d.get("tasks") or [],
                        "summary": d.get("summary", ""), "session": d["session"]})
    windows.sort(key=lambda w: w["start"])
    # Main keeps working on an input for a while after recording its
    # disposition, so the handling window runs ten minutes past that record,
    # never into the next captain input.
    for i, w in enumerate(windows):
        nxt = windows[i + 1]["start"] if i + 1 < len(windows) else w["end"] + 600
        w["end"] = max(w["start"], min(nxt, w["end"] + 600))
        tr = transcripts.get(w["session"])
        w["reply"] = tr.reply_after(w["start"]) if tr else None

    def window_for(epoch):
        hits = [w for w in windows if w["start"] <= epoch <= w["end"]]
        return max(hits, key=lambda w: w["start"]) if hits else None

    if not windows and dispositions:
        fb.add("intake dispositions exist but no transcript matched them: captain ask times unavailable")

    first_staged = min((s["through"] for s in stages if isinstance(s.get("through"), int)), default=None)

    def ack_time_for_row(seq):
        best = None
        if first_staged is None or seq <= first_staged:
            return None
        for s in stages:
            if isinstance(s.get("through"), int) and s["through"] >= seq:
                tr = transcripts.get(s["session"])
                ts = tr.line_ts(s["at"]) if (tr and tr.ok and isinstance(s.get("at"), int)) else None
                if ts is not None and (best is None or ts < best):
                    best = ts
        return best

    # Parent-channel result lines by task.
    fact_lines = defaultdict(list)
    mate_lines = defaultdict(list)
    pr_lines = defaultdict(list)
    for ln in channel:
        fm = FACT_RE.match(ln["text"])
        if fm:
            fact_lines[fm.group(2)].append(ln)
            continue
        pm = PR_READY_RE.match(ln["text"])
        if pm:
            pr_lines[pm.group(2)].append(ln)
            continue
        km = KEY_RE.match(ln["text"])
        if km and km.group(1) in ("done", "failed") and "corr=" in ln["text"]:
            mate_lines[km.group(2)].append(ln)

    # Mate worker records.
    def worker_bounds(task):
        spawn = end = None
        spawn_src = end_src = None
        lines = load_status_lines(mate_home / "state" / f"{task}.status", mate_rows, f"{task}.status")
        if lines:
            first = lines[0]
            spawn, spawn_src = first["at"], "worker first status line"
            if spawn is None:
                spawn, spawn_src = first["row_epoch"], "mate wake row for the worker's first line"
            for ln in lines:
                if TERMINAL_RE.match(ln["text"]):
                    end, end_src = ln["at"], "worker terminal line"
                    if end is None:
                        end, end_src = ln["row_epoch"], "mate wake row for the worker's terminal line"
        brief = mate_home / "data" / task / "brief.md"
        if spawn is None and brief.is_file():
            spawn, spawn_src = brief.stat().st_mtime, "brief.md mtime"
        task_rows = [r for r in mate_rows if r.get("task") == task]
        if spawn is None and task_rows:
            spawn, spawn_src = task_rows[0].get("epoch"), "mate's first wake row for the task"
        if end is None:
            status_rows = [r for r in task_rows if f"{task}.status" in str(r.get("wake", ""))]
            if status_rows:
                end, end_src = status_rows[-1].get("epoch"), "mate's last wake row for the worker's status (file gone)"
        if spawn_src and spawn_src != "worker first status line":
            fb.add(f"spawn time fallback used: {spawn_src}")
        if end_src and end_src != "worker terminal line":
            fb.add(f"worker end fallback used: {end_src}")
        return spawn, end, spawn_src, end_src, len(task_rows)

    tasks = set(fact_lines) | set(mate_lines) | set(steers_by_task)
    tasks = {t for t in tasks if t in known or t in fact_lines or t in mate_lines}
    per_task = []
    for task in sorted(tasks):
        facts = fact_lines.get(task, [])
        mates = mate_lines.get(task, [])
        prs = pr_lines.get(task, [])
        spawn, wend, spawn_src, end_src, mate_wakes = worker_bounds(task)
        steers = steers_by_task.get(task, [])
        anchor = None
        if facts:
            anchor = facts[-1]["at"] or facts[-1]["row_epoch"]
        elif mates:
            anchor = mates[-1]["row_epoch"]
        elif wend:
            anchor = wend
        if anchor is not None and anchor < since_epoch and not steers:
            continue
        route = steers[0] if steers else None
        burst = [s_ for s_ in steers if route and s_["written"] - route["written"] <= 600]
        hit_windows = {}
        for s_ in steers:
            w = window_for(s_["written"])
            if w:
                hit_windows.setdefault(w["id"], w)
        changes = len(hit_windows)
        first_window = window_for(route["written"]) if route else None
        ask_ts = first_window["start"] if first_window else None
        main_reply = first_window["reply"] if first_window else None
        real_end = wend if end_src == "worker terminal line" else None
        fact = facts[-1] if facts else None
        fact_at = (fact["at"] or fact["row_epoch"]) if fact else None
        if fact and fact["at"] is None:
            fb.add("child-outcome line without [at=] dated by its wake row")
        fact_row_epoch = fact["row_epoch"] if fact else None
        fact_ack = None
        if fact and fact["row_seq"] and fact["row_verdict"] == "captain":
            fact_ack = ack_time_for_row(fact["row_seq"])
        main_rows_between = 0
        if fact_at and fact_row_epoch:
            main_rows_between = sum(1 for r in main_rows if fact_at < r.get("epoch", 0) < fact_row_epoch)
        mate_after = [m for m in mates if fact is None or (m["end"] > fact["end"])]
        mate_line_epoch = mate_after[0]["row_epoch"] if mate_after else None
        result_lines = facts + mates + prs
        result_rows = {ln["row_seq"] for ln in result_lines if ln["row_seq"] is not None}
        events = max(1, len(facts)) if result_lines else 0
        reposts = [s_ for s_ in steers if s_["kind"] == "repost"]
        per_task.append({
            "task": task,
            "ask": ask_ts,
            "changes": changes,
            "route": route["written"] if route else None,
            "route_kind": route["kind"] if route else None,
            "route_burst": len(burst),
            "mate_ack": route["acked"] if route else None,
            "spawn": spawn,
            "spawn_source": spawn_src,
            "worker_end": wend,
            "worker_end_source": end_src,
            "mate_wakes": mate_wakes,
            "main_reply": main_reply,
            "fact_line": fact_at,
            "fact_row": fact_row_epoch,
            "fact_verdict": fact["row_verdict"] if fact else None,
            "main_rows_between": main_rows_between,
            "fact_ack": fact_ack,
            "mate_line": mate_line_epoch,
            "steers": len(steers),
            "reposts": len(reposts),
            "messages_per_change": (len(steers) / changes) if changes else None,
            "result_events": len(facts),
            "result_lines": len(result_lines),
            "result_rows": len(result_rows),
            "copies_per_result": (len(result_lines) / events) if events else None,
            "turns_per_result": (len(result_rows) / events) if events else None,
            "edges": {
                "ask->route": (route["written"] - ask_ts) if (route and ask_ts) else None,
                "ask->main_reply": (main_reply - ask_ts) if (main_reply and ask_ts) else None,
                "route->mate_ack": (route["acked"] - route["written"]) if (route and route["acked"]) else None,
                "route->spawn": (spawn - route["written"]) if (route and spawn) else None,
                "ask->spawn": (spawn - ask_ts) if (spawn and ask_ts) else None,
                "spawn->worker_end": (wend - spawn) if (spawn and wend) else None,
                "worker_end->fact_line": (fact_at - real_end) if (fact_at and real_end) else None,
                "fact_line->fact_row": (fact_row_epoch - fact_at) if (fact_at and fact_row_epoch) else None,
                "fact_row->main_ack": (fact_ack - fact_row_epoch) if (fact_ack and fact_row_epoch) else None,
                "fact_line->mate_line": (mate_line_epoch - fact_at) if (mate_line_epoch and fact_at) else None,
            },
        })

    # Steer-level view (every main->mate record since --since).
    steer_rows = []
    for rec in inbox:
        rr = [pending.get(c) for c in rec["corrs"] if c in pending]
        resolved = [int(p["resolved_epoch"]) for p in rr if p and p.get("resolved_epoch", "").isdigit()]
        w = window_for(rec["written"])
        steer_rows.append({
            "id": rec["id"], "task": rec["task"], "kind": rec["kind"],
            "captain_input": w["id"] if w else None,
            "from_ask": (rec["written"] - w["start"]) if w else None,
            "written": rec["written"], "acked": rec["acked"], "pending": rec["pending"],
            "ack_delay": (rec["acked"] - rec["written"]) if rec["acked"] else None,
            "reply_delay": (max(resolved) - rec["written"]) if resolved else None,
            "corrs": rec["corrs"],
            "summary": re.sub(r"\s+", " ", rec["body"])[:90],
        })

    # Main-home tasks: duplicate-result count from the main store and status files.
    main_tasks = {}
    for r in main_rows:
        t = r.get("task")
        if not t or t == mate or r.get("epoch", 0) < since_epoch:
            continue
        rec = main_tasks.setdefault(t, {"task": t, "rows": 0, "status_rows": 0, "stale_rows": 0, "terminal_lines": None})
        rec["rows"] += 1
        wake = str(r.get("wake", ""))
        if f"{t}.status" in wake:
            rec["status_rows"] += 1
        if wake.startswith("stale"):
            rec["stale_rows"] += 1
    for t, rec in main_tasks.items():
        sf = state / f"{t}.status"
        if sf.is_file():
            rec["terminal_lines"] = sum(1 for l in sf.read_text("utf-8", "replace").splitlines() if TERMINAL_RE.match(l))

    # Summaries.
    edge_names = ["ask->route", "ask->main_reply", "route->mate_ack", "route->spawn", "ask->spawn", "spawn->worker_end",
                  "worker_end->fact_line", "fact_line->fact_row", "fact_row->main_ack", "fact_line->mate_line"]
    edges = {}
    for name in edge_names:
        vals = [t["edges"][name] for t in per_task]
        edges[name] = {"n": len([v for v in vals if v is not None]), "median": median(vals), "worst": worst(vals),
                       "worst_task": next((t["task"] for t in per_task if t["edges"][name] is not None and t["edges"][name] == worst(vals)), None)}
    steer_ack = [s["ack_delay"] for s in steer_rows if s["ack_delay"] is not None and s["kind"] != "fire-and-forget"]
    ff_ack = [s["ack_delay"] for s in steer_rows if s["ack_delay"] is not None and s["kind"] == "fire-and-forget"]
    repost_reply = [s_["reply_delay"] for s_ in steer_rows if s_["kind"] == "repost" and s_["reply_delay"] is not None]
    with_results = [t for t in per_task if t["result_events"]]
    with_changes = [t for t in per_task if t["changes"]]
    summary = {
        "since": args.since,
        "mate": mate,
        "routed_tasks": len(per_task),
        "tasks_with_results": len(with_results),
        "ask_to_worker_start_median": edges["ask->spawn"]["median"],
        "ask_to_worker_start_worst": edges["ask->spawn"]["worst"],
        "ask_to_worker_start_n": edges["ask->spawn"]["n"],
        "messages_per_change_mean": (sum(t["steers"] for t in with_changes) / sum(t["changes"] for t in with_changes)) if with_changes else None,
        "messages_per_change_n": len(with_changes),
        "route_burst_mean": (sum(t["route_burst"] for t in per_task if t["steers"]) / len([t for t in per_task if t["steers"]])) if any(t["steers"] for t in per_task) else None,
        "handoff_wake_burst_mean": (sum(t["route_burst"] for t in per_task if t["route_kind"] == "handoff-wake") / len([t for t in per_task if t["route_kind"] == "handoff-wake"])) if any(t["route_kind"] == "handoff-wake" for t in per_task) else None,
        "messages_total": len(steer_rows),
        "messages_attributed": sum(1 for s in steer_rows if s["task"]),
        "messages_repost": sum(1 for s in steer_rows if s["kind"] == "repost"),
        "messages_handoff_wake": sum(1 for s in steer_rows if s["kind"] == "handoff-wake"),
        "messages_fire_and_forget": sum(1 for s in steer_rows if s["kind"] == "fire-and-forget"),
        "repost_reply_median": median(repost_reply),
        "repost_reply_worst": worst(repost_reply),
        "steer_ack_median": median(steer_ack),
        "steer_ack_worst": worst(steer_ack),
        "fire_and_forget_ack_median": median(ff_ack),
        "fire_and_forget_ack_worst": worst(ff_ack),
        "result_events": sum(t["result_events"] for t in with_results),
        "copies_per_result_lines_mean": (sum(t["result_lines"] for t in with_results) / sum(t["result_events"] for t in with_results)) if with_results else None,
        "copies_per_result_rows_mean": (sum(t["result_rows"] for t in with_results) / sum(t["result_events"] for t in with_results)) if with_results else None,
        "main_tasks": len(main_tasks),
        "main_status_rows_mean": (sum(r["status_rows"] for r in main_tasks.values()) / len(main_tasks)) if main_tasks else None,
        "main_tasks_with_status_file": sum(1 for r in main_tasks.values() if r["terminal_lines"] is not None),
        "main_terminal_lines_total": sum(r["terminal_lines"] or 0 for r in main_tasks.values()),
        "main_status_rows_with_file_total": sum(r["status_rows"] for r in main_tasks.values() if r["terminal_lines"] is not None),
    }
    return {
        "summary": summary,
        "edges": edges,
        "tasks": per_task,
        "steers": steer_rows,
        "unattributed_steers": len(unattributed),
        "main_tasks": sorted(main_tasks.values(), key=lambda r: r["task"]),
        "fallbacks": fb.notes,
        "inputs": {
            "state": str(state), "mate_home": str(mate_home),
            "main_rows": len(main_rows), "mate_rows": len(mate_rows),
            "channel_lines": len(channel), "inbox_records": len(inbox),
            "pending_replies": len(pending), "dispositions": len(dispositions),
            "transcripts": sorted(s for s, t in transcripts.items() if t.ok),
        },
    }


# --- rendering ----------------------------------------------------------------

def fmt_num(v, unit="s"):
    if v is None:
        return "-"
    if unit == "s":
        return hms(v)
    return f"{v:.2f}"


def render_text(res, markdown=False):
    s, e = res["summary"], res["edges"]
    out = []
    sep = "|" if markdown else "  "
    out.append(f"fm-coordination-trace: {s['mate']} since {s['since']} "
               f"(routed tasks {s['routed_tasks']}, with results {s['tasks_with_results']})")
    out.append("")
    out.append("SUMMARY")
    out.append(f"  ask -> worker start: median {hms(s['ask_to_worker_start_median'])}, "
               f"worst {hms(s['ask_to_worker_start_worst'])} (n={s['ask_to_worker_start_n']})")
    out.append(f"  messages per captain change: {fmt_num(s['messages_per_change_mean'], '')} (n={s['messages_per_change_n']} tasks; "
               f"{s['messages_total']} steers, {s['messages_attributed']} attributed, "
               f"{s['messages_handoff_wake']} handoff wakes, {s['messages_repost']} reposts, "
               f"{s['messages_fire_and_forget']} fire-and-forget; steers in the first ten minutes per task "
               f"{fmt_num(s['route_burst_mean'], '')}, after a handoff wake {fmt_num(s['handoff_wake_burst_mean'], '')})")
    out.append(f"  copies per result at main: {fmt_num(s['copies_per_result_lines_mean'], '')} lines, "
               f"{fmt_num(s['copies_per_result_rows_mean'], '')} supervision turns ({s['result_events']} results)")
    out.append(f"  repost steers: {s['messages_repost']}, mate reply after the repost median {hms(s['repost_reply_median'])}, worst {hms(s['repost_reply_worst'])}")
    out.append(f"  steer ack: median {hms(s['steer_ack_median'])}, worst {hms(s['steer_ack_worst'])}; "
               f"fire-and-forget ack: median {hms(s['fire_and_forget_ack_median'])}, worst {hms(s['fire_and_forget_ack_worst'])}")
    out.append(f"  main-home tasks: {s['main_tasks']}, status wake rows per task {fmt_num(s['main_status_rows_mean'], '')}; "
               f"with a surviving status file: {s['main_tasks_with_status_file']} tasks, {s['main_terminal_lines_total']} terminal lines, "
               f"{s['main_status_rows_with_file_total']} status wake rows")
    out.append("")
    out.append("EDGES (median / worst / n)")
    if markdown:
        out.append("| edge | n | median | worst | worst task |")
        out.append("| --- | --- | --- | --- | --- |")
    for name, v in e.items():
        if markdown:
            out.append(f"| {name} | {v['n']} | {hms(v['median'])} | {hms(v['worst'])} | {v['worst_task'] or '-'} |")
        else:
            out.append(f"  {name:24} {hms(v['median']):>9} {hms(v['worst']):>9}  n={v['n']:<3} worst={v['worst_task'] or '-'}")
    out.append("")
    out.append("TASKS")
    cols = ["task", "ask", "route", "mate_ack", "spawn", "worker_end", "fact_line", "fact_row", "fact_ack", "mate_line",
            "steers", "changes", "reposts", "results", "copies(lines/turns)"]
    if markdown:
        out.append("| " + " | ".join(cols) + " |")
        out.append("|" + " --- |" * len(cols))
    for t in res["tasks"]:
        vals = [t["task"], iso(t["ask"]), iso(t["route"]), iso(t["mate_ack"]), iso(t["spawn"]), iso(t["worker_end"]),
                iso(t["fact_line"]), iso(t["fact_row"]), iso(t["fact_ack"]), iso(t["mate_line"]),
                str(t["steers"]), str(t["changes"]), str(t["reposts"]), str(t["result_events"]),
                f"{t['result_lines']}/{t['result_rows']}"]
        if markdown:
            out.append("| " + " | ".join(vals) + " |")
        else:
            out.append("  " + t["task"])
            for k in ("ask", "main_reply", "route", "mate_ack", "spawn", "worker_end", "fact_line", "fact_row", "fact_ack", "mate_line"):
                out.append(f"    {k:12} {iso(t[k])}" + (f"  ({t['spawn_source']})" if k == "spawn" and t["spawn_source"] else ""))
            ed = "  ".join(f"{k}={hms(v)}" for k, v in t["edges"].items() if v is not None)
            out.append(f"    edges        {ed}")
            if t["fact_line"] and t["fact_row"] and t["main_rows_between"] == 0 and t["edges"]["fact_line->fact_row"] and t["edges"]["fact_line->fact_row"] > 900:
                out.append("    note         main handled no wake at all between the result line and its row (main was idle or off)")
            out.append(f"    steers={t['steers']} (first ten minutes {t['route_burst']}) reposts={t['reposts']} changes={t['changes']} "
                       f"results={t['result_events']} copies={t['result_lines']} lines in {t['result_rows']} supervision turns, "
                       f"mate wakes={t['mate_wakes']}")
    out.append("")
    out.append("MAIN-HOME TASKS (wake rows / rows naming the status file / stale rows / terminal lines in a surviving status file)")
    for r in res["main_tasks"]:
        out.append(f"  {r['task']:40} rows={r['rows']:<4} status_rows={r['status_rows']:<3} stale_rows={r['stale_rows']:<3} "
                   f"terminal_lines={r['terminal_lines'] if r['terminal_lines'] is not None else '-'}")
    out.append("")
    out.append(f"STEERS ({len(res['steers'])} main->mate records, {res['unattributed_steers']} unattributed)")
    for st in res["steers"]:
        out.append(f"  {st['id']} {iso(st['written'])} ask+{hms(st['from_ask'])} ack+{hms(st['ack_delay']) if st['ack_delay'] is not None else 'PENDING'} "
                   f"reply+{hms(st['reply_delay'])} {st['kind']:16} {st['task'] or '-':36} {st['summary']}")
    out.append("")
    out.append("FALLBACKS USED")
    for n in res["fallbacks"] or ["none"]:
        out.append(f"  - {n}")
    i = res["inputs"]
    out.append("")
    out.append(f"INPUTS main rows {i['main_rows']}, mate rows {i['mate_rows']}, channel lines {i['channel_lines']}, "
               f"steers {i['inbox_records']}, pending replies {i['pending_replies']}, dispositions {i['dispositions']}, "
               f"transcripts {len(i['transcripts'])}")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--state", required=True, help="main home state dir")
    ap.add_argument("--mate", required=True, help="second mate id (status/inbox basename)")
    ap.add_argument("--mate-home", required=True, help="second mate home (read only)")
    ap.add_argument("--since", default="2026-10-09", help="earliest date YYYY-MM-DD (UTC)")
    ap.add_argument("--transcript-dir", default=None, help="primary harness transcript dir for captain ask times")
    ap.add_argument("--json", default=None, help="write the full result as JSON to this file")
    ap.add_argument("--markdown", action="store_true", help="render tables as Markdown")
    args = ap.parse_args(argv)
    res = trace(args)
    if args.json:
        Path(args.json).write_text(json.dumps(res, indent=1, default=float), "utf-8")
    print(render_text(res, markdown=args.markdown))
    return 0


if __name__ == "__main__":
    sys.exit(main())

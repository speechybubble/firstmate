#!/usr/bin/env python3
"""fm-quote-check.py - the captain's typed words, and the check that a page's
quotes of the captain appear in them word for word.

bin/fm-quote-check.sh owns the command line, home resolution and freshness;
this file owns what counts as the captain's typed words, how a page's quotes
are found, and what counts as a match. Run it through the wrapper.

Source (refresh). One JSON document, schema fm-captain-words.v1, holding every
message the captain typed, from two channels:

  claude   Claude Code transcripts of each home (<transcripts>/<session>.jsonl).
           An entry counts when it is a top-level `user` entry (not isMeta,
           isCompactSummary or isSidechain) whose origin kind is `human`, whose
           content is text rather than a tool result, and that carries a
           promptSource, which marks a submitted prompt; a slash command echo
           with no promptSource contributes only its typed arguments. This
           follows the captain-input rule bin/fm-request-continuity.sh owns,
           so a prompt the captain sent by accepting Claude's suggestion
           (promptSource suggestion_accepted) counts as their words, but it
           also requires the origin to be recorded as human: supervision wakes
           and the main-dialog mirror are submitted with no origin, and they
           never qualify. A prompt typed while a turn runs and absorbed into it
           is stored instead as an `attachment` entry of type queued_command;
           it counts when its commandMode is `prompt` and its origin kind is
           `human`. No entry counts that the operational-input owner
           (bin/fm-operational-input.sh) classifies as Firstmate's own input:
           envelopes, doorbells and from-firstmate steers.
  lavish   The Lavish session store, limited to sessions whose page sits inside
           one of the homes. A `message` entry is text the captain typed in the
           conversation panel. An `annotation` entry that carries a page's
           "Context data:" JSON contributes only its `note` strings, since the
           sentence around them is the page's own template; an annotation with
           no context data is the reviewer's comment and counts whole.

From every message, pasted blocks (<pasted_content>...</pasted_content>) and
<system-reminder> blocks are removed: pasted text is someone else's words.
Images and tool output never enter the source.

Limits. Text another agent types into a pane carries the same record as the
captain's typing, so it can't be told apart and counts; so does an envelope
whose invisible mark the harness stripped. Words the captain wrote anywhere
else (a notes document, a voice transcript, sessions from before the Claude
Code transcripts) are not in the source, so a quote of them is flagged.

Quotes (check). A marker names how a page marks the captain's words:

  class:<name>   the text of each HTML element whose class list holds <name>;
                 surrounding quotation marks are dropped. `class:verbatim` is
                 the default, the internal kit's box for verbatim words.
  attributed     a quoted span ("...", '...', or curly quotes) that follows a
                 cue attributing it to the captain in the same sentence: "you
                 said", "you wrote", "your words", "your transcript said", "the
                 captain said", "in your words", "your note" and close forms.
  typed          the attributed spans whose cue claims words the captain typed
                 to an agent, so every cue above except the ones naming a note
                 ("your note", "your notes", "the captain's note"): the source
                 holds no notes, so a quote of one can't be confirmed or refuted
                 here and is left out rather than flagged. This is the marker of
                 the standing check bin/fm-checks.sh runs on page deliverables.
  regex:<re>     each match of <re> in the page's visible text; the group named
                 q, else group 1, else the whole match is the quote.

Visible text is the page with tags, scripts and styles removed and entities
decoded; a Markdown or text file is read as it is.

Match. A quote matches when its words, in order and with nothing between them,
appear inside one source message. Words are compared after Unicode NFKC
folding, lower-casing and straightening curly apostrophes, and punctuation and
spacing are ignored, so a changed, added, dropped or reordered word fails while
a capital letter or a comma does not. Words inside [brackets] are ordinary
words and must match the source at their position. An ellipsis splits a quote
into parts that must each match, in order, in the same message. When the
closest such match, the one leaving out the fewest source words, still leaves
source words out between two parts, the quote is "verbatim with omissions",
flagged for review rather than passed, and those words are reported; an
ellipsis that leaves nothing out between parts (one the captain typed, or one
marking a cut at either end) is plain verbatim. A quote with no words is
skipped and reported. There is no fuzzy matching: a paraphrase is a misquote.

Nothing here prints source text beyond the words an ellipsis left out of one
quote; a check otherwise prints only the page's own quotes.
"""

import argparse
import html
import html.parser
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata

SCHEMA = "fm-captain-words.v1"
# Claude Code closes a paste as </pasted_content id="...">, so the closing tag
# may carry attributes too. An unclosed block runs to the end of the message.
STRIP_BLOCKS = re.compile(r"<(pasted_content|system-reminder)\b[^>]*>.*?(?:</\1\b[^>]*>|\Z)", re.S)
COMMAND_ECHO = re.compile(r"^\s*<command-(?:name|message)>")
COMMAND_ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.S)
CONTEXT_DATA = "\n\nContext data:\n"

# ---------------------------------------------------------------- source build


def message_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return None
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text")
    return None


def claude_candidates(transcript_dir, home):
    """Yield (text, at, ref) for each captain-typed entry in one transcript dir."""
    try:
        names = sorted(os.listdir(transcript_dir))
    except OSError:
        return
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(transcript_dir, name)
        try:
            fh = open(path, "rb")
        except OSError:
            continue
        with fh:
            for raw in fh:
                # Byte prefilter: inside a JSON string a quote is escaped, so these
                # spellings only match the entry's own fields.
                if b'"kind":"human"' not in raw or (b'"type":"user"' not in raw and b'"queued_command"' not in raw):
                    continue
                try:
                    e = json.loads(raw)
                except ValueError:
                    continue
                if e.get("isSidechain"):
                    continue
                att = e.get("attachment")
                if e.get("type") == "attachment" and isinstance(att, dict):
                    # A prompt typed while a turn runs and absorbed into it.
                    if (att.get("type") == "queued_command" and att.get("commandMode") == "prompt"
                            and (att.get("origin") or {}).get("kind") == "human"):
                        text = message_text(att.get("prompt"))
                        if text is not None:
                            yield text, e.get("timestamp", ""), "%s:%s" % (name[:-6], att.get("source_uuid") or e.get("uuid", ""))
                    continue
                if e.get("type") != "user" or e.get("isMeta") or e.get("isCompactSummary"):
                    continue
                if (e.get("origin") or {}).get("kind") != "human":
                    continue
                msg = e.get("message")
                text = message_text(msg.get("content")) if isinstance(msg, dict) else None
                if text is None:
                    continue
                if e.get("promptSource") is None:
                    if not COMMAND_ECHO.match(text):
                        continue
                    m = COMMAND_ARGS.search(text)
                    text = m.group(1) if m else ""
                yield text, e.get("timestamp", ""), "%s:%s" % (name[:-6], e.get("uuid", ""))


def note_strings(value):
    if isinstance(value, dict):
        for k, v in value.items():
            if k == "note" and isinstance(v, str):
                yield v
            else:
                yield from note_strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from note_strings(v)


def within(path, roots):
    real = os.path.realpath(path)
    return any(real == r or real.startswith(r + os.sep) for r in roots)


def lavish_candidates(state_file, homes):
    try:
        with open(state_file, encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        return
    roots = [os.path.realpath(h) for h in homes]
    for key, session in sorted((state.get("sessions") or {}).items()):
        if not isinstance(session, dict) or not within(session.get("file") or "", roots):
            continue
        for i, entry in enumerate(session.get("chat") or []):
            if not isinstance(entry, dict) or entry.get("role") != "user":
                continue
            text = entry.get("text")
            if not isinstance(text, str):
                continue
            kind = entry.get("kind")
            ref = "%s:%s" % (key, entry.get("prompt_id") or i)
            if kind == "message":
                yield text, entry.get("at", ""), ref
            elif kind == "annotation":
                if CONTEXT_DATA in text:
                    try:
                        data = json.loads(text.split(CONTEXT_DATA, 1)[1])
                    except ValueError:
                        continue
                    for note in note_strings(data):
                        yield note, entry.get("at", ""), ref
                else:
                    yield text, entry.get("at", ""), ref


def operational_indices(texts, lib):
    """Indices of texts the operational-input owner calls Firstmate's input."""
    if not texts:
        return set()
    script = r'''
. "$1" || exit 3
i=0
while IFS= read -r -d '' t; do
  if fm_operational_input_classify "$t" k || fm_operational_doorbell_path "$t" k \
     || fm_steering_doorbell_inbox "$t" k || fm_message_from_firstmate "$t"; then
    printf '%s\n' "$i"
  fi
  i=$((i + 1))
done
'''
    payload = b"".join(t.encode("utf-8", "surrogateescape") + b"\0" for t in texts)
    proc = subprocess.run(["bash", "-c", script, "fm-quote-check", lib], input=payload,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        sys.stderr.write("fm-quote-check: operational-input classifier failed: %s\n"
                         % proc.stderr.decode("utf-8", "replace").strip())
        sys.exit(2)
    return {int(x) for x in proc.stdout.split()}


def clean(text):
    return STRIP_BLOCKS.sub(" ", text).strip()


def cmd_refresh(args):
    homes = [h for h in args.home]
    raw = []  # (channel, home, text, at, ref)
    for home, tdir in zip(homes, args.transcripts):
        for text, at, ref in claude_candidates(tdir, home):
            raw.append(("claude", home, text, at, ref))
    if args.lavish_state:
        for text, at, ref in lavish_candidates(args.lavish_state, homes):
            raw.append(("lavish", "", text, at, ref))
    claude_idx = [i for i, r in enumerate(raw) if r[0] == "claude"]
    operational = operational_indices([raw[i][2] for i in claude_idx], args.operational_lib)
    dropped = {claude_idx[j] for j in operational}
    messages, counts = [], {}
    for i, (channel, home, text, at, ref) in enumerate(raw):
        if i in dropped:
            continue
        text = clean(text)
        if not words(text):
            continue
        messages.append({"channel": channel, "home": home, "at": at, "ref": ref, "text": text})
        label = channel if channel == "lavish" else "claude:" + home
        counts[label] = counts.get(label, 0) + 1
    doc = {
        "schema": SCHEMA,
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "homes": [{"home": h, "transcripts": t} for h, t in zip(homes, args.transcripts)],
        "lavish_state": args.lavish_state or None,
        "counts": counts,
        "excluded_operational": len(dropped),
        "messages": messages,
    }
    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".captain-words.", dir=out_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, args.out)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    parts = ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items()))
    print("refreshed: %d messages (%s); %d Firstmate inputs excluded -> %s"
          % (len(messages), parts or "none", len(dropped), args.out))
    return 0


# ---------------------------------------------------------------- matching

WORD = re.compile(r"[^\W_]+(?:'[^\W_]+)*")
ELLIPSIS = re.compile(r"\.\.\.|…")


def words(text):
    t = unicodedata.normalize("NFKC", text).lower()
    t = t.replace("’", "'").replace("‘", "'").replace("ʼ", "'")
    return WORD.findall(t)


def load_source(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        sys.stderr.write("fm-quote-check: cannot read source %s: %s\n" % (path, exc))
        sys.exit(2)
    if doc.get("schema") != SCHEMA:
        sys.stderr.write("fm-quote-check: %s is not a %s source\n" % (path, SCHEMA))
        sys.exit(2)
    return [" " + " ".join(words(m.get("text", ""))) + " " for m in doc.get("messages", [])], doc


def matches(quote, haystacks):
    """Return (verdict, omitted source words) for one quote."""
    parts = [" " + " ".join(p) + " " for p in map(words, ELLIPSIS.split(quote)) if p]
    if not parts:
        return "skipped", None
    best = None
    for hay in haystacks:
        start = hay.find(parts[0])
        while start >= 0 and best != []:
            pos, omitted = start + len(parts[0]) - 1, []
            for p in parts[1:]:
                found = hay.find(p, pos)
                if found < 0:
                    break
                omitted += hay[pos:found].split()
                pos = found + len(p) - 1
            else:
                if best is None or len(omitted) < len(best):
                    best = omitted
            start = hay.find(parts[0], start + 1)
        if best == []:
            break
    if best is None:
        return "misquote", None
    if best:
        return "verbatim with omissions", best
    return "verbatim", None


# ---------------------------------------------------------------- page reading

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"}
BLOCK = {"p", "div", "li", "br", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
         "section", "article", "blockquote", "header", "footer", "dd", "dt", "figcaption",
         "label", "summary", "details", "form", "fieldset", "legend", "ul", "ol", "table"}
# Formatting that can sit inside a word; every other element boundary separates
# words, so two adjacent labels never fuse into one word ("RecommendedYour").
INLINE = {"a", "abbr", "b", "code", "em", "i", "mark", "q", "s", "small", "strong", "sub",
          "sup", "u"}


class PageText(html.parser.HTMLParser):
    """Visible text, plus the text of every element carrying one class."""

    def __init__(self, cls):
        super().__init__(convert_charrefs=True)
        self.cls = cls
        self.out = []
        self.skip = 0
        self.stack = []  # (tag, collecting-buffer or None)
        self.boxes = []

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "template", "noscript"):
            self.skip += 1
        self._separate(tag)
        if tag in VOID:
            return
        buf = None
        if self.cls and self.cls in (dict(attrs).get("class") or "").split():
            buf = []
            self.boxes.append(buf)
        self.stack.append((tag, buf))

    def handle_endtag(self, tag):
        if tag in ("script", "style", "template", "noscript"):
            self.skip = max(0, self.skip - 1)
        self._separate(tag)
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break

    def _separate(self, tag):
        if tag in BLOCK:
            self._emit("\n")
        elif tag not in INLINE:
            self._emit(" ")

    def handle_data(self, data):
        self._emit(data)

    def _emit(self, s):
        if self.skip:
            return
        self.out.append(s)
        for _, buf in self.stack:
            if buf is not None:
                buf.append(s)


def read_page(path, cls):
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    if not re.search(r"\.x?html?$", path, re.I) and not re.match(r"\s*<(!doctype|html)", raw, re.I):
        return raw, []
    p = PageText(cls)
    p.feed(raw)
    p.close()
    return "".join(p.out), ["".join(b) for b in p.boxes]


QUOTE_PAIRS = (("“", "”"), ('"', '"'), ("‘", "’"), ("'", "'"))


def unwrap(text):
    t = re.sub(r"\s+", " ", text).strip()
    for o, c in QUOTE_PAIRS:
        if len(t) > 1 and t.startswith(o) and t.endswith(c):
            return t[1:-1].strip()
    return t


CUE_TYPED = (
    r"\b(?:you|the captain|captain)\s+(?:(?:once|just|also|literally|actually|already)\s+)?"
    r"(?:said|says|wrote|writes|typed|asked|told (?:me|us|firstmate)|put it|replied|answered|noted)\b"
    r"|\byour (?:own )?(?:words|transcript|message|reply|answer|comment)\b"
    r"|\bthe captain's (?:words|message|reply|answer)\b"
    r"|\bin your (?:own )?words\b")
CUE_NOTE = r"|\byour (?:own )?(?:note|notes)\b|\bthe captain's note\b"
CUE = re.compile(CUE_TYPED + CUE_NOTE, re.I)
TYPED_CUE = re.compile(CUE_TYPED, re.I)
# A quoted span: double or curly quotes, or single quotes (straight or curly)
# that close before a non-letter, the straight ones also opening after a
# non-letter, so apostrophes inside words are not quote marks.
QUOTED = re.compile(
    r"“(?P<a>[^”]{1,2000})”"
    r"|\"(?P<b>[^\"]{1,2000})\""
    r"|‘(?P<c>[^\n]{1,2000}?)’(?![^\W_])"
    r"|(?<![^\W_])'(?P<d>[^'\n]{1,2000}?)'(?![^\W_])")
SENTENCE_END = re.compile(r"[.!?]\s|\n")


def attributed_quotes(text, cues=CUE):
    found = []
    for cue in cues.finditer(text):
        tail = text[cue.end():]
        m = QUOTED.search(tail)
        if not m:
            continue
        gap = tail[:m.start()]
        if SENTENCE_END.search(gap) or len(gap) > 80:
            continue
        span = next(g for g in m.groups() if g is not None)
        found.append((cue.end() + m.start(), span))
    seen, out = set(), []
    for pos, span in found:
        if pos not in seen:
            seen.add(pos)
            out.append(span)
    return out


def page_quotes(path, marker):
    if marker.startswith("class:"):
        _, boxes = read_page(path, marker[6:])
        return [unwrap(b) for b in boxes]
    text, _ = read_page(path, None)
    if marker in ("attributed", "typed"):
        cues = CUE if marker == "attributed" else TYPED_CUE
        return [re.sub(r"\s+", " ", q).strip() for q in attributed_quotes(text, cues)]
    if marker.startswith("regex:"):
        try:
            rx = re.compile(marker[6:], re.S)
        except re.error as exc:
            sys.stderr.write("fm-quote-check: invalid regex marker %r: %s\n" % (marker, exc))
            sys.exit(2)
        out = []
        for m in rx.finditer(text):
            if "q" in rx.groupindex:
                q = m.group("q")
            elif rx.groups:
                q = m.group(1)
            else:
                q = m.group(0)
            if q:
                out.append(re.sub(r"\s+", " ", q).strip())
        return out
    sys.stderr.write("fm-quote-check: unknown marker %r (use class:<name>, attributed, typed or regex:<re>)\n" % marker)
    sys.exit(2)


def cmd_check(args):
    haystacks, doc = load_source(args.source)
    results = []
    for page in args.pages:
        if not os.path.isfile(page):
            sys.stderr.write("fm-quote-check: page %s not found\n" % page)
            return 2
        for marker in args.marker:
            for q in page_quotes(page, marker):
                verdict, omitted = matches(q, haystacks)
                r = {"page": page, "marker": marker, "quote": q, "verdict": verdict}
                if omitted is not None:
                    r["omitted"] = omitted
                results.append(r)
    count = {v: sum(r["verdict"] == v for r in results)
             for v in ("verbatim", "verbatim with omissions", "misquote", "skipped")}
    summary = {"quotes": len(results), "verbatim": count["verbatim"],
               "misquote": count["misquote"], "omissions": count["verbatim with omissions"],
               "skipped": count["skipped"],
               "source_built_at": doc.get("built_at"), "source_messages": len(haystacks)}
    if args.json:
        json.dump({"summary": summary, "results": results}, sys.stdout, ensure_ascii=False, indent=1)
        sys.stdout.write("\n")
    else:
        for r in results:
            if r["verdict"] != "verbatim" or args.verbose:
                line = '%s: "%s" (%s, %s)' % (r["verdict"], r["quote"], r["marker"], r["page"])
                if args.verbose and "omitted" in r:
                    line += '; omitted: "%s"' % " ".join(r["omitted"])
                print(line)
        print("quotes: %d checked, %d verbatim, %d misquoted, %d with omissions, %d skipped; source %s, %d messages"
              % (summary["quotes"], summary["verbatim"], summary["misquote"], summary["omissions"],
                 summary["skipped"], summary["source_built_at"], summary["source_messages"]))
    return 1 if summary["misquote"] or summary["omissions"] else 0


def main(argv):
    ap = argparse.ArgumentParser(prog="fm-quote-check.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("refresh")
    r.add_argument("--out", required=True)
    r.add_argument("--home", action="append", default=[])
    r.add_argument("--transcripts", action="append", default=[])
    r.add_argument("--lavish-state")
    r.add_argument("--operational-lib", required=True)
    c = sub.add_parser("check")
    c.add_argument("pages", nargs="+")
    c.add_argument("--source", required=True)
    c.add_argument("--marker", action="append", default=[])
    c.add_argument("--json", action="store_true")
    c.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)
    if args.cmd == "refresh":
        if len(args.home) != len(args.transcripts) or not args.home:
            ap.error("refresh takes one --transcripts per --home")
        return cmd_refresh(args)
    if not args.marker:
        args.marker = ["class:verbatim"]
    return cmd_check(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

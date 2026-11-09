# Page deliverable

## Sub-features

`--deliverable page` marks a ship brief as a page deliverable, ahead of the Task slots and outside every slot.
It tells the worker what drive evidence the ready `done:` line carries, and records one `page` line in the home's skill-fire log.
A scout refuses the flag, and so does any value other than `page`, without writing a brief or a fire.
`--client-facing`, only beside `--deliverable page`, adds a second marker for a page that addresses a client's visitors: the brief drops the standing quote-check instruction, and spawn admits no standing check for it.

## How to get to it (user POV)

Use `bin/fm-brief.sh <task-id> <repo-name> --mode <mode> --deliverable page` when Firstmate classifies a ship as a page, app, or site at intake.
The source entry points are the `--deliverable` parser and the Task section of `bin/fm-brief.sh`; `bin/fm-dod-lib.sh` owns the marker, the evidence rule, and the log format.

## Driving it with Bash

After Launch and Doctor, run:

```bash
"$BRIEF_REPO/bin/fm-brief.sh" page-ship fixture --mode direct-PR --deliverable page > "$BRIEF_PROOF/page-ship.out"
brief="$FM_HOME/data/page-ship/brief.md"
log="$FM_HOME/data/skill-fires.tsv"
test -s "$brief"
sed -n '/^# Task$/,/^## Captain/p' "$brief" > "$BRIEF_PROOF/page-ship-task-head.txt"
grep -Fx '<!-- fm-brief: deliverable page -->' "$BRIEF_PROOF/page-ship-task-head.txt"
grep -F 'drive=<absolute path to those results>' "$BRIEF_PROOF/page-ship-task-head.txt"
grep -F 'no-drive: <reason>' "$BRIEF_PROOF/page-ship-task-head.txt"
grep -Fx '<!-- fm-brief: task-slots v4 -->' "$brief"
awk -F'\t' -v b="$brief" '$2 == "page-ship" && $3 == "page" && $4 == "fm-brief.sh" && $5 == b && NF == 5' "$log" | grep -q .
cp "$brief" "$BRIEF_PROOF/page-ship.md"
cp "$log" "$BRIEF_PROOF/page-skill-fires.tsv"
expect_refused() {
  if "$BRIEF_REPO/bin/fm-brief.sh" "$@" > "$BRIEF_PROOF/$1.out" 2>&1; then
    echo "$1 unexpectedly accepted" >&2
    return 1
  fi
  test ! -e "$FM_HOME/data/$1/brief.md" || return 1
  ! awk -F'\t' -v id="$1" '$2 == id' "$log" | grep -q .
}
expect_refused page-scout fixture --scout --deliverable page
expect_refused page-site fixture --mode direct-PR --deliverable site
expect_refused page-client-bare fixture --mode direct-PR --client-facing
"$BRIEF_REPO/bin/fm-brief.sh" page-client fixture --mode direct-PR --deliverable page --client-facing > "$BRIEF_PROOF/page-client.out"
sed -n '/^# Task$/,/^## Captain/p' "$FM_HOME/data/page-client/brief.md" > "$BRIEF_PROOF/page-client-task-head.txt"
grep -Fx '<!-- fm-brief: client-facing -->' "$BRIEF_PROOF/page-client-task-head.txt"
! grep -F 'standing check, whatever' "$BRIEF_PROOF/page-client-task-head.txt"
```

Expected state is one marked page brief whose instruction sits before `## Captain's intent`, exactly one five-field `page` fire naming that brief, a client-facing page brief carrying both markers and no standing quote-check instruction, and three refusals that left neither a brief nor a fire.

## Gotchas

The done-time refusal itself is not driven here: it needs a launched task record, and `tests/fm-dod-lib.test.sh` plus `tests/fm-crew-state.test.sh` own that regression.
The fire log belongs to the home, so a fresh `FM_HOME` per episode keeps the one-fire expectation honest.

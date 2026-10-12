# Invalid delivery mode

## Sub-features

An unsupported ship mode is rejected before a brief artifact is written.

## How to get to it (user POV)

Call the same ship CLI with an unsupported delivery mode.
The parser and mode validation in `bin/fm-brief.sh` own this refusal.

## Driving it with Bash

After Launch and Doctor, run:

```bash
if "$BRIEF_REPO/bin/fm-brief.sh" invalid fixture --mode unsupported > "$BRIEF_PROOF/invalid.out" 2>&1; then
  echo 'invalid mode unexpectedly accepted' >&2
  exit 1
else
  brief_rc=$?
  printf '%s\n' "$brief_rc" > "$BRIEF_PROOF/invalid.exit"
fi
test ! -e "$FM_HOME/data/invalid/brief.md"
cat "$BRIEF_PROOF/invalid.out"
```

Expected state is a nonzero exit, explanatory diagnostic, and no successful brief artifact.

## Gotchas

Directory creation alone is not success; inspect the actual brief path.
Do not maintain away this expectation if an invalid mode starts succeeding.

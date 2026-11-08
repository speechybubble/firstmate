# Intake checks

## Sub-features

A scaffolded ship or scout brief carries a `## Checks` slot holding `{CHECKS}`, and `# Task` tells the worker the one command that runs the admitted checks before `done:`.
`bin/fm-checks.sh validate` admits a filled slot only when every check passes its known-good example and fails its known-bad one, or when the slot is one reasoned exemption line.
A check that passes its bad example is refused, which is what stops a check that would pass anything.
`bin/fm-checks.sh drive-results` accepts only a drive run's assertion results with every assertion passing as page drive evidence.

## How to get to it (user POV)

Firstmate fills `## Checks` at intake after `bin/fm-brief.sh`, and checks it with `bin/fm-checks.sh validate <brief> --kind <ship|scout>` before spawning, which runs the same validation.
`bin/fm-checks.sh --help` owns the format, the closed set of check types, and the results format; `bin/fm-dod-lib.sh` owns the done-time gate.

## Driving it with Bash

After Launch and Doctor, run:

```bash
"$BRIEF_REPO/bin/fm-brief.sh" checks-ship fixture --mode direct-PR > "$BRIEF_PROOF/checks-ship.out"
brief="$FM_HOME/data/checks-ship/brief.md"
grep -Fx '{CHECKS}' "$brief"
grep -F "fm-checks.sh' run '$FM_HOME/state/checks-ship.checks.json' --head" "$brief"
grep -F 'fill {CHECKS}' "$BRIEF_PROOF/checks-ship.out"
python3 - "$brief" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
checks = '''```json
[{"id": "guarantee-conditional", "source": "higher price guarantees should always be conditional", "type": "not-contains", "target": "ad.txt", "pattern": "(any reason|no questions asked)", "good": "If you run them 30 days and none wins, next month is free.", "bad": "Full refund for any reason, no questions asked."},
 {"id": "has-cta", "source": "the ad has a call to action", "type": "contains", "target": "ad.txt", "pattern": "(Book|Get)", "good": "Book a call", "bad": "Get a full refund, no questions asked"}]
```'''
open(path, "w", encoding="utf-8").write(text.replace("{CHECKS}", checks, 1))
PY
if "$BRIEF_REPO/bin/fm-checks.sh" validate "$brief" --kind ship > "$BRIEF_PROOF/checks-validate.out"; then
  echo 'a check that passes its bad example was admitted' >&2
  exit 1
fi
grep -Fx 'admitted guarantee-conditional' "$BRIEF_PROOF/checks-validate.out"
grep -F 'invalid has-cta: passes its bad example' "$BRIEF_PROOF/checks-validate.out"
grep -Fx 'checks: 1 admitted, 1 invalid' "$BRIEF_PROOF/checks-validate.out"
printf 'some-host\n' > "$BRIEF_SCRATCH/hostname-like"
if "$BRIEF_REPO/bin/fm-checks.sh" drive-results "$BRIEF_SCRATCH/hostname-like" > "$BRIEF_PROOF/checks-drive-refused.out"; then
  echo 'a file that is not drive results was accepted' >&2
  exit 1
fi
printf 'pick-form-queues\tpass\n' > "$BRIEF_SCRATCH/drive.tsv"
"$BRIEF_REPO/bin/fm-checks.sh" drive-results "$BRIEF_SCRATCH/drive.tsv"
cp "$brief" "$BRIEF_PROOF/checks-ship.md"
```

Expected state is a brief with an unfilled `{CHECKS}` slot and the worker's run command, a validation that admits the conditional-guarantee check and refuses the call-to-action check because its bad example passes, and drive evidence refused for a plain file and accepted for passing results.

## Gotchas

Spawn admission, the admitted record, and the done-time refusal need a launched task record, so `tests/fm-task-delivery.test.sh`, `tests/fm-dod-lib.test.sh`, and `tests/fm-crew-state.test.sh` own those regressions; `tests/fm-checks.test.sh` owns the validator and runner.

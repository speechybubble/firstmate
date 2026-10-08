# Worked example: one retry-plan operation for two callers

This is a synthetic disposable CLI/API fixture, not a production retry service or a historical incident.
It prints or returns a schedule and never sleeps, networks, or executes retries.
The fixture lives under [tests/fixtures/reasoning-workflow](../../../../tests/fixtures/reasoning-workflow/).
Its baseline module contains an explicitly synthetic source-history constraint: zero delay is intentional for dry runs.
Other historical rationale is unknown.

## Executable caller uses

Run these from the repository root:

```sh
python3 tests/fixtures/reasoning-workflow/retry_budget.py '{"delay_ms":12.5,"attempts":2}'
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tests/fixtures/reasoning-workflow python3 -c 'from retry_budget import retry_plan; print(retry_plan({"delay_ms":0,"attempts":3}).delays_ms)'
```

The CLI prints `{"delays_ms": [12.5, 12.5]}` and exits 0.
The imported caller receives an immutable plan and prints `(0, 0, 0)`.
The caller supplies delay in milliseconds and a positive integer attempt count; neither caller needs to know validation order.

```sh
python3 tests/fixtures/reasoning-workflow/retry_budget.py '{"delay_ms":-1,"attempts":3}'
python3 tests/fixtures/reasoning-workflow/retry_budget.py '{"delay_ms":0,"attempts":3}'
```

The invalid call reports `error: delay_ms must be a finite nonnegative number` to stderr, exits 2, and emits no schedule to stdout.
The corrected call prints three zero delays and exits 0.

## Trace, evidence, and decision

The baseline CLI flows through JSON parsing and CLI-only validation before an unchecked `retry_plan` operation.
The imported caller enters that operation directly.
The same negative or non-finite delay is therefore rejected by the CLI and accepted by the baseline API: the CLI check masks the missing domain boundary.
Both baseline callers succeed for zero and positive delay, which is contrary evidence against a claim that every baseline path fails.
Boolean attempts expose another invalid state through the same boundary.

| Candidate | CLI caller | Imported caller | Invariant owner |
|---|---|---|---|
| Exposed load/validate/normalize stages | must orchestrate the sequence | must remember the same sequence | each caller |
| One `retry_plan(config)` operation | parses JSON, then derives a plan | derives a plan directly | shared domain operation |

The second shape fits these callers because deriving a complete plan is the dominant operation and both need the same runtime guarantee.
A staged interface can be appropriate elsewhere; this example does not establish a universal winner.
The corrected domain operation validates runtime values before creating an immutable schedule, while the CLI handles parsing, diagnostics, and printing.
The returned schedule has one delay per attempt and the input remains unchanged.
Type annotations alone would not establish these guarantees.

## Reuse and proof

The existing test command checks an understood two-delay result, reuses the same check on a zero-delay config, then tests failure shapes and replay through both public entry points:

```sh
bin/fm-test-run.sh tests/fm-brief.test.sh tests/fm-reasoning-workflow.test.sh
```

The [verification record](../../../../docs/verification/reasoning-workflows.md) states the active evidence and its limits.
The fixture prevents invalid config from producing a plan through the demonstrated corrected entry points.
The generated method references provide discovery; selecting and applying a method remains agent judgment.

## Transfer examples

For a scoped codemod, compare the project's existing syntax-aware command on one understood call site, then a materially different caller and an unmatched pattern.
Refuse ambiguous matches, preserve unmatched behavior, and check a second run's effects before widening the edit; build a helper only if the existing command lacks a demonstrated capability.

For an existing trace query, map one returned span chain to the user-visible symptom and compare a successful caller path before repeating the query on a different input.
A correlated slow span is evidence for a hypothesis, not proof of cause or historical design intent; retain a counterexample and test a focused counterfactual.

# Reasoning workflow verification

Verified on 2026-10-07 with Python 3.14.4, GNU Bash 5.3.9, and ShellCheck 0.11.0.
These are active reproducible checks for the synthetic workflow and brief integration.
The method owners are [caller-first-design](../../.agents/skills/caller-first-design/SKILL.md) and [diagnostic-reasoning](../../.agents/skills/diagnostic-reasoning/SKILL.md).
The [worked example](../../.agents/skills/caller-first-design/references/worked-example.md) supplies executable callers and a qualified design decision.

## Refresh the proof

From the repository root, run:

```sh
bin/fm-test-run.sh tests/fm-brief.test.sh tests/fm-reasoning-workflow.test.sh
bin/fm-test-run.sh --check-coverage
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

The caller/brief run returned both scripts with `exit=0` and this exact summary:

```text
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=54237
```

Timing varies between runs.
The fixture's Python check ran eight tests and returned `OK`.
The coverage guard returned the following, with the new suite registered in `pure-contract-unit`:

```text
FM_TEST_COVERAGE ok total=217 parallel=24 parallel_max_ms=417163 parallel_imbalance_ms=2894 parallel_unhinted=0 serial=177 serial_shards=9 serial_unhinted=1 herdr=16
```

## Demonstrated guarantees and limits

| Surface | Demonstrated behavior | Limit |
|---|---|---|
| Ordinary generated briefs | Scout and all three ship modes emit usable absolute method paths from the code root, with a distinct private home and paths containing spaces | Discoverability is deterministic; selecting and following a method depends on agent judgment |
| Existing brief contracts | Task placeholders and delivery contracts remain available; secondmate charters keep their existing scope | Existing running briefs are not rewritten |
| Synthetic baseline | CLI rejects negative/non-finite delays while the imported API accepts them; zero and positive delays succeed on both paths | This is retained fixture evidence, not a production defect |
| Corrected CLI/API | Both reject invalid delay and attempt values, including booleans and non-finite floats, before emitting a plan | Validation covers the demonstrated config-to-plan entry points |
| Caller result | Schedule length matches attempts, milliseconds remain explicit, input is unchanged, output is immutable, and valid replay/recovery succeeds | No sleeping, network access, or actual retries are implemented |
| Causal method | The fixture exercises the shared-boundary remedy after baseline reproduction and preserves contrary evidence | A method exercise does not certify general agent compliance, reasoning quality, comparative speed, or production reliability |

The generated brief path and method bodies were used by the implementation worker for the isolated CLI/API decision.
A separate generated routine-help brief was exercised through public `--help` output without an architectural comparison or a new tool.
Those bounded exercises establish usable invocation, not a quantitative comparison of agent policies.

`bin/fm-brief.sh` uses the same method section for each ordinary delivery mode and does not depend on a primary harness or runtime backend.
The portable output checks exercise that common surface without starting an agent or lifecycle endpoint.
The [brief suite](../../tests/fm-brief.test.sh) checks ambient Bash parsing and executable scaffold output; it does not enforce heredoc source structure.
Stock macOS Bash compatibility is checked by the `macos-stock-bash` job in [CI](../../.github/workflows/ci.yml), not established by the local Bash run above.
Landing and supported fleet convergence are required before new live briefs receive the change.

## Required ancestry fixture compatibility

Verified on 2026-10-08 with the same Bash and Python versions above.
The [ancestry suite](../../tests/fm-session-lock-ancestry.test.sh) now keeps its real process trees under an ordinary test-shell parent and checks the production owner's complete reported harness run.
It preserves the existing hook exit-code, session-lock, rewake, competing-owner, namespace PID 1, and non-harness-gap assertions.
The fixture has no dependency on which host process adopts an orphan.
Cleanup signals only a still-owned direct child and reaps the daemon, session, and hook before removing their home.

```sh
env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE bin/fm-test-run.sh tests/fm-session-lock-ancestry.test.sh --per-script-timeout-secs 180
```

This returned:

```text
ok - session-lock fixtures reap the owned daemon, session and hook before home cleanup
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=14946
```

The existing fixture completion budget was preserved.
The explicit script bound limits validation; it does not change the fixture's assertions or deadlines.
The extra cleanup case uses a held synthetic hook; the three session cases still run the real copied Stop hook.
This is portable fixture compatibility and cleanup evidence, not a change to live session ownership or runtime supervision.

# Task-context activation and reuse

The internal [`task-context` skill](../../.agents/skills/task-context/SKILL.md) owns relevant context selection and learning disposition.
[`AGENTS.md`](../../AGENTS.md) activates it during relevant brief preparation, pickup and learning admission.
[`fm-brief.sh`](../../bin/fm-brief.sh) carries its conditional code-root pointer into ship/scout instructions, including tasks in other repositories.
The existing [`recovery`](../../.agents/skills/stuck-crewmate-recovery/SKILL.md) and [`stow`](../../.agents/skills/stow/SKILL.md) callers reach it at their progress-note and learning-admission steps.

## Deterministic entry-point verification

Verified on 2026-10-07 with GNU Bash 5.3.9 on Linux.
Run the existing behavior interfaces from the repository root:

```sh
bin/fm-test-run.sh tests/fm-brief.test.sh tests/fm-spawn-batch.test.sh
```

The exact relevant output was:

```text
ok - fm-brief: task context is reachable in every worker mode and stays outside intent and charters
ok - fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=56430
```

The generated-output test covers all three ship modes and scout with an operational home distinct from the code root.
It follows the emitted skill path, checks its readability, fills ordinary task placeholders and uses the existing launch parser to verify that context guidance remains outside the authorized intent and specification bodies.
It also preserves ship delivery modes, connects project-memory admission and leaves secondmate supervisor roles and parent channels intact.
The brief suite clears inherited home/data/state overrides so fixture paths cannot resolve into an active fleet.
These are transport and contract checks, not semantic comprehension tests.
The common launch-brief transport and runtime adapters are unchanged; this record does not claim a new live-harness or backend-lifecycle trial.

## Worked semantic pickup and reuse

A bounded synthetic exercise ran on 2026-10-07 in the implementing Codex CLI 0.160.0 session, without extra agents or live product effects.
The worker generated briefs, loaded the referenced skill, read scoped source records and current artifacts, saved ordinary reports, then used a later generated brief to pick up the saved result.

| Case | Observed decision or result |
|---|---|
| Required order, advice and correction | Foundation preceded advanced work only for new users; returning users retained their exception and performance advice stayed optional. |
| Older rejected design | A cited older revert explained draft loss on timeout, so the worker chose local-draft preservation instead of reinstating autosave-before-retry. |
| Sufficient or stale summary | Sufficient context needed no additional historical retrieval; after the artifact changed, a stale summary was corrected and the next action became completion verification. |
| Preferences | One explicit domain preference became a candidate for firstmate; an incident-only request stayed task-local, an unrelated preference survived, and agent-inferred habits were not promoted. |
| Learning disposition | A wrong body and a missing trigger were corrected at their existing synthetic owners; adequate instructions were retained, a structural defect went to its repair task, and unknown causes stayed qualified. |
| Later reuse | The saved rejection reason and current artifact led to a retry repair that retained the draft through two failures, then acknowledged and cleared it on success. |
| Neighbors and access | Export remained valid; a fresh edit needed no recall, unavailable evidence stayed a precise gap, and cancelled work and unrelated/private records remained untouched. |

The synthetic editor's exact relevant command output changed as follows:

```text
python3 editor.py retry-timeout
before: {"draft": "", "status": "timeout"}
after:  {"draft": "alpha", "status": "timeout"}
python3 editor.py retry-success
before and after: {"draft": "", "saved": "alpha", "status": "saved"}
python3 editor.py export
before and after: {"draft": "alpha", "exported": "alpha"}
```

To repeat the semantic exercise, use a disposable home, generate a normal brief, provide a scoped correction and rejected-design record, and follow its skill pointer into an ordinary report.
Generate a later related brief with that report and the current artifact, then record the retained fact, changed decision and caller-visible result, including a valid neighbor.
Judge those semantic results directly; the behavior suite supplies no automated relevance or learning oracle.

The same worker knew the plan and fixture answers, and the captured baseline instructions also supported correct semantic decisions.
This establishes a usable conditional entry point and one worked reuse path, not comparative model superiority, longitudinal improvement or guaranteed relevance and comprehension.
Missing context and stale claims are detectable/recoverable through existing task records; semantic selection, preference scope and causal classification remain judgment-dependent.
Branch verification does not install these changes into running homes or reinject older briefs.

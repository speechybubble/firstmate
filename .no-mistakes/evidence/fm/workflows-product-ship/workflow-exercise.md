# Bounded workflow consumption exercise

## Scope and provenance

This run's agent followed the pointer in the actual generated `live-local-only-brief.md` and read the product-experience skill. The product under test is Firstmate's brief generator and instruction workflow, not a result-list application. The generated task placeholders were not dispatched. This is same-worker consumption, with prior exposure to the change, not an independent model comparison or proof of fleet rollout.

## User/caller task and observed result

A caller wants a local-only brief in an operational home separate from both Firstmate's code and the destination project. `caller-tutorial.md` was written before execution. `drive.py` then executed its five steps through the real `bin/fm-brief.sh` CLI. The missing-mode attempt failed before creating a brief; explicit local-only succeeded; an attempted mode-changing overwrite failed and preserved the original bytes; using a fresh ID recovered successfully. `live-cli-transcript.json` preserves commands, exits and diagnostics. The generated brief points to the readable tracked skill, leaves intent/specification placeholders explicit, and does not install a skill in the destination.

There is no unresolved interaction-design choice in this caller task: its interface is already fixed. I did not invent an alternative UI or prototype. The execution demonstrated first success and recovery, not a subjective usability score or improved task speed.

## Evidence-preserving explanation output

Input: “The retry may have failed because the upstream service was unavailable. We do not know why the original author chose a fixed delay.”

Output: “Upstream unavailability may explain the retry failure. The original author's reason for the fixed delay is unknown.”

The output retains uncertainty in both the failure attribution and historical motivation; it does not turn a plausible cause into an observed fact.

Applied handoff: “The generated brief contains an absolute path into the tracked code root. In this isolated run that path was readable although the operational home and destination project were elsewhere. This provides a usable entry point without a copied skill in the project. It does not establish that every launched model will follow the instruction, or that any installed fleet has updated.”

## Six-stage communication exercise

Synthetic input: six stages each saying “Explicit delivery modes make task setup safer.”

Revised output:
1. Goal: Create a local-only task brief without authorizing a push or PR.
2. Prerequisite: Choose a disposable operational home and destination; clear inherited data/state overrides.
3. Mechanism: The required `--mode local-only` argument fixes the emitted delivery contract rather than guessing from a registry.
4. First action: Run `bin/fm-brief.sh tutorial "$project" --mode local-only`, then read the generated brief before filling its intent and specification.
5. Recovery: A missing mode is rejected before a brief is created. An existing brief is not overwritten; use a fresh task ID for a separate task.
6. Limit and next step: A scaffold is not a launched worker. Fill and review task-specific content before using the separately authorized dispatch path.

These stages contribute a goal, prerequisites, mechanism, action, recovery, and an authority limit rather than repeating a benefit. This is a qualitative same-agent exercise, not a heading-count assertion.

## Neighboring authority checks

For a fixed copy correction, the expected action is the named replacement with no exploration. This validation itself needed no prototype, extra worker, or expanded delivery authority. A hypothetical cancelled redesign remains context: no task was spawned or reactivated. A hypothetical marketing request requiring an unavailable named book cannot be represented as book-informed copy; the appropriate output is to identify that missing source and request an authorized excerpt, not install a writing bundle or invent its contents.

## Limits

No comparative inline-expansion/side-panel application was built or driven in this run. That proposed exercise is not a runtime UI shipped by this change. No claim is made about screenshots, keyboard accessibility, screen readers, mobile devices, interaction preference, marketing-book fidelity, independent model adherence, or long-term adoption. Prior author artifacts were not reused as live evidence. The current run demonstrates the CLI entry path, executable compatibility and a bounded caller/tutorial plus communication application of the method.

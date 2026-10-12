---
name: caller-first-design
description: >-
  Agent-only method for choosing or materially changing an interface or ownership
  boundary, an internal migration, or a repeated mechanical operation whose
  implementation remains uncertain. Start from executable caller uses, separate
  behavior from qualified rationale, place invariants with their actual owner,
  and reuse supported tools. Skip obvious routine edits with no material design
  uncertainty; the same task worker applies this method without a design panel.
user-invocable: false
metadata:
  internal: true
---

# caller-first-design

Make the next useful caller result concrete before selecting an implementation.
Use the task's existing report or project architecture owner for a compact decision, with enough evidence to review it.
Do not introduce another report system, approval, reviewer, or framework.
For bug work, [diagnostic-reasoning](../diagnostic-reasoning/SKILL.md) remains the causal owner.

## Start with the caller and the blocking uncertainty

Identify the next observable result and the specific uncertainty preventing it.
Reuse supplied evidence and supported commands; stop preparation when they answer the question.
An obvious routine edit needs neither a separate plan nor alternative designs.

Write two realistic caller uses and one meaningful error/recovery use before deriving the interface.
For each, name the input, returned result, side effect, and knowledge the caller should not need.
Make the short tutorial executable acceptance through the actual public entry points.

Trace entry -> boundary parser -> domain owner -> effect/result for those uses.
Keep how the path behaves separate from why the design was chosen.
Qualify rationale as explicit evidence, supported inference, or unknown; missing history stays unknown.
Turn material evidence into constraints to preserve, change, or avoid, and name the remaining risk.

## Choose a shape and place invariants

If the uncertainty is material, compare two genuinely different shapes with the same caller uses.
Choose by invariant ownership, dominant operations, compatibility, and caller burden.
A complete domain operation and caller-orchestrated stages are candidates, not a rule that a wrapper must win.

Put each invariant at one actual owner and boundary.
Reuse canonical parsers, variants, and declarations instead of copying checks or lists.
Validate runtime data at runtime: a type annotation or brand does not establish finite, nonnegative, or authorized values.
Preserve useful rationale and intentional negative tests until replacement enforcement is demonstrated.

For a migration, inventory real callers, including scripts, examples, and dynamic references.
Migrate one coherent unit and settle the compatibility boundary before deleting an old API.
For unfamiliar work, use a short finite phase list driven by the hardest uncertainty, a baseline, and acceptance.
Repeated deviations reopen the specific failed assumption rather than requiring a whole redesign.

## Reuse a tool only for understood work

When repeated mechanical work or a concrete direct-path blocker warrants tooling, understand one unit first.
Find the existing supported command or parser, compare its result with the understood unit, then reuse it on a different input.
Reject ambiguous input and check replay effects before expanding the operation.
Add a helper only for the demonstrated missing capability within the existing project or tool owner.

Verify the caller result, relevant failure shapes, and valid neighbors through the actual workflow.
Record the selected shape, rejected candidate, invariant owners, qualified rationale, and observed result together.
Distinguish runtime prevention from detection/recovery and agent judgment; passing a worked example does not prove general compliance or speed.
Use [the worked example](references/worked-example.md) when a CLI/import boundary or a reusable mechanical operation needs a concrete model.

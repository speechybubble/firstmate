---
name: diagnostic-reasoning
description: >-
  Agent-only procedure for diagnosing reported bugs.
  Use before scoping a reported bug and before acting on a diagnostic report.
  Owns end-user-aligned reproduction, causal separation, divergent-path and history inspection, counterfactual testing, and disconfirming evidence.
user-invocable: false
metadata:
  internal: true
---

# diagnostic-reasoning

Use this procedure before scoping a reported bug and before acting on a diagnostic report.
This skill is the single owner of Firstmate's bug-diagnosis reasoning procedure.
Firstmate applies it when briefing delegated investigation and evaluating the resulting evidence, without taking over project-specific investigation itself.

## Establish the observed behavior

Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Require an end-to-end reproduction aligned with the real user path whenever it is feasible and safe.
If a faithful reproduction is not feasible, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Separate these three facts explicitly:

- The **initiating trigger** is the event, input, or transition that starts the faulty behavior.
- The **masking condition** is the independent state, environment, timing, cache, configuration, or path difference that hides or exposes the fault.
- The **visible symptom** is what the end user or operator can actually observe.

Do not collapse those facts into one label.
A masking condition may explain why a fault appears only sometimes without being the initiating cause, and the visible symptom may be several layers downstream from both.

## Test the causal explanation

Inspect the failing path and a proven path where the intended behavior is known to work.
Compare their inputs, state transitions, dependencies, timing, and control flow to find the earliest meaningful divergence.
Inspect relevant history, including blame, commits, migrations, and prior implementations, when it can explain why the paths diverged or which invariant was intended.
Do not treat the most recent nearby change as causal without evidence.
Separate how the path behaves from why its design was chosen: qualify rationale as explicit evidence, supported inference, or unknown.
Missing history remains unknown; current code alone does not establish author intent.

Identify the smallest counterfactual that should change the outcome if the leading explanation is true.
Change one condition at a time where practical, and record whether the symptom appears, disappears, or remains unchanged.
Seek disconfirming evidence deliberately: name what observation would falsify the leading explanation, run that check when feasible, and retain contradictory results instead of explaining them away.
Compare the final explanation against the proven path and show why the proposed causal boundary accounts for both the failure and the success.
Group sibling symptoms only when that causal account explains them; keep unrelated symptoms separate.
If actor-role skew is a relevant hypothesis, compare the actor census and retain an even-census counterexample before attributing the failure to skew.

## Choose the remedy at the causal owner

For a workflow or instruction-related failure, distinguish the following explanations using the failing path and counterfactual evidence:

- Missing or wrong instruction body: the loaded guidance cannot produce the required behavior.
- Missed trigger: adequate guidance exists but was not loaded on the relevant path.
- Execution failure: adequate guidance was loaded and the observed action ignored it.
- Structural cause: ownership, state, or a boundary allows the error to recur despite adequate guidance.

These explanations can coexist; identify which evidence supports each instead of choosing a label from the symptom alone.
Repair the narrowest demonstrated owner: the body, discovery trigger, execution/recovery path, or structural boundary.
Repeated failure alone does not justify another AGENTS rule, a wrapper, or actor rotation.
When the remedy changes a material interface or ownership boundary, use [caller-first-design](../caller-first-design/SKILL.md) for the compact caller and invariant handoff.

## Scope and act on the result

A diagnosis brief should ask for the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.
Implementation still requires the captain's request or another existing lifecycle authority, and the reproduction should become the regression test when a fix is authorized.
Before claiming systematic correction, exercise the original failure, a materially different case of its mechanism, a valid neighbor, and the actual workflow using the correction.
Report deterministic prevention, detection/recovery, and remaining judgment dependence separately.

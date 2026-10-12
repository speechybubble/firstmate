# Intake dry run: synthapp README typo

## Context
Captain ask: "Fix the typo recieved -> received in synthapp README."
Dry run in synthetic lab home /tmp/fm-lab.Uo7DLP; no scaffold, spawn, or lifecycle scripts.

## Intake findings (read-only)
- Project: synthapp, named explicitly; one confident match.
- Only occurrence: `projects/synthapp/README.md:3` - "Results are recieved from the index." (grep across repo, `.git` excluded; `results.html` has none).
- Lab home has no project registry -> unregistered project resolves to `no-mistakes`, yolo off; registration gap goes to the captain.
- Deliverable: ship (implementation authorized, no uncertainty). No scout, no product-experience load (docs-only typo, no experience change).
- Branch prefix: default `fm/`; base branch: project default. Effort: low.
- Backlog note: mode no-mistakes, yolo off, reason "unregistered project default".

## ## Firstmate spec (to write into the brief)

- In `README.md`, change "recieved" to "received" on the line "A synthetic app. Results are recieved from the index."
- This is the only occurrence in the repository at intake; edit nothing else.
- Out of scope: other spelling or wording fixes, other files (including `results.html`), and any project-wide spelling sweep or tooling. If you notice another typo, mention it in your final status as a follow-up instead of fixing it.
- Done when the diff is exactly that one-word change in `README.md` and it has gone through the no-mistakes pipeline to a PR.

## Verification
`git diff` shows a single-line change in `README.md`; `grep -rn recieved` (excluding `.git`) returns nothing.

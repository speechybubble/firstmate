# Intake dry run: synthapp result details (lab home /tmp/fm-lab.Uo7DLP)

## Context
Ask: clicking a search result in synthapp navigates away and the reader loses their place; work out whether inline details or a side panel is better, and ship it.
Dry run only: no scaffold, spawn, backlog write, or lifecycle script.

## Intake decisions
- Project: synthapp, explicitly named (`projects/synthapp`: `README.md`, `results.html`, one commit).
- Deliverable: **ship**, not scout. "Ship it" authorizes implementation; inline vs side panel is a bounded, in-scope interaction choice that the ship resolves using the product-experience comparison. No separate design scout.
- Delivery: the lab home has no project registry, so synthapp is unregistered and resolves to `no-mistakes` with yolo off (the captain approves the merge). The missing registration is reported to the captain.
- Effort: xhigh (design comparison with open questions), per the generic fallback.
- Product-experience applies (changes the reader experience and compares interaction alternatives).
- Observed starting state: `results.html` lists three focusable results (Alpha, Beta, Gamma "details unavailable"); a script comment says clicking navigates to `details.html`, which does not exist in the repo.

## Captain's intent (verbatim)
In synthapp, clicking a search result navigates away and the reader loses their place. Work out whether opening details inline or in a side panel is better, and ship it.

## Firstmate spec (what goes into the instructions)
See the reply; same text.

## Verification (for the real run)
Worker drives open, read, close, and return in the browser at desktop and narrow widths, including Gamma's unavailable state, and keeps screenshots plus a focus/scroll trace as evidence; no-mistakes validates and opens the PR.

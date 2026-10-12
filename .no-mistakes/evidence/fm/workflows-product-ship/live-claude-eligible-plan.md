# Scout-1 plan: open a result's details without losing place (synthapp)

## Context
The captain wants a reader to open one search result's details from `results.html` and come back to the exact spot they left, instead of navigating away and losing their place.
Firstmate scoped this as scout-only: compare **inline expansion** and a **side panel**, recommend one in `/tmp/fm-lab.Uo7DLP/data/scout-1/report.md`, and start from the current `results.html`.
The deliverable is the report. Prototypes are scratch work in the disposable worktree and get thrown away.
My reading of the brief: "decide" means I recommend one with evidence. Firstmate or the captain adopts it or promotes the task. I do not build the feature.

## Starting state (observed, read-only)
- `results.html:1-4` is the whole app: three `<li tabindex="0">` items (Alpha, Beta, and "Gamma report (details unavailable)"), no links or handlers. The only script is a comment that says clicking navigates to `details.html` and loses scroll position.
- `details.html` does not exist. Nothing in the repo implements the navigation that the comment describes, so the reported bug can't be reproduced literally. The report must say this plainly and must not claim a repro.
- With three items there is nothing to scroll, so "losing scroll position" only becomes observable with a longer list.
- Side findings to report (out of scope for a scout, listed as ship follow-ups):
  - The `<li tabindex="0">` items are focusable but have no role or activation, so keyboard users can't open anything.
  - `README.md:3` has the typo "recieved".

## Approach (sequential, single worker, in the scratch worktree)
1. **Status:** append a `working [at=<epoch>]` line when work starts (use the command from the brief, run `date +%s` first).
2. **Reference lock (light):** use the `refero:refero-design` skill, as product-experience requires, to find 2-3 real examples of each pattern: inline expand in result lists, and a master-detail side panel. Record one fixed, neutral visual target so the two candidates differ only in how they behave.
3. **Shared fixture:** in scratch files, extend the existing result list to about 40 items. Keep Alpha, Beta and Gamma (Gamma still has unavailable details) and add identical detail text for every item. Both candidates use the same data, the same item selected (one around #25, so scrolling matters), and the same trigger: a `<button>` inside each result, activated by click or Enter/Space.
4. **Baseline stand-in:** a `results-baseline.html` that goes to a stub `details.html`. Using the browser back button shows what the reader experiences today with real navigation (in Chrome, bfcache or scroll restoration may hide the problem). This replaces the comment's untested claim with an observation.
5. **Candidate A, inline expansion:** a disclosure pattern where the button has `aria-expanded` and `aria-controls` and the details region opens right under the item. Close returns focus to the button. Gamma shows an inline "Details unavailable" message with a retry or close option.
6. **Candidate B, side panel:** a list plus a panel region (`aria-labelledby`, focus moves into the panel, Esc and Close return focus to the item that opened it). At narrow width it becomes a full-width overlay drawer with a focus trap. Gamma shows the unavailable state inside the panel.
7. **Drive both with `chrome-devtools-axi`** at desktop (1280px) and narrow (375px) widths. For each candidate and width:
   - scroll to the item, open it, read, close
   - record `scrollY`, `document.activeElement`, and whether the selected item is still in view before open, after open, and after close
   - repeat the whole sequence using only the keyboard
   - open Gamma (unavailable) and recover
   - save screenshots for appearance, and a trace or JS-evaluated log for focus and scroll behaviour
8. **Decide from observations, not from assumed speed or satisfaction.** Keep three things separate: visual match to the target, interaction correctness (position kept, focus returned, keyboard works, error recovery), and product fit (one result at a time, short details, narrow screens).
   - Working hypothesis, to be confirmed or overturned by step 7: **inline expansion**. It keeps the reader's place by construction at every width, needs no focus trap, and the error state sits next to its item.
   - Expected reason the side panel loses: at narrow width it turns into an overlay, which brings back a context switch. It also needs more focus handling to be correct.
   - What would flip it: comparing several results side by side, or long detail content.
9. **Minimal tutorial:** write a short "how to open and return" usage note for the chosen candidate. Then re-run it exactly as written against the same scratch revision, as a later pickup would.

## Report contents (`/tmp/fm-lab.Uo7DLP/data/scout-1/report.md`, standalone)
- **Intent and scope:** what I did and what was not exercised. The trial is same-worker and sequential. I saw candidate A first, which limits a fair comparison. No real users were involved.
- **Evidence:**
  - starting-state facts with `file:line` references
  - commands I ran
  - a measured table of scroll, focus and in-view results for each candidate and width
  - paths to the screenshots and traces
- **Recommendation:** one interaction, the observed trade-off, why the other option loses, and what would change the call.
- **Ship follow-up, if promoted:**
  - implementation sketch: give the `<li>` items a button trigger, add the disclosure region, and handle unavailable details
  - accessibility fix for the current focusable-but-inert items
  - README typo fix
  - note that `details.html` is missing
- **Tutorial:** the minimal tutorial plus the result of re-running it.

## Completion
- Before writing `done`, load `captain-hold-lifecycle` and go through every open question in the report. A recommendation that needs no captain choice creates no held task, so I expect `bin/fm-captain-hold.sh complete scout-1 --none`, run in the lab `FM_HOME`.
- If the evidence comes out a genuine product tie (for example, the panel is clearly better for some reader goal the captain hasn't stated), I will instead hold one task with both options and its `--origin`, and append `needs-decision`.
- Then append `done [at=<epoch>]: recommend <choice> - <one-line reason>`.
- Check the inbox (`/tmp/fm-lab.Uo7DLP/state/scout-1.inbox`, currently absent) at each checkpoint.
- In this dry run, the setup and delivery steps (worktree, status-file writes, hold commands) are skipped as instructed.

## Verification
- The report reads on its own: every claim links to a command, measured output, screenshot, or `file:line`.
- Each candidate has been driven end to end (open, read, close, return) at both widths, by mouse and by keyboard, including Gamma's unavailable state. The recommended candidate shows the same `scrollY` and the original trigger focused after closing.
- The tutorial ran as written, and the result is recorded.

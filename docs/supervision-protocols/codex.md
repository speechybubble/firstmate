Mode: Codex native Stop-owned watcher.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   Handle the emitted events within existing authority and holds, then run the exact `WAKE_ACK_REQUIRED` acknowledgement.
   Native queue delivery never acknowledges durable work.
2. The asynchronous project Stop hook owns the next watcher cycle after the handling turn finishes.
   It binds the current native thread and home to verified session ownership, observes durable rows, status files and registered checks through the existing watcher, and delivers one coalesced native queue notification.
3. Do not manually rearm after ordinary notifications or start a background watcher from a tool.
   Follow `docs/watcher-continuity.md` for ownership and failure boundaries.
4. If the native Stop guard explicitly reports missing supervision, inspect the hook/delivery failure, drain pending work, and use one foreground checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"` as bounded recovery.
   Fully collect its result, including quiet exit 124, then drain and exactly acknowledge handled work.
   This checkpoint is a fallback, not a persistent successor.
5. Never use shell `&`, Codex background tasks, or direct `bin/fm-watch-arm.sh` calls for model-driven supervision.
   The PreToolUse seatbelt remains active.

The native Stop owner, `bin/fm-codex-stop-watch.sh`, owns the binding, notification bounds and delivery watermark.
Its synchronous guard waits briefly for verified watcher readiness while retaining its one-block loop limit.

The configured asynchronous hook lifetime is at most 86400 seconds per Stop.
A normally handled wake produces the next Stop, but quiet heartbeat absorption can leave a cycle waiting until that limit.
Expiry does not start a new turn or watcher by itself; status and poll coverage then stops until a subsequent native turn establishes another owner.
Catchable interruption writes an advisory and releases the owned lock; hard process-group termination can bypass shell cleanup, leaving stale evidence for the existing lock recovery.
Native 24-hour expiry has not been validated, so this path is not an indefinite supervision guarantee.

The owner attempts native delivery twice, bounded to 15 seconds each, without acknowledging any durable row.
A successor Stop waits up to 40 seconds for a previous hook to release ownership, covering overlap with those bounded attempts instead of silently dropping the successor.
Exhausting that wait records a visible failure without stealing the live owner.
A failure remains visible through the next fleet guard invocation; it cannot itself wake a parked model.
A delivery watermark prevents repeated notification of the same pending episode within one native generation, so an accepted message that the model fails to handle is not retried indefinitely.
An event appended between drain and acknowledgement retains its own sequence and remains pending.
When that row is immediately delivered at Stop, the synchronous watcher-readiness guard can still request its one bounded fallback checkpoint because no waiting watcher remains.
That fallback preserves handling but is a remaining coordination edge, not proof that the late path needs only asynchronous ownership.

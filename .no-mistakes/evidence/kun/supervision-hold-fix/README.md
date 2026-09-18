# Hold-race test evidence

Validated commit: acca470132ac3edc53a69d1e88fb0c357146b598.

The CLI and Pi transcripts contain only synthetic tasks and isolated homes created under this worktree. The CLI scripts and watcher were the real tracked executables. Pi used the installed SDK 0.85.1 with real extension loading, dispatch, sessions and watcher processes. No provider credentials, live fleet state, or model-powered worker tasks were used. Fake terminal transport was used where a worker endpoint was required. The watcher probe captured the real main input event and handled it before any model call. The branch race probe delayed real predicate executions without replacing their results.

- cli-transcript.log: main lease exclusion; durable hold blocks continuation and relaunch; main Escape; explicit release; post-grant hold; unreadable backlog; hold/send serialization; durable inbox and backlog output.
- pi-watch-transcript.log: real watcher signal and stale events route backlog-only held tasks to main; hold after primary acceptance rejects to main; main drains the preserved trigger and unrelated row.
- pi-transcript.log: real Pi branch rejects signal/stale post-acceptance holds and asynchronous two-task hold races; real main drain retains both rows.
- grant-serialization.log: publisher retains both task-control locks while waiting for the queue lock, and a concurrent hold finishes only after publication.
- generation-transcript.log: stale-generation publication and cleanup are refused without damaging the successor grant; current owner can clean up.

The four targeted suites ran through bin/fm-test-run.sh. The initial system Node 22 build lacked TypeScript support, causing the two Pi suites to fail at loading. Rerunning only those suites with the existing Node 24.14.0 binary passed. The send-inbox and wake-queue suites passed in the initial run. Logs are retained as targeted-suites.log and pi-suites-node24.log. Probe setup issues were corrected before the final successful transcripts: copied Pi helpers needed FM_OPERATIONAL_INPUT_SCRIPT pointing to the tracked script, extension tools needed noTools=builtin instead of tools=[], and stale-generation cleanup correctly expects refusal exit 1.

Manual drivers are included beside their transcripts. Python drivers run from the worktree root. Node drivers require a fresh FM_HOME inside the worktree, HOME and PI_CODING_AGENT_DIR pointed at that isolated home, FM_ROOT_OVERRIDE set to the worktree, FM_OPERATIONAL_INPUT_SCRIPT set to bin/fm-operational-input.sh, FM_GATE_REFUSE_BYPASS=1, NODE_NO_WARNINGS=1, and the existing Node 24 binary on PATH. The watcher probe additionally used FM_POLL=1, FM_SIGNAL_GRACE=0, and FM_HEARTBEAT=999999. All intentional temporary homes were removed after successful verification. Source was unchanged. No UI layout was changed, so evidence is CLI and Pi event transcripts rather than screenshots.

# Create an isolated task brief

Task: scaffold a local-only worker brief without dispatching, pushing, or changing a project.
Run from the tested worktree. Set `FM_HOME` to a disposable existing directory and use a disposable project directory as `$project`. Unset inherited `FM_ROOT_OVERRIDE`, `FM_DATA_OVERRIDE`, and `FM_STATE_OVERRIDE`; use a disposable `HOME` too.

1. Run `bin/fm-brief.sh tutorial "$project"`. Expect exit 1 explaining that ship briefs require a delivery mode, and no brief created.
2. Recover with `bin/fm-brief.sh tutorial "$project" --mode local-only`. Expect success and `$FM_HOME/data/tutorial/brief.md`.
3. Read that brief. Its fixed delivery contract is local-only; its product workflow pointer resolves to the tracked code root, not the operational home or destination. The scaffold still needs task intent and specification filled before dispatch. Do not spawn a worker in this exercise.
4. Run `bin/fm-brief.sh tutorial "$project" --mode direct-PR`. Expect refusal to overwrite; the original brief must remain byte-identical.
5. Recover using a fresh ID: `bin/fm-brief.sh tutorial-recovery "$project" --mode local-only`. Expect a second brief, without altering the first.

These commands are proposed until the companion live transcript records their execution. This is a caller-usability exercise of the real CLI, not a new CLI design or an authorization to run the delivery lifecycle.

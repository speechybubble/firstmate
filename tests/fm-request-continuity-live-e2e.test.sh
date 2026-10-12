#!/usr/bin/env bash
# Opt-in, credentialed semantic regression of AGENTS.md section 10 through real
# Pi RPC steering, normal model completion, actual backlog commands and real
# same-session compaction. A synthetic independent worker process and explicit
# completion wake exercise handling; no agent or runtime backend is launched.
# Run with the existing authenticated openai-codex/gpt-6-astra subscription.
# Semantic passes are observations, not guarantees for arbitrary future prompts.
# FM_REQUEST_CONTINUITY_EVIDENCE optionally preserves visible messages and the
# final backlog in a private directory; native model session files are excluded.
# FM_REQUEST_CONTINUITY_POLICY can select a preserved AGENTS.md for a controlled
# before/after comparison; it defaults to the current tracked contract.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_REQUEST_CONTINUITY_LIVE_E2E pi python3 tasks-axi
TMP_ROOT=$(fm_test_tmproot fm-request-continuity-live)
python3 "$ROOT/tests/fm-request-continuity-live.py" "$ROOT" "$TMP_ROOT/home"

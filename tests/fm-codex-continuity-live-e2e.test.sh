#!/usr/bin/env bash
# Opt-in real interactive Codex parked-continuity regression. Normal native
# folder/hook trust only; private file-store ChatGPT auth, removed in finally.
# Set FM_HERDR_LAB_PROTECTED_SESSION explicitly and FM_CODEX_TEST_AUTH when the
# local auth file is elsewhere. TMPDIR selects retained private fixture storage.
# No production lifecycle, operator queue/rearm, hook bypass or paid API.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_LIVE_E2E codex herdr jq python3
python3 "$ROOT/tests/fm-codex-stop-watch-live.py"

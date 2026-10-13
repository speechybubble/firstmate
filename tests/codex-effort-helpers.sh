#!/usr/bin/env bash
# Synthetic native Codex model/list fixtures for the focused effort callers.
# Source before shared fixtures when using the portable environment reset.

# Call before the shared fixtures load or any lifecycle operation. Portable
# callers must not inherit a real home, backend binary override or endpoint.
fm_test_codex_portable_environment() {
  local key
  while IFS= read -r key; do
    case "$key" in
      FM_TEST_*|FM_LIVE) ;;
      FM_*|HERDR_*|CMUX_*|ORCA_*|ZELLIJ*|TMUX*|CODEX_HOME|CLAUDE_CONFIG_DIR|GROK_HOME)
        unset "$key"
        ;;
    esac
  done < <(compgen -e)
  # Spawn suites require the outer pin; bootstrap's diagnostic cases instead
  # exercise their own config/backend with a PATH containing only test tools.
  [ "${1:-tmux}" = config ] || export FM_BACKEND=tmux
}

# Keep the shared fake-toolchain behavior, observing provisioning calls only
# when a case asks. The optional dead-pane response models a stopped task for
# relaunch; no real terminal/process group is inspected.
fm_test_codex_record_spawn_calls() {
  local fakebin=$1 tool
  for tool in tmux treehouse; do
    mv "$fakebin/$tool" "$fakebin/$tool.fixture"
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf 'fixture=%q\n' "$fakebin/$tool.fixture"
      printf 'tool=%q\n' "$tool"
      cat <<'SH'
if [ -n "${FM_TEST_CODEX_CALL_DIR:-}" ]; then
  printf '%s\n' "${1:-}" >> "$FM_TEST_CODEX_CALL_DIR/$tool.calls"
fi
if [ "$tool" = tmux ] && [ "${FM_TEST_CODEX_DEAD_PANE:-0}" = 1 ]; then
  case "$*" in
    *pane_current_command*) printf 'bash\n'; exit 0 ;;
    *pane_tty*) printf 'no-such-fixture-tty\n'; exit 0 ;;
  esac
fi
exec "$fixture" "$@"
SH
    } > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
}

fm_test_codex_catalog() {
  local path=$1
  cat > "$path" <<'JSON'
{"data":[
  {"model":"gpt-6.1-sol","supportedReasoningEfforts":[{"reasoningEffort":"medium"},{"reasoningEffort":"max"},{"reasoningEffort":"ultra"}]},
  {"model":"gpt-6-astra","supportedReasoningEfforts":[{"reasoningEffort":"medium"},{"reasoningEffort":"max"}]},
  {"model":"gpt-5.6-luna","supportedReasoningEfforts":[{"reasoningEffort":"medium"},{"reasoningEffort":"max"}]},
  {"model":"other-exact-model","supportedReasoningEfforts":[{"reasoningEffort":"max"}]},
  {"model":"gpt-5","supportedReasoningEfforts":[{"reasoningEffort":"high"}]}
],"nextCursor":null}
JSON
}

fm_test_fake_codex_discovery() {
  local fakebin=$1 catalog=$2
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'catalog_default=%q\n' "$catalog"
    cat <<'SH'
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'codex-cli 0.160.0 (fixture)'
  exit 0
fi
exec python3 - "${FM_TEST_CODEX_CATALOG:-$catalog_default}" 3<&0 <<'PY'
import json
import os
import sys

# stdin belongs to the protocol, so reopen fd 3 forwarded by the shell below.
mode = os.environ.get("FM_TEST_CODEX_NATIVE_MODE", "normal")
cwd_log = os.environ.get("FM_TEST_CODEX_NATIVE_CWD_LOG")
if cwd_log:
    with open(cwd_log, "a") as stream:
        stream.write(os.getcwd() + "\n")
if mode == "exit":
    sys.exit(1)
for line in os.fdopen(3):
    message = json.loads(line)
    method = message["method"]
    log = os.environ.get("FM_TEST_CODEX_NATIVE_LOG")
    if log:
        with open(log, "a") as stream:
            stream.write(method + "\n")
    if "id" not in message:
        continue
    ident = message["id"]
    if method == "initialize":
        result = {"userAgent": "codex-cli 0.160.0 (fixture)"}
    elif method == "account/read":
        result = {"account": None if mode == "account-null" else {"type": "chatgpt"}}
    elif method == "model/list":
        if mode == "malformed":
            print("{truncated", flush=True)
            sys.exit(0)
        if mode == "rpc-error":
            print(json.dumps({"id": ident, "error": {"code": -32000, "message": "private-secret-must-not-leak"}}), flush=True)
            continue
        with open(sys.argv[1]) as stream:
            result = json.load(stream)
        mutate = os.environ.get("FM_TEST_CODEX_MUTATE_CATALOG")
        if mutate:
            with open(mutate) as stream:
                replacement = stream.read()
            with open(sys.argv[1], "w") as stream:
                stream.write(replacement)
    else:
        sys.exit(2)
    print(json.dumps({"id": ident, "result": result}), flush=True)
PY
SH
  } > "$fakebin/codex"
  chmod +x "$fakebin/codex"
}

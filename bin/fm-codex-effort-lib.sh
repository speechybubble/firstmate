#!/usr/bin/env bash
# Account-scoped Codex max capability checks shared by spawn and dispatch.
# Source this library; it does not execute discovery at load time.
#
# fm_codex_effort_snapshot <existing-launch-directory>
#   Reads one bounded model/list snapshot from a fresh native stdio app-server
#   in that directory, using the same CODEX_HOME, account, config and
#   executable as the launch. Native discovery owns cache/version/account
#   applicability and may refresh its catalog. No login, model turn, shared
#   daemon or fleet endpoint is used.
# fm_codex_max_check <concrete-model>
#   Returns 0 supported, 1 unsupported, 2 unknown; FM_CODEX_EFFORT_REASON names
#   the result. Missing/default models and unusable or ambiguous evidence are
#   unknown. Only an exact native model and explicit advertised max pass.
# fm_codex_max_profiles <validated-profile-file> <discovery-directory>
#   Checks every declared Codex max profile against one snapshot taken in the
#   discovery directory. An unknown profile is never selected around,
#   including in a profile array.
#
# Globals: FM_CODEX_EFFORT_MODELS (operation-local JSON, never persisted),
#   FM_CODEX_EFFORT_REASON. Raw diagnostics/account data are never printed.
# Requires jq and Python 3 for discovery. The native subprocess has a 15-second
#   total deadline and 4 MiB output bound; unsupported protocol is unknown.

FM_CODEX_EFFORT_MODELS=
FM_CODEX_EFFORT_REASON='native Codex capability discovery has not run'

fm_codex_effort_snapshot() {
  local directory=$1 binary result
  FM_CODEX_EFFORT_MODELS=
  FM_CODEX_EFFORT_REASON='unable to verify Codex max: native discovery unavailable; open the native model picker, verify the account and retry'
  binary=$(command -v codex 2>/dev/null) || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  result=$(python3 - "$binary" "$directory" <<'PY'
import json
import os
import selectors
import signal
import subprocess
import sys
import time

# The native API owns provider/account filtering and cache applicability.
# Retain only model identifiers and advertised efforts, never account values.
process = None
selector = None
try:
    process = subprocess.Popen(
        [sys.argv[1], "--disable", "hooks", "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        cwd=sys.argv[2], start_new_session=True,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 15
    pending = b""
    total = 0

    def object_unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate native response field")
            result[key] = value
        return result

    def send(method, params, ident=None):
        message = {"method": method, "params": params}
        if ident is not None:
            message["id"] = ident
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()

    def receive(ident):
        global pending, total
        while time.monotonic() < deadline:
            while b"\n" in pending:
                raw, pending = pending.split(b"\n", 1)
                if not raw:
                    continue
                message = json.loads(raw, object_pairs_hook=object_unique)
                if not isinstance(message, dict):
                    raise ValueError("invalid native message")
                if message.get("id") == ident:
                    if "error" in message or "result" not in message:
                        raise ValueError("native discovery refused")
                    return message["result"]
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > 4 * 1024 * 1024:
                raise ValueError("native response exceeds bound")
            pending += chunk
        raise ValueError("native discovery deadline")

    send("initialize", {"clientInfo": {"name": "fm-effort-check", "version": "1"}}, 1)
    receive(1)
    send("initialized", {})
    send("account/read", {"refreshToken": False}, 2)
    account = receive(2)
    if not isinstance(account, dict) or not isinstance(account.get("account"), dict):
        raise ValueError("native account unavailable")
    if account["account"].get("type") not in ("chatgpt", "apiKey"):
        raise ValueError("native account not established")
    # Request one complete snapshot, rather than mixing changing catalog pages.
    send("model/list", {"includeHidden": True, "limit": 4294967295}, 3)
    result = receive(3)
    if not isinstance(result, dict) or not isinstance(result.get("data"), list):
        raise ValueError("unknown native model schema")
    if result.get("nextCursor") is not None:
        raise ValueError("incomplete native model snapshot")
    models = []
    for model in result["data"]:
        if not isinstance(model, dict):
            raise ValueError("unknown native model schema")
        models.append({"model": model.get("model"), "efforts": model.get("supportedReasoningEfforts")})
    print(json.dumps(models))
except Exception:
    # Vendor/config diagnostics may contain credentials. Emit no raw error.
    sys.exit(2)
finally:
    if selector is not None:
        selector.close()
    if process is not None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        except ProcessLookupError:
            process.wait()
PY
  ) || return 2
  FM_CODEX_EFFORT_MODELS=$result
  return 0
}

fm_codex_max_check() {
  local model=$1 verdict label
  case "$model" in
    ''|default)
      FM_CODEX_EFFORT_REASON='unable to verify Codex max: a concrete --model is required'
      return 2
      ;;
  esac
  [ -n "$FM_CODEX_EFFORT_MODELS" ] || return 2
  verdict=$(printf '%s' "$FM_CODEX_EFFORT_MODELS" | jq -r --arg model "$model" '
    if type != "array" or length == 0 then "unknown"
    elif any(.[]; (.model | type) != "string" or (.model | length) == 0) then "unknown"
    elif (map(.model) | length) != (map(.model) | unique | length) then "unknown"
    else [ .[] | select(.model == $model) ] as $matches
      | if ($matches | length) == 0 then "unsupported"
        elif ($matches[0].efforts | type) != "array" or ($matches[0].efforts | length) == 0 then "unknown"
        elif any($matches[0].efforts[]; type != "object" or (.reasoningEffort | type) != "string" or (.reasoningEffort | length) == 0) then "unknown"
        elif any($matches[0].efforts[]; .reasoningEffort == "max") then "supported"
        else "unsupported" end
    end
  ' 2>/dev/null) || verdict=unknown
  label=$(printf '%s' "$model" | jq -Rs .)
  case "$verdict" in
    supported)
      FM_CODEX_EFFORT_REASON="native Codex advertises max for $label"
      return 0
      ;;
    unsupported)
      FM_CODEX_EFFORT_REASON="unsupported Codex max for $label: not advertised by native model discovery"
      return 1
      ;;
    *)
      FM_CODEX_EFFORT_REASON="unable to verify Codex max for $label: native capability data is unusable or ambiguous; verify native model discovery and retry"
      return 2
      ;;
  esac
}

fm_codex_max_profiles() {
  local file=$1 directory=$2 models encoded model status
  models=$(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [((.rules // [])[] | profiles(.use)[]), profiles(.default // null)[]]
    | map(select(.harness == "codex" and .effort == "max") | (.model // "default"))
    | unique | .[] | @base64
  ' "$file") || return 2
  [ -n "$models" ] || return 0
  fm_codex_effort_snapshot "$directory" || true
  while IFS= read -r encoded; do
    model=$(printf '%s' "$encoded" | jq -Rr '@base64d') || return 2
    fm_codex_max_check "$model" && continue
    status=$?
    return "$status"
  done <<< "$models"
}

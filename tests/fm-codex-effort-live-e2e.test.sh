#!/usr/bin/env bash
# Native Codex resolved-profile guard using the flags captured from fm-spawn.
# No model prompt or fleet endpoint is used. A private file-auth home pins a
# medium default, so omitting explicit max cannot be masked by user defaults.
# thread/start is structural resolved-configuration evidence, not a receipt
# for server-side reasoning or account entitlement. Discovery is native too.
# Set FM_CODEX_EFFORT_LIVE=1 to require this guard, or =0 to disable it.
# The model defaults to the first one native discovery advertises max for, so
# account catalog changes cannot turn a stale model name into a false failure;
# FM_CODEX_EFFORT_MODEL pins one explicitly. A listed model without max proves
# the live refusal before launch.
set -u

NATIVE_HOME=${CODEX_HOME:-$HOME/.codex}
LIVE_REQUEST=${FM_CODEX_EFFORT_LIVE:-}
TEST_MODEL=${FM_CODEX_EFFORT_MODEL:-}
# shellcheck source=tests/codex-effort-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/codex-effort-helpers.sh"
fm_test_codex_portable_environment
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
export FM_CODEX_EFFORT_LIVE=$LIVE_REQUEST
fm_live_gate default-on FM_CODEX_EFFORT_LIVE codex python3 jq
CODEX_BIN=$(command -v codex)
CODEX_VERSION=$("$CODEX_BIN" --version 2>&1) || fail "Codex version probe failed"
TMP_ROOT=$(fm_test_tmproot fm-codex-effort-live)
CODEX_TEST_HOME="$TMP_ROOT/native home"
mkdir -m 700 "$CODEX_TEST_HOME"

# Copy only native auth/cache input, never global configuration, plugins or
# transcripts. Credential bytes and raw account responses never reach output.
# Model selection discovers in its own copy: native discovery writes state
# into its home, and the guard's home must stay pristine for the omitted case.
CODEX_SELECT_HOME="$TMP_ROOT/select home"
mkdir -m 700 "$CODEX_SELECT_HOME"
for name in auth.json models_cache.json; do
  if [ -f "$NATIVE_HOME/$name" ]; then
    for dest in "$CODEX_TEST_HOME" "$CODEX_SELECT_HOME"; do
      cp "$NATIVE_HOME/$name" "$dest/$name" || fail "cannot stage private native input"
      chmod 600 "$dest/$name"
    done
  fi
done

# shellcheck source=bin/fm-codex-effort-lib.sh
. "$ROOT/bin/fm-codex-effort-lib.sh"
CODEX_HOME="$CODEX_SELECT_HOME" fm_codex_effort_snapshot discover "$TMP_ROOT" ||
  fail "codex $CODEX_VERSION: native account-scoped model discovery unavailable"
if [ -z "$TEST_MODEL" ]; then
  TEST_MODEL=$(printf '%s' "$FM_CODEX_EFFORT_MODELS" | jq -r '
    first(.[] | select(any(.efforts[]?; .reasoningEffort == "max")) | .model) // empty')
  [ -n "$TEST_MODEL" ] || fail "codex $CODEX_VERSION: native discovery advertises max for no model"
fi
NO_MAX_MODEL=$(printf '%s' "$FM_CODEX_EFFORT_MODELS" | jq -r '
  first(.[] | select((.efforts | type) == "array" and (.efforts | length) > 0
    and all(.efforts[]; .reasoningEffort != "max")) | .model) // empty')

python3 - "$CODEX_TEST_HOME/config.toml" "$TEST_MODEL" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(
    'model = ' + json.dumps(sys.argv[2]) + '\n'
    'model_reasoning_effort = "medium"\n'
    'cli_auth_credentials_store = "file"\n'
    '[features]\nplugins = false\n'
)
PY

for effort in omitted medium max; do
  case_dir="$TMP_ROOT/$effort"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="codex-effort-$effort"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$effort"
  args=(--mode no-mistakes --yolo off --model "$TEST_MODEL")
  [ "$effort" = omitted ] || args+=(--effort "$effort")
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  CODEX_HOME="$CODEX_TEST_HOME" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "${args[@]}" \
    > "$case_dir/spawn.log" 2>&1 ||
    fail "codex $CODEX_VERSION: could not capture $effort profile (native max discovery must be available)"
  CODEX_HOME="$CODEX_TEST_HOME" python3 - "$CODEX_BIN" "$launchlog" "$wt" "$effort" "$TEST_MODEL" <<'PY' || fail "codex $CODEX_VERSION: captured $effort profile failed native resolution"
import json
import os
import pathlib
import selectors
import shlex
import signal
import subprocess
import sys
import time

binary, launchfile, cwd, requested, model = sys.argv[1:]
process = None
selector = None
try:
    # Parse argv as data; never execute the shell brief/notify substitutions.
    words = shlex.split(pathlib.Path(launchfile).read_text())
    start = words.index('codex') + 1
    flags = []
    for word in words[start:]:
        if word.startswith('$('):
            break
        flags.append(word)
    else:
        raise ValueError('missing positional brief boundary')
    effort_config = [flags[i+1] for i, flag in enumerate(flags[:-1])
                     if flag == '-c' and flags[i+1].startswith('model_reasoning_effort=')]
    expected = 'medium' if requested == 'omitted' else requested
    if requested == 'omitted':
        assert not effort_config, 'omitted effort acquired an override'
    else:
        assert effort_config == ['model_reasoning_effort="' + requested + '"'], 'wrong captured override'
    process = subprocess.Popen(
        [binary, *flags, 'app-server', '--listen', 'stdio://'],
        cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, start_new_session=True,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = b''
    total = 0
    deadline = time.monotonic() + 30

    def send(method, params, ident=None):
        message = {'method': method, 'params': params}
        if ident is not None:
            message['id'] = ident
        process.stdin.write((json.dumps(message) + '\n').encode())
        process.stdin.flush()

    def receive(ident):
        global pending, total
        while time.monotonic() < deadline:
            while b'\n' in pending:
                raw, pending = pending.split(b'\n', 1)
                if not raw:
                    continue
                message = json.loads(raw)
                if message.get('id') == ident:
                    if 'error' in message:
                        raise ValueError('native RPC refused')
                    return message['result']
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > 4 * 1024 * 1024:
                raise ValueError('native output exceeds bound')
            pending += chunk
        raise ValueError('native deadline or process exit')

    send('initialize', {'clientInfo': {'name': 'fm-effort-live', 'version': '1'}}, 1)
    receive(1)
    send('initialized', {})
    send('thread/start', {'ephemeral': True, 'cwd': cwd}, 2)
    result = receive(2)
    assert result.get('model') == model, 'resolved model differs'
    assert result.get('reasoningEffort') == expected, 'resolved effort differs'
    print('ok - native captured ' + requested + ' profile resolves model=' + model + ' effort=' + expected)
except Exception:
    # Vendor errors may contain private config/account data. Never print them.
    sys.exit(1)
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
done

if [ -n "$NO_MAX_MODEL" ]; then
  case_dir="$TMP_ROOT/refuse"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=codex-effort-refuse
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" wt-refuse
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  if CODEX_HOME="$CODEX_TEST_HOME" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
      --mode no-mistakes --yolo off --model "$NO_MAX_MODEL" --effort max \
      > "$case_dir/spawn.log" 2>&1; then
    fail "codex $CODEX_VERSION: max for $NO_MAX_MODEL launched although native discovery omits it"
  fi
  grep -q 'unsupported Codex max' "$case_dir/spawn.log" ||
    fail "codex $CODEX_VERSION: max refusal for $NO_MAX_MODEL lacks the unsupported reason"
  [ ! -s "$launchlog" ] || fail "codex $CODEX_VERSION: refused max still reached a launch"
  printf 'ok - native discovery omits max for model=%s; explicit max refuses before launch\n' "$NO_MAX_MODEL"
else
  printf '# native discovery lists no model without max; live refusal arm not exercised\n'
fi

printf 'ok - codex %s: captured max overrides the isolated medium default; omitted/medium neighbors preserved\n' "$CODEX_VERSION"
printf '# resolved native configuration only; no model turn or server-side reasoning claim\n'
printf '# all fm-codex-effort-live-e2e tests passed\n'

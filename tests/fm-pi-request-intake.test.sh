#!/usr/bin/env bash
# Real Pi session/extension regression with an in-process scripted provider.
# No credentials, network request, worker, backend or live home is used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_PI_REQUEST_INTAKE_E2E npm node tasks-axi
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo 'skip: native intake requires installed Pi'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-pi-request-intake)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/home"
agentdir="$TMP_ROOT/agent"
mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state" "$home/data" "$home/config" "$agentdir"
cp "${FM_REQUEST_INTAKE_GUARD:-$ROOT/.pi/extensions/fm-primary-turnend-guard.ts}" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-request-continuity.ts" \
  "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$repo/.pi/extensions/lib/"
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
cp "$ROOT/.tasks.toml" "$home/"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for script in fm-sessionstart-run.sh fm-turnend-guard.sh fm-cd-pretool-check.sh fm-arm-pretool-check.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/$script"
  chmod +x "$repo/bin/$script"
done
cat > "$repo/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
exec bash "${FM_REAL_ROOT:?}/bin/fm-tasks-axi.sh" "$@"
SH
chmod +x "$repo/bin/fm-tasks-axi.sh"
# ResourceLoader.reload reloads settings from storage. Persist fixture settings
# here instead of an applyOverrides call that that lifecycle correctly drops.
printf '%s\n' '{"compaction":{"enabled":false,"keepRecentTokens":100,"reserveTokens":1024}}' > "$agentdir/settings.json"
cat > "$agentdir/models.json" <<'JSON'
{"providers":{"fm-intake":{"baseUrl":"https://fm-intake.invalid/v1","api":"openai-completions","apiKey":"local-placeholder","models":[{"id":"fixture","contextWindow":32768,"maxTokens":1024}]}}}
JSON
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_SUPERVISION_ACTOR
FM_HOME="$home" FM_REAL_ROOT="$ROOT" FM_INTAKE_REPO="$repo" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  PI_CODING_AGENT_DIR="$agentdir" node "$ROOT/tests/fm-pi-request-intake.mjs" > "$TMP_ROOT/result" 2>&1
status=$?
cat "$TMP_ROOT/result"
expect_code 0 "$status" 'native intake must recover omitted dispositions through topic changes and compaction'
pass 'real Pi native input retains omitted obligations without manufacturing task state or endless recovery'

# Separate native session and home: exercise the branch processing exit path.
outcomehome="$TMP_ROOT/outcome-home"
mkdir -p "$outcomehome/state" "$outcomehome/data" "$outcomehome/config" "$repo/node_modules/@earendil-works"
cp "$ROOT/.tasks.toml" "$outcomehome/"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$repo/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/"*.ts "$repo/.pi/extensions/lib/"
ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"
FM_HOME="$outcomehome" FM_ROOT_OVERRIDE="$ROOT" FM_REAL_ROOT="$ROOT" \
  BRANCH_PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  PI_CODING_AGENT_DIR="$agentdir" node "$ROOT/tests/fm-pi-outcome-delivery.mjs" > "$TMP_ROOT/outcome-result" 2>&1
status=$?
cat "$TMP_ROOT/outcome-result"
expect_code 0 "$status" 'native outcome acknowledgement must retain owner review and delivery obligations'

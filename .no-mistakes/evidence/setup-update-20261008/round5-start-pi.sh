#!/usr/bin/env bash
set -eu
cd /home/denni/.no-mistakes/worktrees/21e8d67b590b/01M4F48ADCJ5DDZHPHWBMZXC4N
source .test-fix/env.sh
export HERDR_SESSION=fm-lab-f5
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
exec /home/denni/kun-validation/update-20261008/pi-runtime/node_modules/.bin/pi --offline --no-extensions --no-skills --no-context-files --no-prompt-templates --no-mcp --no-themes --no-approve --provider openai-codex --model gpt-6-astra -e "$PWD/.pi/extensions/fm-primary-pi-watch.ts" -e "$PWD/.pi/extensions/fm-branch-supervision.ts"

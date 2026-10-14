#!/usr/bin/env bash
set -eu
# shellcheck source=tests/env-isolation-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/env-isolation-helpers.sh"

python3 "$(dirname "${BASH_SOURCE[0]}")/fm-observation-boundaries.test.py"

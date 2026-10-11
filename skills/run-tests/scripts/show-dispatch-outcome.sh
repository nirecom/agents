#!/usr/bin/env bash
# show-dispatch-outcome.sh --session <sid>
# WD-BG result display: the latest test-runner dispatch outcome, re-rendered as the
# foreground dispatch YAML. Read-only. Exit: 0 after a valid call; 2 usage error.

set -uo pipefail

exec node "$(dirname "${BASH_SOURCE[0]}")/show-dispatch-outcome.js" "$@"

#!/usr/bin/env bash
# Check that a test entrypoint, new or existing, runs under its language's required runner (#2863,
# #2865: the logic lives in check-test-runner/cli.js; this adapter keeps the bash entry point).
# Usage: check-test-runner.sh [--rel <rel> [--head <path>]] <file1> [file2 ...] (--head is ignored)
# Exit 0: no HIGH. Exit 1: HIGH found or no arguments. Exit 2: a non-existent path, a skip-reason
# op failure, --rel with more than one file, --head without a value, or no node on PATH.
set -euo pipefail
if ! command -v node >/dev/null 2>&1; then echo "check-test-runner.sh: node not found on PATH; install Node.js to run the required-runner check" >&2; exit 2; fi
cli="$(dirname "${BASH_SOURCE[0]}")/check-test-runner/cli.js"
if [[ ! -f "$cli" ]]; then echo "check-test-runner.sh: predicate library unavailable ($cli not found)" >&2; exit 2; fi
exec node "$cli" "$@"

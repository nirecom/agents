#!/usr/bin/env bash
# Check case-marker placement in test files that cover multiple Tests: paths (#2507 D7: the logic
# lives in check-case-markers/cli.js; this adapter keeps the bash entry point).
# Usage: check-case-markers.sh [--rel <rel>] <file1> [file2 ...]
# Exit 0: no HIGH. Exit 1: HIGH found, no arguments, or a non-existent path. Exit 2: a reader part
# unavailable, --rel with more than one file, or no node on PATH.
if ! command -v node >/dev/null 2>&1; then echo "check-case-markers.sh: node not found on PATH; install Node.js to run the case-marker check" >&2; exit 2; fi
cli="$(dirname "${BASH_SOURCE[0]}")/check-case-markers/cli.js"
if [ ! -f "$cli" ]; then echo "check-case-markers.sh: predicate library unavailable ($cli not found)" >&2; exit 2; fi
exec node "$cli" "$@"

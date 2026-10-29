#!/usr/bin/env bash
# Report a test written in another language than the code it tests, after validating the
# test-lang-exception declaration that lets one through (#2507 D7: the logic lives in
# check-test-language-match/cli.js; this adapter keeps the bash entry point).
# Usage: check-test-language-match.sh [--rel <rel>] [--head <head-copy>] <file>...
# Exit 0: no HIGH. 1: HIGH found. 2: usage, a missing file, the registry unavailable or no node.
if ! command -v node >/dev/null 2>&1; then echo "check-test-language-match.sh: node not found on PATH; install Node.js to run the language-match check" >&2; exit 2; fi
cli="$(dirname "${BASH_SOURCE[0]}")/check-test-language-match/cli.js"
if [ ! -f "$cli" ]; then echo "check-test-language-match.sh: predicate library unavailable ($cli not found)" >&2; exit 2; fi
exec node "$cli" "$@"

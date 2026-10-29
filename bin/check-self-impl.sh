#!/usr/bin/env bash
# Report a test that builds its own harness through the caseEmbedRules self-impl op (#2507 D7: the
# logic lives in check-self-impl/cli.js; this adapter keeps the bash entry point).
# Usage: check-self-impl.sh [--rel <rel>] [--head <head-copy>] <file>... | --manifest <manifest>
# Exit 0: no HIGH. Exit 1: HIGH. Exit 2: usage, a missing file, the registry unavailable, an op
# failure, or no node on PATH.
if ! command -v node >/dev/null 2>&1; then echo "check-self-impl.sh: node not found on PATH; install Node.js to run the self-impl check" >&2; exit 2; fi
cli="$(dirname "${BASH_SOURCE[0]}")/check-self-impl/cli.js"
if [ ! -f "$cli" ]; then echo "check-self-impl.sh: predicate library unavailable ($cli not found)" >&2; exit 2; fi
exec node "$cli" "$@"

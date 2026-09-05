#!/usr/bin/env bash
# Tests: skills/review-tests/SKILL.md, rules/shell-commands.md
# Tags: rules, prompt, dispatch, fork, claude-e2e, TL3, scope:issue-specific
#
# THE MECHANISM (#2140/#2141): does a real model, given review-tests' top-of-Procedure
# directive verbatim in a fork-like isolated fixture, actually Read rules/shell-commands.md
# before its first Bash command -- and does removing the directive stop that being guaranteed?
# Static proof of the skill's own TEXT lives in tests/feature-2140-fork-dispatch-shell-commands.sh;
# this gate is the live-model counterpart.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

IMPL_MISSING=0
for f in "$AGENTS_DIR/skills/review-tests/SKILL.md" \
         "$AGENTS_DIR/rules/shell-commands.md" \
         "$AGENTS_DIR/bin/run-with-timeout.sh"; do
    [ -f "$f" ] || { echo "FAIL: IMPLEMENTATION MISSING: $f"; IMPL_MISSING=1; }
done
if [ "$IMPL_MISSING" -eq 1 ]; then
    echo ""
    echo "1 test(s) failed (targets not yet implemented)"
    exit 1
fi

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77
command -v jq >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
skip() { echo "SKIP: $1" >&2; }

# shellcheck source=tests/TL3-review-tests-fork-directive-order/helpers.sh
. "$AGENTS_DIR/tests/TL3-review-tests-fork-directive-order/helpers.sh"
# shellcheck source=tests/TL3-review-tests-fork-directive-order/main.sh
. "$AGENTS_DIR/tests/TL3-review-tests-fork-directive-order/main.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi

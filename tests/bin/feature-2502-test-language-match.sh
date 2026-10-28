#!/usr/bin/env bash
# tests/bin/feature-2502-test-language-match.sh
# Tests: bin/check-test-language-match.sh, bin/lib/test-language-match.sh
# Tags: TL2, bin, test-language-match, test-lang-exception, test-language-registry, scope:issue-specific
# Issue #2502 S4: the judgment table of bin/check-test-language-match.sh, driven with bash tests
# and JavaScript code. A test written in one language whose target is code of another is a
# mismatch; a valid test-lang-exception suppresses it, an invalid one is reported on its own and
# suppresses nothing. For a file HEAD already has, only a mismatch HEAD did not have blocks.
# Cases live in the sibling directory: new-file.sh, languages.sh (all four languages) and existing-file.sh.
# The fixture repo and the body / lm helpers are in the sibling _lib.sh (shared with
# tests/bin/feature-2502-case-addition.sh).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-test-language-match"
# shellcheck source=feature-2502-test-language-match/_lib.sh
. "$CASE_DIR/_lib.sh"

case_begin "lm-cli-and-lib-present" "bin/lib/test-language-match.sh"
if [ -f "$LM_CLI_REAL" ] && [ -f "$LM_LIB" ]; then
  pass "CLI and lib exist"
else
  fail "CLI and lib" "missing: $LM_CLI_REAL or $LM_LIB"
fi
case_end

# shellcheck source=feature-2502-test-language-match/new-file.sh
. "$CASE_DIR/new-file.sh"
# shellcheck source=feature-2502-test-language-match/languages.sh
. "$CASE_DIR/languages.sh"
# shellcheck source=feature-2502-test-language-match/existing-file.sh
. "$CASE_DIR/existing-file.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

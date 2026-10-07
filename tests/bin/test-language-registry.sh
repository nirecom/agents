#!/usr/bin/env bash
# tests/bin/test-language-registry.sh
# Tests: hooks/lib/test-language-registry.js, bin/test-language-registry, bin/lib/test-language-registry.sh, bin/lib/run-all-launch.sh, bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/case-parser.sh, bin/check-table-driven.sh, bin/lib/run-tests-baseline-exec.sh, bin/mutation-probe.sh
# Tags: TL2, bin, hooks, test-language-registry, parity, glob, launch, scope:common
# The test language registry owns which file names are tests and how each is run.
# Cases live in tests/bin/test-language-registry/*.sh; fake languages exist only in
# fixtures/*.json, installed as the default table of a fixture checkout (no env override).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
export RUN_ALL_DURATIONS_LIB=/nonexistent RUN_ALL_PROGRESS=off

# shellcheck source=test-language-registry/_lib.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/_lib.sh"

case_begin "registry-files-present" "hooks/lib/test-language-registry.js"
for f in "$CLI" "$LOADER" "$READER" "$TABLE"; do
  if [ -f "$f" ]; then
    pass "present: ${f#"$AGENTS_DIR/"}"
  else
    fail "present: ${f#"$AGENTS_DIR/"}" "missing — the cases that use it fail too"
  fi
done
case_end

# shellcheck source=test-language-registry/validation.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/validation.sh"
# shellcheck source=test-language-registry/reader.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/reader.sh"
# shellcheck source=test-language-registry/loader.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/loader.sh"
# shellcheck source=test-language-registry/parity.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/parity.sh"
# shellcheck source=test-language-registry/parts.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/parts.sh"
# shellcheck source=test-language-registry/launch.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/launch.sh"
# shellcheck source=test-language-registry/mutation.sh
. "$AGENTS_DIR/tests/bin/test-language-registry/mutation.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

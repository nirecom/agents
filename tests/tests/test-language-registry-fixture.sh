#!/usr/bin/env bash
# tests/tests/test-language-registry-fixture.sh
# Tests: tests/lib/test-language-registry-fixture.sh
# Tags: test-infrastructure, test-language-registry, shared-lib, fixture, scope:common, pwsh-not-required, TL2
# TL3 gap: whether every consumer calls the helper instead of a hand copy (residue check owns it).
# Pins the helper's own contract (#2500): default source root, a loadable set, parts registered
# outside the parts dir, and loud failure instead of a half-installed fixture.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"

WORK="$(make_tmp)"
trap 'rm -rf "$WORK"' EXIT

# loads <root> — "ok" when the installed loader reads its sibling table.
loads() {
  if bash -c '. "$1/bin/lib/test-language-registry.sh" && tlr_load' _ "$1" >/dev/null 2>&1; then
    echo ok
  else
    echo fail
  fi
}

case_begin "default-source-installs-loadable-set" "tests/lib/test-language-registry-fixture.sh"
DEF="$WORK/default"
rc=0; install_test_language_registry "$DEF" || rc=$?
assert_eq "$rc" "0"
assert_eq "$(loads "$DEF")" "ok"
case_end

case_begin "registered-part-outside-parts-dir-copied" "tests/lib/test-language-registry-fixture.sh"
# Every "file" the real table names must exist in the fixture, wherever it lives.
missing=""
while IFS= read -r rel; do
  [ -f "$DEF/$rel" ] || missing="$missing $rel"
done < <(grep -o '"file"[[:space:]]*:[[:space:]]*"[^"]*"' "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json" \
  | sed 's/.*"\([^"]*\)"$/\1/')
assert_eq "missing=[${missing# }]" "missing=[]"
case_end

case_begin "missing-source-file-fails-loudly" "tests/lib/test-language-registry-fixture.sh"
SRC="$WORK/src-no-cli"
install_test_language_registry "$SRC" >/dev/null 2>&1
rm -f "$SRC/bin/test-language-registry"
rc=0; err="$(install_test_language_registry "$WORK/dst-no-cli" "$SRC" 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "1"
case "$err" in
  *"missing source"*"bin/test-language-registry"*) pass "stderr names the missing file" ;;
  *) fail "stderr names the missing file" "err=<<$err>>" ;;
esac
assert_eq "$([ -e "$WORK/dst-no-cli/bin/lib/test-language-registry.sh" ] && echo partial || echo none)" "none"
case_end

case_begin "no-parts-fails-loudly" "tests/lib/test-language-registry-fixture.sh"
SRC2="$WORK/src-no-parts"
install_test_language_registry "$SRC2" >/dev/null 2>&1
rm -f "$SRC2"/bin/lib/test-language-parts/*.sh
rc=0; err="$(install_test_language_registry "$WORK/dst-no-parts" "$SRC2" 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "1"
case "$err" in
  *"no parts under"*) pass "stderr reports the empty parts dir" ;;
  *) fail "stderr reports the empty parts dir" "err=<<$err>>" ;;
esac
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

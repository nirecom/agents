#!/usr/bin/env bash
# tests/bin/feature-2502-case-embed-order.sh
# Tests: bin/lib/test-language-parts/pester-case-embed.sh, bin/lib/test-language-parts/pytest-case-embed.sh, bin/lib/test-language-parts/js-case-embed.sh
# Tags: TL2, bin, case-markers, test-language-registry, sweep-tests, pester, pytest, js, scope:issue-specific
# The pester, pytest and js caseEmbedRules parts (#2502 S1). Here: the case-order contract —
# a stub analyzer whose ORDER lines move every range (shift) or report only case 0 (short)
# makes the deps op return 1 with `case-embed: order mismatch`, and crr_read answers
# `FILE uncertain case-embed` with no CASE line (S1-3b). Sibling parts: deps.sh (the deps op contract),
# cache.sh (the pester CASE_EMBED_CACHE_DIR cache); helpers and fixtures: _lib.sh, fixtures.sh.
# TL3 gap: real corpus files (dot-sourced helpers, conftest.py fixtures, re-exported js helpers) are only met when the first band is embedded.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
export HOME="$TMPBASE/home"
mkdir -p "$HOME"
export NO_LOG=true
harness_isolate "$TMPBASE/state"
unset CASE_EMBED_CACHE_DIR

# fx_checkout / path_without: the registry suite's helpers (one owner).
# shellcheck source=test-language-registry/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/test-language-registry/_lib.sh"
CASE_DIR_EMBED="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-case-embed-order"
# shellcheck source=feature-2502-case-embed-order/_lib.sh
. "$CASE_DIR_EMBED/_lib.sh"

# One base checkout; each language's stub checkout is a copy of it (its .git included).
BASE="$TMPBASE/co-base"
embed_checkout "$BASE"

# check_order_mismatch <id>
check_order_mismatch() {
  local id="$1" mode co="$TMPBASE/co-stub-$1" c out lines
  need_rt "$id" || return 0
  cp -R "$BASE" "$co"
  cp "$FXD/$L_STUB" "$co/$PARTS/$L_ANALYZER"
  for mode in shift short; do
    export STUB_ORDER="$mode" STUB_B0="$L_B0" STUB_E0="$L_E0"
    out="$(batch "$co" "$co/$L_REL" - "$id" "deps FILE")"
    assert_eq "$id $mode: deps op rc=$(sect_rc "$out" "deps FILE")" "$id $mode: deps op rc=1"
    case "$(cat "$TMPBASE/b.1.err")" in
      *"case-embed: order mismatch"*) pass "$id $mode: stderr names the mismatch" ;;
      *) fail "$id $mode: stderr names the mismatch" "stderr=[$(head -c 200 "$TMPBASE/b.1.err")]" ;;
    esac
    lines="$(sect "$out" crr)"
    # S1-3b: a deps op that fails makes the version uncertain, and crr_read prints no CASE line.
    assert_eq "$id $mode: crr_read rc=$(sect_rc "$out" crr) FILE=$(file_line "$lines")" "$id $mode: crr_read rc=0 FILE=uncertain||case-embed"
    assert_eq "$id $mode: first CASE line deps=$(deps_of "$lines" 0)" "$id $mode: first CASE line deps=<none>"
  done
  unset STUB_ORDER STUB_B0 STUB_E0
}

case_begin "pester-order-mismatch" "bin/lib/test-language-parts/pester-case-embed.sh"
check_order_mismatch pester
case_end

case_begin "pytest-order-mismatch" "bin/lib/test-language-parts/pytest-case-embed.sh"
check_order_mismatch pytest
case_end

case_begin "js-order-mismatch" "bin/lib/test-language-parts/js-case-embed.sh"
check_order_mismatch js
case_end

# shellcheck source=feature-2502-case-embed-order/deps.sh
. "$CASE_DIR_EMBED/deps.sh"
# shellcheck source=feature-2502-case-embed-order/cache.sh
. "$CASE_DIR_EMBED/cache.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

#!/usr/bin/env bash
# Tests: bin/lib/concern-ledger/core.sh, bin/run-codex-review-loop
# Tags: feature-2478, concern-ledger, producer-allowlist, cc-fallback, prestaged, scope:issue-specific, TL2
#
# #2478 T5 (S2): each path-kind format admits exactly its codex reviewer and its CC-fallback
# reviewer agent as ledger producers, so a fallback round stages under a closed, provenance-bound
# name and any third producer is refused by the loop. review-security-shared keeps its own pair
# and no format declares a mandatory producer.
# TL3 gap: none beyond TL2 — the producer set is a pure function and the refusal is the real loop.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"

LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/concern-ledger.sh"
# producer_set <fn> <fmt> — the function's output as one space-joined line.
producer_set() {
    local out
    out="$(bash -c 'set +u; source "$1" >/dev/null 2>&1 || exit 127; "$2" "$3"' _ "$LIB" "$1" "$2" 2>/dev/null \
        | tr -d '\r' | tr '\n' ' ')"
    printf '%s' "${out%"${out##*[![:space:]]}"}"
}
# producer_lines <fmt> — how many lines cl_allowed_producers prints.
producer_lines() {
    bash -c 'set +u; source "$1" >/dev/null 2>&1 || exit 127; cl_allowed_producers "$2"' _ "$LIB" "$1" 2>/dev/null | grep -c .
}

echo "=== T5: the allowed producers of each path-kind format ==="
case_begin "test-review-admits-codex-and-test-reviewer" "bin/lib/concern-ledger/core.sh"
assert_eq "test-review: allowed set" "review-plan-codex test-reviewer" "$(producer_set cl_allowed_producers test-review)"
assert_eq "test-review: exactly two lines" "2" "$(producer_lines test-review)"
case_end

case_begin "security-plan-admits-codex-and-plan-security-reviewer" "bin/lib/concern-ledger/core.sh"
assert_eq "security-plan: allowed set" "review-plan-codex plan-security-reviewer" \
    "$(producer_set cl_allowed_producers security-plan)"
assert_eq "security-plan: exactly two lines" "2" "$(producer_lines security-plan)"
case_end

case_begin "outline-plan-admits-codex-and-outline-reviewer" "bin/lib/concern-ledger/core.sh"
assert_eq "outline-plan: allowed set" "review-plan-codex outline-reviewer" "$(producer_set cl_allowed_producers outline-plan)"
assert_eq "outline-plan: exactly two lines" "2" "$(producer_lines outline-plan)"
case_end

case_begin "detail-plan-admits-codex-and-detail-reviewer" "bin/lib/concern-ledger/core.sh"
assert_eq "detail-plan: allowed set" "review-plan-codex detail-reviewer" "$(producer_set cl_allowed_producers detail-plan)"
assert_eq "detail-plan: exactly two lines" "2" "$(producer_lines detail-plan)"
case_end

case_begin "shared-format-and-declared-sets-unchanged" "bin/lib/concern-ledger/core.sh"
assert_eq "review-security-shared keeps its pair" "review-code-codex security-scanner" \
    "$(producer_set cl_allowed_producers review-security-shared)"
for f in test-review security-plan outline-plan detail-plan review-security-shared; do
    assert_eq "$f declares no mandatory producer" "" "$(producer_set cl_declared_producers "$f")"
done
case_end

echo ""
echo "=== T5: the loop refuses a producer outside the format's set ==="
case_begin "loop-refuses-a-third-producer" "bin/run-codex-review-loop"
seed_sid t5
printf '<!-- begin-codex-output -->\nNEEDS_REVISION\nC1. [HIGH] x\n<!-- end-codex-output -->\n' > "$FX_TMP/t5.md"
for pair in "detail-plan security-scanner" "outline-plan detail-reviewer" "test-review review-code-codex" \
    "security-plan test-reviewer"; do
    set -- $pair
    loop t5 "$1" --prestaged-report "$FX_TMP/t5.md" --prestaged-producer "$2" --prestaged-exec PERFORMED
    assert_eq "$1 with producer $2: exit 4" "4" "$L_RC"
    assert_contains "$1 with producer $2: refused by the producer gate" \
        "--prestaged-producer not permitted for format $1: $2" "$L_ERR"
    assert_eq "$1 with producer $2: no row" "0" "$(rows t5 "$1")"
done
case_end

finish

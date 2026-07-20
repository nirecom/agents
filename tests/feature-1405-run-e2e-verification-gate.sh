#!/usr/bin/env bash
# Tests: skills/_shared/user-verified.md, .env.example, docs/ops.md, rules/test.md
# Tags: run-e2e, verification-gate, user-verified, scope:issue-specific
# Tests for issue #1405 — gate the #833 verification-gate ask behind RUN_TL3.
#
# Test-first (TDD): the RUN_TL3 guard in user-verified.md and the doc edits have
# NOT been written yet — content assertions (cases 1,3,4,5,6,7,8,9,11,12) are
# EXPECTED TO FAIL initially (RED state). Cases 2,10,13,14 already hold and PASS.
#
# L3 gap (what this test does NOT catch):
# - The real `claude -p` commit/merge-flow path where RUN_TL3=off actually
#   suppresses the AskUserQuestion is never exercised — this is a structural
#   (grep/line-number) test only. A live session would confirm the classifier
#   preflight is skipped and no ask is raised.
# - Closest-to-action mitigation: case 3 asserts the RUN_TL3 reader reference
#   precedes the check-verification-gate.sh invocation (guard-before-classifier
#   ordering), the ordering property the runtime path relies on.

set -u

# Resolve repo root from this test's own location so it works in any worktree.
_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(git -C "$_TEST_DIR" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$AGENTS_DIR" ] || AGENTS_DIR="$(cd "$_TEST_DIR/.." && pwd)"

USER_VERIFIED="$AGENTS_DIR/skills/_shared/user-verified.md"
ENV_EXAMPLE="$AGENTS_DIR/.env.example"
OPS_MD="$AGENTS_DIR/docs/ops.md"
TEST_MD="$AGENTS_DIR/rules/test.md"
CLASSIFIER="$AGENTS_DIR/bin/check-verification-gate.sh"
REVIEW_ENV_EXAMPLE="$AGENTS_DIR/bin/review-env-example"
RUN_WITH_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================================
# Case 1 — user-verified.md contains reader `confirm-off RUN_TL3 off`
# ============================================================================
echo "=== Case 1: user-verified.md confirm-off RUN_TL3 off ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "1. user-verified.md not found at $USER_VERIFIED"
elif grep -qE 'confirm-off[[:space:]]+RUN_TL3[[:space:]]+off' "$USER_VERIFIED"; then
    pass "1. reader 'confirm-off RUN_TL3 off' present"
else
    fail "1. reader 'confirm-off RUN_TL3 off' missing"
fi

# ============================================================================
# Case 2 — user-verified.md does NOT contain raw `get-config-var --is-off`
#          (T17 invariant double-lock)
# ============================================================================
echo "=== Case 2: user-verified.md raw get-config-var --is-off absent ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "2. user-verified.md not found"
elif grep -qE 'get-config-var[[:space:]]+--is-off' "$USER_VERIFIED"; then
    fail "2. raw 'get-config-var --is-off' idiom present (T17 violation)"
else
    pass "2. raw 'get-config-var --is-off' idiom absent"
fi

# ============================================================================
# Case 3 — RUN_TL3 reader reference precedes check-verification-gate.sh call
#          (guard-before-classifier ordering)
# ============================================================================
echo "=== Case 3: RUN_TL3 reader precedes classifier invocation ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "3. user-verified.md not found"
else
    reader_ln="$(grep -nE 'confirm-off[[:space:]]+RUN_TL3[[:space:]]+off' "$USER_VERIFIED" | head -1 | cut -d: -f1)"
    classifier_ln="$(grep -nE 'check-verification-gate\.sh' "$USER_VERIFIED" | head -1 | cut -d: -f1)"
    if [ -z "$reader_ln" ]; then
        fail "3. RUN_TL3 reader reference not found (cannot compare ordering)"
    elif [ -z "$classifier_ln" ]; then
        fail "3. check-verification-gate.sh invocation not found (cannot compare ordering)"
    elif [ "$reader_ln" -lt "$classifier_ln" ]; then
        pass "3. RUN_TL3 reader (L$reader_ln) precedes classifier call (L$classifier_ln)"
    else
        fail "3. RUN_TL3 reader (L$reader_ln) does NOT precede classifier call (L$classifier_ln)"
    fi
fi

# ============================================================================
# Case 4 — user-verified.md documents OFF → suppress-ask directive
#          (both "do not" case-insensitive and "AskUserQuestion" in RUN_TL3 subsection)
# ============================================================================
echo "=== Case 4: OFF → suppress-ask directive ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "4. user-verified.md not found"
else
    # Isolate the RUN_TL3 subsection: from the first RUN_TL3 mention to the next
    # top-level (## ) heading (or EOF).
    subsection="$(awk '
        /RUN_TL3/ { grab=1 }
        grab && /^## / && seen { exit }
        grab { print; seen=1 }
    ' "$USER_VERIFIED")"
    if printf '%s\n' "$subsection" | grep -qi 'do not' \
        && printf '%s\n' "$subsection" | grep -q 'AskUserQuestion'; then
        pass "4. RUN_TL3 subsection contains both 'do not' and 'AskUserQuestion'"
    else
        fail "4. RUN_TL3 subsection missing 'do not' and/or 'AskUserQuestion'"
    fi
fi

# ============================================================================
# Case 5 — distinct log annotation string `skipped: RUN_TL3=off` (CPR-5)
# ============================================================================
echo "=== Case 5: log annotation 'skipped: RUN_TL3=off' ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "5. user-verified.md not found"
elif grep -qF 'skipped: RUN_TL3=off' "$USER_VERIFIED"; then
    pass "5. distinct annotation 'skipped: RUN_TL3=off' present"
else
    fail "5. distinct annotation 'skipped: RUN_TL3=off' missing"
fi

# ============================================================================
# Case 6 — fail-safe documented with the word "unchanged"
#          (ON / ERROR run the preflight unchanged)
# ============================================================================
echo "=== Case 6: fail-safe 'unchanged' wording ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "6. user-verified.md not found"
else
    subsection="$(awk '
        /RUN_TL3/ { grab=1 }
        grab && /^## / && seen { exit }
        grab { print; seen=1 }
    ' "$USER_VERIFIED")"
    if printf '%s\n' "$subsection" | grep -qi 'unchanged'; then
        pass "6. fail-safe documents 'unchanged'"
    else
        fail "6. fail-safe 'unchanged' wording missing"
    fi
fi

# ============================================================================
# Case 7 — off-path classifier-error totality: "classifier" together with
#          "skip"/"skipping" in the off-path context (no ask on classifier error)
# ============================================================================
echo "=== Case 7: off-path classifier-error totality ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "7. user-verified.md not found"
else
    subsection="$(awk '
        /RUN_TL3/ { grab=1 }
        grab && /^## / && seen { exit }
        grab { print; seen=1 }
    ' "$USER_VERIFIED")"
    if printf '%s\n' "$subsection" | grep -qi 'classifier' \
        && printf '%s\n' "$subsection" | grep -qiE 'skip(ping)?'; then
        pass "7. off-path documents classifier + skip (no ask on classifier error)"
    else
        fail "7. off-path missing classifier + skip wording"
    fi
fi

# ============================================================================
# Case 8 — .env.example RUN_TL3 block mentions "verification-gate"
# ============================================================================
echo "=== Case 8: .env.example RUN_TL3 block mentions verification-gate ==="
if [ ! -f "$ENV_EXAMPLE" ]; then
    fail "8. .env.example not found"
else
    # RUN_TL3 block: from the RUN_TL3 comment header/value up to the next blank-line
    # separated category. Extract the contiguous comment+value region around RUN_TL3=.
    block="$(awk '
        /^RUN_TL3=/ { print; inblock=0; next }
        /^#/ { buf = buf $0 "\n"; next }
        /^[[:space:]]*$/ { if (matched) exit; buf=""; next }
        { if (!matched) buf="" }
        END { }
        /^RUN_TL3=/ { }
    ' "$ENV_EXAMPLE")"
    # Simpler robust approach: grab 8 lines of context around RUN_TL3= and search.
    region="$(grep -nE '^RUN_TL3=' "$ENV_EXAMPLE" | head -1 | cut -d: -f1)"
    if [ -z "$region" ]; then
        fail "8. RUN_TL3= entry not found in .env.example"
    else
        start=$((region > 8 ? region - 8 : 1))
        end=$((region + 1))
        if sed -n "${start},${end}p" "$ENV_EXAMPLE" | grep -qi 'verification-gate'; then
            pass "8. RUN_TL3 block mentions 'verification-gate'"
        else
            fail "8. RUN_TL3 block does not mention 'verification-gate'"
        fi
    fi
fi

# ============================================================================
# Case 9 — .env.example RUN_TL3 block contains "commit"
#          (i.e. "before commit or merge" wording — not pre-merge only)
# ============================================================================
echo "=== Case 9: .env.example RUN_TL3 block mentions 'commit' ==="
if [ ! -f "$ENV_EXAMPLE" ]; then
    fail "9. .env.example not found"
else
    region="$(grep -nE '^RUN_TL3=' "$ENV_EXAMPLE" | head -1 | cut -d: -f1)"
    if [ -z "$region" ]; then
        fail "9. RUN_TL3= entry not found in .env.example"
    else
        start=$((region > 8 ? region - 8 : 1))
        end=$((region + 1))
        if sed -n "${start},${end}p" "$ENV_EXAMPLE" | grep -qi 'commit'; then
            pass "9. RUN_TL3 block mentions 'commit'"
        else
            fail "9. RUN_TL3 block does not mention 'commit'"
        fi
    fi
fi

# ============================================================================
# Case 10 — .env.example still passes bin/review-env-example (no new HARD)
# ============================================================================
echo "=== Case 10: .env.example passes review-env-example ==="
if [ ! -x "$REVIEW_ENV_EXAMPLE" ]; then
    fail "10. review-env-example not executable at $REVIEW_ENV_EXAMPLE"
else
    set +e
    bash "$RUN_WITH_TIMEOUT" 60 bash "$REVIEW_ENV_EXAMPLE" >/tmp/1405-rev.out 2>&1
    rc=$?
    set -e
    # Exit code is the SSOT for HARD violations: review-env-example exits 0 when
    # there are 0 HARD findings and exits non-zero when a HARD finding blocks.
    # Do NOT grep stdout for the word "HARD" — the tool unconditionally prints an
    # informational header line containing "HARD" even on a clean, exit-0 run.
    if [ "$rc" -eq 0 ]; then
        pass "10. review-env-example exit 0 (no HARD violations)"
    else
        fail "10. review-env-example exit $rc (expected 0)"
        sed 's/^/  | /' /tmp/1405-rev.out
    fi
    rm -f /tmp/1405-rev.out
fi

# ============================================================================
# Case 11 — rules/test.md contains `RUN_TL3=on` qualifier AND
#           "before commit or merge" wording in closest-to-action verification
# ============================================================================
echo "=== Case 11: rules/test.md RUN_TL3=on + before commit or merge ==="
if [ ! -f "$TEST_MD" ]; then
    fail "11. rules/test.md not found"
else
    if grep -qE 'RUN_TL3=on' "$TEST_MD" \
        && grep -qiE 'before commit or merge' "$TEST_MD"; then
        pass "11. rules/test.md has 'RUN_TL3=on' and 'before commit or merge'"
    else
        fail "11. rules/test.md missing 'RUN_TL3=on' and/or 'before commit or merge'"
    fi
fi

# ============================================================================
# Case 12 — docs/ops.md RUN_TL3 paragraph mentions verification-gate suppression
#           AND references both commit and merge firing points
# ============================================================================
echo "=== Case 12: docs/ops.md RUN_TL3 verification-gate + commit/merge ==="
if [ ! -f "$OPS_MD" ]; then
    fail "12. docs/ops.md not found"
else
    if grep -qiE 'verification-gate' "$OPS_MD" \
        && grep -qiE 'commit' "$OPS_MD" \
        && grep -qiE 'merge' "$OPS_MD"; then
        pass "12. docs/ops.md mentions verification-gate + commit + merge"
    else
        fail "12. docs/ops.md missing verification-gate suppression and/or commit/merge firing points"
    fi
fi

# ============================================================================
# Case 13 — Non-regression: check-verification-gate.sh source does NOT reference
#           RUN_TL3, get-config-var, or confirm-off (classifier purity)
# ============================================================================
echo "=== Case 13: classifier purity ==="
if [ ! -f "$CLASSIFIER" ]; then
    fail "13. check-verification-gate.sh not found"
elif grep -qE 'RUN_TL3|get-config-var|confirm-off' "$CLASSIFIER"; then
    fail "13. classifier references RUN_TL3/get-config-var/confirm-off (impurity)"
    grep -nE 'RUN_TL3|get-config-var|confirm-off' "$CLASSIFIER" | sed 's/^/  | /'
else
    pass "13. classifier is pure (no RUN_TL3/get-config-var/confirm-off)"
fi

# ============================================================================
# Case 14 — T17 regression: grep -rln 'get-config-var --is-off' skills/ → ZERO
# ============================================================================
echo "=== Case 14: T17 zero-match in skills/ ==="
matches="$(grep -rlnE 'get-config-var[[:space:]]+--is-off' "$AGENTS_DIR/skills/" 2>/dev/null || true)"
if [ -z "$matches" ]; then
    pass "14. zero 'get-config-var --is-off' matches under skills/"
else
    fail "14. found 'get-config-var --is-off' under skills/ (T17 violation)"
    printf '%s\n' "$matches" | sed 's/^/  | /'
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

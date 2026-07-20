#!/usr/bin/env bash
# Tests: skills/_shared/user-verified.md, .env.example, docs/ops.md, rules/test.md, bin/check-verification-gate.sh, bin/select-tests.sh
# Tags: run-tl3, run-tl4, verification-gate, user-verified, scope:common
# Permanent test guarding the orthogonality of two toggles:
#   RUN_TL3 — test execution / selection gate (bin/select-tests.sh)
#   RUN_TL4 — verification-gate AskUserQuestion gate (skills/_shared/user-verified.md)
# Neither toggle may leak into the other's surface. The classifier
# (bin/check-verification-gate.sh) stays env-var free.
# Provenance: gate introduced in #1405 (then RUN_E2E/RUN_TL3), split onto RUN_TL4 in #1586.
#
# TL3 gap (what this test does NOT catch):
# - The real `claude -p` commit/merge-flow path where RUN_TL4=off actually
#   suppresses the AskUserQuestion is never exercised — this is a structural
#   (grep/section-extraction) test only. A live session would confirm the ask is
#   not raised while the classifier still runs for its log-only trace.
# - Nor does it catch RUN_TL3=on wrongly re-activating the ask at runtime; only
#   the absence of the RUN_TL3 literal from the ask wiring is asserted (case 2).
# Closest-to-action mitigation: case 4 asserts the RUN_TL4 reader reference
# precedes the check-verification-gate.sh invocation (guard-before-classifier
# ordering), the ordering property the runtime path relies on.

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
SELECT_TESTS="$AGENTS_DIR/bin/select-tests.sh"
REVIEW_ENV_EXAMPLE="$AGENTS_DIR/bin/review-env-example"
RUN_WITH_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Helper: RUN_TL4 subsection of user-verified.md — first RUN_TL4 mention up to
# the next top-level (## ) heading, or EOF.
tl4_subsection() {
    awk '
        /RUN_TL4/ { grab=1 }
        grab && /^## / && seen { exit }
        grab { print; seen=1 }
    ' "$USER_VERIFIED"
}

# Helper: tl4_bullet <awk-regex> — the one `- ` bullet of the RUN_TL4 subsection
# whose first line matches <awk-regex>, plus continuation lines, stopping at the
# next bullet / blank line / heading.
# Branch-scoped extraction is required: word co-occurrence across the whole
# subsection passes even when a directive is bound to the WRONG branch (e.g.
# "do not raise any AskUserQuestion" landing on the ON bullet).
tl4_bullet() {
    tl4_subsection | awk -v re="$1" '
        /^- / { if (grab) exit; if ($0 ~ re) { grab=1; print; next } }
        /^[[:space:]]*$/ { if (grab) exit; next }
        /^#/ { if (grab) exit; next }
        grab { print }
    '
}

# Helper: env_block_for <VAR> — the comment block belonging to <VAR>, mirroring
# bin/review-env-example's parser: walk back from `VAR=`, stop at a blank line or
# a category heading (`^#\s*---.*---\s*$`). A fixed-size lookback window would
# bleed into the neighbouring block and break the negative assertion in case 12.
env_block_for() {
    awk -v var="$1" '
        $0 ~ "^" var "=" { for (i = 1; i <= n; i++) print buf[i]; exit }
        /^[[:space:]]*$/ { n=0; next }
        /^#[[:space:]]*---.*---[[:space:]]*$/ { n=0; next }
        /^#/ { buf[++n] = $0; next }
        { n=0 }
    ' "$ENV_EXAMPLE"
}

# Helper: md_section <file> <heading-substring> — the `##`/`###` section whose
# heading contains <heading-substring>, up to the next heading.
# Section-scoped extraction is mandatory: whole-file greps false-negative pass,
# because RUN_TL3 legitimately survives elsewhere in these same files.
md_section() {
    awk -v needle="$2" '
        /^#{2,3} / {
            if (grab) exit
            if (index($0, needle) > 0) { grab=1; print; next }
        }
        grab { print }
    ' "$1"
}

# Helper: md_paragraph <file> <substring> — the single blank-line-delimited
# paragraph containing <substring>.
md_paragraph() {
    awk -v needle="$2" '
        /^[[:space:]]*$/ {
            if (hit) { for (i = 1; i <= n; i++) print buf[i]; hit=0; exit }
            n=0; next
        }
        { buf[++n] = $0; if (index($0, needle) > 0) hit=1 }
        END { if (hit) for (i = 1; i <= n; i++) print buf[i] }
    ' "$1"
}

# ============================================================================
# Group A — ask gate wiring (skills/_shared/user-verified.md)
# ============================================================================

# ============================================================================
# Case 1 — user-verified.md contains reader `confirm-off RUN_TL4 off`
# ============================================================================
echo "=== Case 1: user-verified.md confirm-off RUN_TL4 off ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "1. user-verified.md not found at $USER_VERIFIED"
elif grep -qE 'confirm-off[[:space:]]+RUN_TL4[[:space:]]+off' "$USER_VERIFIED"; then
    pass "1. reader 'confirm-off RUN_TL4 off' present"
else
    fail "1. reader 'confirm-off RUN_TL4 off' missing"
fi

# ============================================================================
# Case 2 — user-verified.md contains NO RUN_TL3 token at all (orthogonality).
#          Also guards cases 5-8: a stray RUN_TL3 means the split is partial.
# ============================================================================
echo "=== Case 2: user-verified.md free of RUN_TL3 ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "2. user-verified.md not found"
elif grep -qF 'RUN_TL3' "$USER_VERIFIED"; then
    fail "2. RUN_TL3 token present in ask wiring (toggles not orthogonal)"
    grep -nF 'RUN_TL3' "$USER_VERIFIED" | sed 's/^/  | /'
else
    pass "2. no RUN_TL3 token in user-verified.md"
fi

# ============================================================================
# Case 3 — user-verified.md does NOT contain raw `get-config-var --is-off`
#          (T17 invariant double-lock)
# ============================================================================
echo "=== Case 3: user-verified.md raw get-config-var --is-off absent ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "3. user-verified.md not found"
elif grep -qE 'get-config-var[[:space:]]+--is-off' "$USER_VERIFIED"; then
    fail "3. raw 'get-config-var --is-off' idiom present (T17 violation)"
else
    pass "3. raw 'get-config-var --is-off' idiom absent"
fi

# ============================================================================
# Case 4 — RUN_TL4 reader reference precedes check-verification-gate.sh call
#          (guard-before-classifier ordering)
# ============================================================================
echo "=== Case 4: RUN_TL4 reader precedes classifier invocation ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "4. user-verified.md not found"
else
    reader_ln="$(grep -nE 'confirm-off[[:space:]]+RUN_TL4[[:space:]]+off' "$USER_VERIFIED" | head -1 | cut -d: -f1)"
    classifier_ln="$(grep -nE 'check-verification-gate\.sh' "$USER_VERIFIED" | head -1 | cut -d: -f1)"
    if [ -z "$reader_ln" ]; then
        fail "4. RUN_TL4 reader reference not found (cannot compare ordering)"
    elif [ -z "$classifier_ln" ]; then
        fail "4. check-verification-gate.sh invocation not found (cannot compare ordering)"
    elif [ "$reader_ln" -lt "$classifier_ln" ]; then
        pass "4. RUN_TL4 reader (L$reader_ln) precedes classifier call (L$classifier_ln)"
    else
        fail "4. RUN_TL4 reader (L$reader_ln) does NOT precede classifier call (L$classifier_ln)"
    fi
fi

# ============================================================================
# Case 5 — the OFF branch itself carries the suppress-ask directive ("do not" +
#          "AskUserQuestion"), so the directive cannot satisfy this case while
#          actually being bound to the ON or ERROR branch.
# ============================================================================
echo "=== Case 5: OFF branch carries the suppress-ask directive ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "5. user-verified.md not found"
else
    off_bullet="$(tl4_bullet '`OFF`')"
    if [ -z "$off_bullet" ]; then
        fail "5. RUN_TL4 OFF branch bullet not found"
    elif printf '%s\n' "$off_bullet" | grep -qi 'do not' \
        && printf '%s\n' "$off_bullet" | grep -q 'AskUserQuestion'; then
        pass "5. OFF branch contains both 'do not' and 'AskUserQuestion'"
    else
        fail "5. OFF branch missing 'do not' and/or 'AskUserQuestion'"
        printf '%s\n' "$off_bullet" | sed 's/^/  | /'
    fi
fi

# ============================================================================
# Case 6 — distinct log annotation string `skipped: RUN_TL4=off` (CPR-5)
# ============================================================================
echo "=== Case 6: log annotation 'skipped: RUN_TL4=off' ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "6. user-verified.md not found"
elif grep -qF 'skipped: RUN_TL4=off' "$USER_VERIFIED"; then
    pass "6. distinct annotation 'skipped: RUN_TL4=off' present"
else
    fail "6. distinct annotation 'skipped: RUN_TL4=off' missing"
fi

# ============================================================================
# Case 7 — "run the preflight unchanged" is bound to BOTH non-suppressing
#          branches (ON and ERROR); ERROR must additionally say fail-safe, since
#          an ambiguous config read must never silence the gate. A subsection-wide
#          check would pass with the word present on only one of the two.
# ============================================================================
echo "=== Case 7: ON and ERROR branches both run the preflight unchanged ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "7. user-verified.md not found"
else
    on_bullet="$(tl4_bullet '`ON`')"
    err_bullet="$(tl4_bullet '`ERROR`')"
    if [ -z "$on_bullet" ]; then
        fail "7. RUN_TL4 ON branch bullet not found"
    elif [ -z "$err_bullet" ]; then
        fail "7. RUN_TL4 ERROR branch bullet not found"
    elif ! printf '%s\n' "$on_bullet" | grep -qi 'unchanged'; then
        fail "7. ON branch does not run the preflight 'unchanged'"
        printf '%s\n' "$on_bullet" | sed 's/^/  | /'
    elif ! printf '%s\n' "$err_bullet" | grep -qi 'unchanged'; then
        fail "7. ERROR branch does not run the preflight 'unchanged'"
        printf '%s\n' "$err_bullet" | sed 's/^/  | /'
    elif ! printf '%s\n' "$err_bullet" | grep -qi 'fail-safe'; then
        fail "7. ERROR branch missing 'fail-safe' wording"
        printf '%s\n' "$err_bullet" | sed 's/^/  | /'
    else
        pass "7. ON and ERROR both 'unchanged'; ERROR documents fail-safe"
    fi
fi

# ============================================================================
# Case 8 — off-path classifier-error totality: "classifier" together with
#          "skip"/"skipping" in the off-path context (no ask on classifier error)
# ============================================================================
echo "=== Case 8: off-path classifier-error totality ==="
if [ ! -f "$USER_VERIFIED" ]; then
    fail "8. user-verified.md not found"
else
    offpath_bullet="$(tl4_bullet 'off path')"
    if [ -z "$offpath_bullet" ]; then
        fail "8. off-path classifier-error bullet not found"
    elif ! printf '%s\n' "$offpath_bullet" | grep -qi 'classifier'; then
        fail "8. off-path bullet does not mention the classifier"
        printf '%s\n' "$offpath_bullet" | sed 's/^/  | /'
    elif ! printf '%s\n' "$offpath_bullet" | grep -qiE 'skip(ping)?'; then
        fail "8. off-path bullet does not document skipping the category trace"
        printf '%s\n' "$offpath_bullet" | sed 's/^/  | /'
    elif ! printf '%s\n' "$offpath_bullet" | grep -q 'AskUserQuestion'; then
        fail "8. off-path bullet does not state that no AskUserQuestion is raised"
        printf '%s\n' "$offpath_bullet" | sed 's/^/  | /'
    else
        pass "8. off-path bullet: classifier error still raises no ask, trace skipped"
    fi
fi

# ============================================================================
# Group B — .env.example split
# ============================================================================

# ============================================================================
# Case 9 — .env.example defines RUN_TL4=off
# ============================================================================
echo "=== Case 9: .env.example RUN_TL4=off entry ==="
if [ ! -f "$ENV_EXAMPLE" ]; then
    fail "9. .env.example not found"
elif grep -qE '^RUN_TL4=off[[:space:]]*$' "$ENV_EXAMPLE"; then
    pass "9. 'RUN_TL4=off' entry present"
else
    fail "9. 'RUN_TL4=off' entry missing"
fi

# ============================================================================
# Case 10 — .env.example still defines RUN_TL3=off (deletion-accident detector)
# ============================================================================
echo "=== Case 10: .env.example RUN_TL3=off entry retained ==="
if [ ! -f "$ENV_EXAMPLE" ]; then
    fail "10. .env.example not found"
elif grep -qE '^RUN_TL3=off[[:space:]]*$' "$ENV_EXAMPLE"; then
    pass "10. 'RUN_TL3=off' entry retained"
else
    fail "10. 'RUN_TL3=off' entry missing (accidental deletion?)"
fi

# ============================================================================
# Case 11 — RUN_TL4 comment block mentions both 'verification-gate' and 'commit'
# ============================================================================
echo "=== Case 11: RUN_TL4 block mentions verification-gate + commit ==="
if [ ! -f "$ENV_EXAMPLE" ]; then
    fail "11. .env.example not found"
else
    block="$(env_block_for RUN_TL4)"
    if [ -z "$block" ]; then
        fail "11. RUN_TL4 comment block not found in .env.example"
    elif printf '%s\n' "$block" | grep -qi 'verification-gate' \
        && printf '%s\n' "$block" | grep -qi 'commit'; then
        pass "11. RUN_TL4 block mentions 'verification-gate' and 'commit'"
    else
        fail "11. RUN_TL4 block missing 'verification-gate' and/or 'commit'"
        printf '%s\n' "$block" | sed 's/^/  | /'
    fi
fi

# ============================================================================
# Case 12 — RUN_TL3 comment block mentions NEITHER 'verification-gate' NOR 'ask'
#           (proves the split completed — ask wording moved out of RUN_TL3)
# ============================================================================
echo "=== Case 12: RUN_TL3 block free of verification-gate / ask ==="
if [ ! -f "$ENV_EXAMPLE" ]; then
    fail "12. .env.example not found"
else
    block="$(env_block_for RUN_TL3)"
    if [ -z "$block" ]; then
        fail "12. RUN_TL3 comment block not found in .env.example"
    elif printf '%s\n' "$block" | grep -qi 'verification-gate'; then
        fail "12. RUN_TL3 block still mentions 'verification-gate'"
        printf '%s\n' "$block" | sed 's/^/  | /'
    elif printf '%s\n' "$block" | grep -qiE '\bask(s|ed|ing)?\b'; then
        fail "12. RUN_TL3 block still mentions 'ask'"
        printf '%s\n' "$block" | sed 's/^/  | /'
    else
        pass "12. RUN_TL3 block mentions neither 'verification-gate' nor 'ask'"
    fi
fi

# ============================================================================
# Case 13 — bin/review-env-example --all reports PERFORMED and emits zero
#           `^HARD: ./.env.example:` lines.
#
#           Exit code alone is NOT evidence of cleanliness: --all always exits 0
#           even with HARD findings, and no-arg diff mode exits 0 on four SKIPPED
#           paths (vacuously green forever once .env.example leaves the diff).
#           Stdout is the primary judgment; the `^HARD:` anchor is mandatory
#           because a clean run still prints an advisory line containing "HARD".
#           `--all` is exclusive with `--base`; do not combine them.
#           Exit 0 is asserted as an extra guard — not sufficient, but necessary:
#           a wrapper failure or 60s timeout could otherwise leave a truncated
#           but marker-bearing stdout that passes both stdout checks.
# ============================================================================
echo "=== Case 13: review-env-example --all PERFORMED + zero HARD ==="
if [ ! -f "$REVIEW_ENV_EXAMPLE" ]; then
    fail "13. review-env-example not found at $REVIEW_ENV_EXAMPLE"
else
    # cd to repo root: collect_all_targets uses `find .` and is CWD-dependent.
    rev_out="$(cd "$AGENTS_DIR" && bash "$RUN_WITH_TIMEOUT" 60 bash "$REVIEW_ENV_EXAMPLE" --all 2>&1)"
    rev_rc=$?
    hard_lines="$(printf '%s\n' "$rev_out" | grep -cE '^HARD: \./\.env\.example:')"
    if ! printf '%s\n' "$rev_out" | grep -qF '## Env-example Review: PERFORMED (all-scan mode)'; then
        fail "13. review-env-example did not report PERFORMED (all-scan mode)"
        printf '%s\n' "$rev_out" | head -20 | sed 's/^/  | /'
    elif [ "$hard_lines" -ne 0 ]; then
        fail "13. review-env-example reported $hard_lines HARD finding(s) for ./.env.example"
        printf '%s\n' "$rev_out" | grep -E '^HARD: \./\.env\.example:' | sed 's/^/  | /'
    elif [ "$rev_rc" -ne 0 ]; then
        fail "13. review-env-example exited $rev_rc (run did not complete cleanly)"
        printf '%s\n' "$rev_out" | tail -20 | sed 's/^/  | /'
    else
        pass "13. review-env-example PERFORMED, zero HARD findings, exit 0"
    fi
fi

# ============================================================================
# Group C — doc SSOT (section-scoped; whole-file grep would false-negative pass)
# ============================================================================

# ============================================================================
# Case 14 — rules/test.md "Closest-to-action verification" section references
#           RUN_TL4=on and no longer references RUN_TL3
# ============================================================================
echo "=== Case 14: rules/test.md closest-to-action section on RUN_TL4 ==="
if [ ! -f "$TEST_MD" ]; then
    fail "14. rules/test.md not found"
else
    section="$(md_section "$TEST_MD" 'Closest-to-action verification')"
    if [ -z "$section" ]; then
        fail "14. 'Closest-to-action verification' section not found"
    elif ! printf '%s\n' "$section" | grep -qF 'RUN_TL4=on'; then
        fail "14. section does not reference 'RUN_TL4=on'"
        printf '%s\n' "$section" | sed 's/^/  | /'
    elif printf '%s\n' "$section" | grep -qF 'RUN_TL3'; then
        fail "14. section still references RUN_TL3 (ask must be gated on RUN_TL4 only)"
        printf '%s\n' "$section" | grep -nF 'RUN_TL3' | sed 's/^/  | /'
    else
        pass "14. closest-to-action section gates the ask on RUN_TL4 only"
    fi
fi

# ============================================================================
# Case 15 — rules/test.md "Test file naming by layer" section still carries the
#           RUN_TL3-gated wording (protects the deliberately-unchanged line)
# ============================================================================
echo "=== Case 15: rules/test.md naming section retains RUN_TL3-gated ==="
if [ ! -f "$TEST_MD" ]; then
    fail "15. rules/test.md not found"
else
    section="$(md_section "$TEST_MD" 'Test file naming by layer')"
    if [ -z "$section" ]; then
        fail "15. 'Test file naming by layer' section not found"
    elif printf '%s\n' "$section" | grep -qF 'RUN_TL3'; then
        pass "15. naming section retains RUN_TL3-gated wording"
    else
        fail "15. naming section lost its RUN_TL3 reference (over-broad replacement?)"
    fi
fi

# ============================================================================
# Case 16 — docs/ops.md: the ask paragraph references RUN_TL4 (and not RUN_TL3),
#           while the test-execution paragraph still references RUN_TL3
# ============================================================================
echo "=== Case 16: docs/ops.md ask paragraph on RUN_TL4, exec paragraph on RUN_TL3 ==="
if [ ! -f "$OPS_MD" ]; then
    fail "16. docs/ops.md not found"
else
    ask_para="$(md_paragraph "$OPS_MD" 'verification-gate ask')"
    exec_para="$(md_paragraph "$OPS_MD" 'exit 77')"
    if [ -z "$ask_para" ]; then
        fail "16. verification-gate ask paragraph not found in docs/ops.md"
    elif ! printf '%s\n' "$ask_para" | grep -qF 'RUN_TL4'; then
        fail "16. ask paragraph does not reference RUN_TL4"
        printf '%s\n' "$ask_para" | sed 's/^/  | /'
    elif printf '%s\n' "$ask_para" | grep -qF 'RUN_TL3'; then
        fail "16. ask paragraph still references RUN_TL3"
        printf '%s\n' "$ask_para" | sed 's/^/  | /'
    elif [ -z "$exec_para" ]; then
        fail "16. test-execution paragraph not found in docs/ops.md"
    elif printf '%s\n' "$exec_para" | grep -qF 'RUN_TL3'; then
        pass "16. ask paragraph on RUN_TL4; test-execution paragraph retains RUN_TL3"
    else
        fail "16. test-execution paragraph lost its RUN_TL3 reference"
        printf '%s\n' "$exec_para" | sed 's/^/  | /'
    fi
fi

# ============================================================================
# Group D — non-regression
# ============================================================================

# ============================================================================
# Case 17 — check-verification-gate.sh references none of RUN_TL3 / RUN_TL4 /
#           get-config-var / confirm-off (classifier purity)
# ============================================================================
echo "=== Case 17: classifier purity ==="
if [ ! -f "$CLASSIFIER" ]; then
    fail "17. check-verification-gate.sh not found"
elif grep -qE 'RUN_TL3|RUN_TL4|get-config-var|confirm-off' "$CLASSIFIER"; then
    fail "17. classifier references a toggle or config reader (impurity)"
    grep -nE 'RUN_TL3|RUN_TL4|get-config-var|confirm-off' "$CLASSIFIER" | sed 's/^/  | /'
else
    pass "17. classifier is pure (no RUN_TL3/RUN_TL4/get-config-var/confirm-off)"
fi

# ============================================================================
# Case 18 — bin/select-tests.sh references RUN_TL3 and NOT RUN_TL4
#           (out-of-scope file protection: the selection gate stays on RUN_TL3)
# ============================================================================
echo "=== Case 18: select-tests.sh gate stays on RUN_TL3 ==="
if [ ! -f "$SELECT_TESTS" ]; then
    fail "18. select-tests.sh not found"
elif ! grep -qF 'RUN_TL3' "$SELECT_TESTS"; then
    fail "18. select-tests.sh no longer references RUN_TL3"
elif grep -qF 'RUN_TL4' "$SELECT_TESTS"; then
    fail "18. select-tests.sh references RUN_TL4 (ask toggle leaked into selection gate)"
    grep -nF 'RUN_TL4' "$SELECT_TESTS" | sed 's/^/  | /'
else
    pass "18. select-tests.sh references RUN_TL3 only"
fi

# ============================================================================
# Case 19 — T17 regression: zero `get-config-var --is-off` matches under skills/
# ============================================================================
echo "=== Case 19: T17 zero-match in skills/ ==="
matches="$(grep -rlnE 'get-config-var[[:space:]]+--is-off' "$AGENTS_DIR/skills/" 2>/dev/null || true)"
if [ -z "$matches" ]; then
    pass "19. zero 'get-config-var --is-off' matches under skills/"
else
    fail "19. found 'get-config-var --is-off' under skills/ (T17 violation)"
    printf '%s\n' "$matches" | sed 's/^/  | /'
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

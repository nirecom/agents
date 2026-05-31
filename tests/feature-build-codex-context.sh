#!/bin/bash
# Tests: bin/build-codex-context
# Tags: build-codex-context
# Tests for bin/build-codex-context
#
# Builds a unified Codex context file by concatenating intent.md and outline.md
# from a session plans directory. Handles absent/empty inputs, atomic writes,
# trailing-newline injection, and stale-output cleanup.
#
# RED: this suite fails clean while bin/build-codex-context is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$AGENTS_DIR/bin/build-codex-context"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
if [ ! -x "$SUT" ]; then
    echo "FAIL: bin/build-codex-context not found — write-tests RED (expected before implementation)"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Track all temp dirs created so we can sweep for leftover tempfiles in C9.
declare -a ALL_TMPS=()

mk_tmp() {
    local d
    d="$(mktemp -d)"
    ALL_TMPS+=("$d")
    mkdir -p "$d/drafts"
    echo "$d"
}

cleanup() {
    for d in "${ALL_TMPS[@]}"; do
        [ -d "$d" ] && rm -rf "$d"
    done
}
trap cleanup EXIT

SID="test"
INTENT_CONTENT=$'# Intent\nThis is intent.'
OUTLINE_CONTENT=$'# Outline\nThis is outline.'

run_sut() {
    local plans_dir="$1" sid="$2" output="$3"
    run_with_timeout 15 "$SUT" \
        --plans-dir "$plans_dir" \
        --session-id "$sid" \
        --output "$output"
}

# ============================================================================
# C1 — intent.md only (non-empty)
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
printf '%s\n' "$INTENT_CONTENT" > "$TMP/${SID}-intent.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && [ -f "$OUT" ] \
   && grep -qF "## Section 1: Intent (User Requirements)" "$OUT" \
   && grep -qF "This is intent." "$OUT" \
   && ! grep -qF "## Section 2:" "$OUT" \
   && ! grep -qE "^---$" "$OUT"; then
    pass "C1: intent.md only → Section 1, no Section 2, no separator"
else
    fail "C1: rc=$RC out_exists=$([ -f "$OUT" ] && echo yes || echo no)"
fi

# ============================================================================
# C2 — outline.md only (non-empty)
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
printf '%s\n' "$OUTLINE_CONTENT" > "$TMP/${SID}-outline.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && [ -f "$OUT" ] \
   && grep -qF "## Section 2: Outline (Design Proposal)" "$OUT" \
   && grep -qF "This is outline." "$OUT" \
   && ! grep -qF "## Section 1:" "$OUT" \
   && ! grep -qE "^---$" "$OUT"; then
    pass "C2: outline.md only → Section 2, no Section 1, no separator"
else
    fail "C2: rc=$RC out_exists=$([ -f "$OUT" ] && echo yes || echo no)"
fi

# ============================================================================
# C3 — both present
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
printf '%s\n' "$INTENT_CONTENT" > "$TMP/${SID}-intent.md"
printf '%s\n' "$OUTLINE_CONTENT" > "$TMP/${SID}-outline.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
SEP_COUNT=$(grep -cE "^---$" "$OUT" 2>/dev/null || echo 0)
S1_LINE=$(grep -nF "## Section 1: Intent" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
SEP_LINE=$(grep -nE "^---$" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
S2_LINE=$(grep -nF "## Section 2: Outline" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
if [ "$RC" -eq 0 ] \
   && [ -f "$OUT" ] \
   && [ "$SEP_COUNT" -eq 1 ] \
   && grep -qF "This is intent." "$OUT" \
   && grep -qF "This is outline." "$OUT" \
   && [ -n "$S1_LINE" ] && [ -n "$SEP_LINE" ] && [ -n "$S2_LINE" ] \
   && [ "$S1_LINE" -lt "$SEP_LINE" ] && [ "$SEP_LINE" -lt "$S2_LINE" ]; then
    pass "C3: both present → Section 1, ---, Section 2 (correct order)"
else
    fail "C3: rc=$RC sep_count=$SEP_COUNT s1=$S1_LINE sep=$SEP_LINE s2=$S2_LINE"
fi

# ============================================================================
# C4 — neither present, no pre-existing output
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$OUT" ]; then
    pass "C4: no inputs → output not created, exit 0"
else
    fail "C4: rc=$RC out_exists=$([ -e "$OUT" ] && echo yes || echo no)"
fi

# ============================================================================
# C4b — stale-output deletion regression
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
printf '%s\n' "$INTENT_CONTENT" > "$TMP/${SID}-intent.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC1=$?
ROUND1_OK=$([ "$RC1" -eq 0 ] && [ -f "$OUT" ] && grep -qF "## Section 1:" "$OUT" && echo yes || echo no)
rm -f "$TMP/${SID}-intent.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC2=$?
if [ "$ROUND1_OK" = "yes" ] && [ "$RC2" -eq 0 ] && [ ! -e "$OUT" ]; then
    pass "C4b: stale output deleted when both inputs disappear"
else
    fail "C4b: round1=$ROUND1_OK rc2=$RC2 out_exists=$([ -e "$OUT" ] && echo yes || echo no)"
fi

# ============================================================================
# C5 — intent.md present but empty (zero bytes)
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
touch "$TMP/${SID}-intent.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$OUT" ]; then
    pass "C5: zero-byte intent.md treated as absent"
else
    fail "C5: rc=$RC out_exists=$([ -e "$OUT" ] && echo yes || echo no)"
fi

# ============================================================================
# C5b — both empty + stale pre-existing output
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
touch "$TMP/${SID}-intent.md"
touch "$TMP/${SID}-outline.md"
echo "stale prior output" > "$OUT"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$OUT" ]; then
    pass "C5b: both empty + stale output → output deleted"
else
    fail "C5b: rc=$RC out_exists=$([ -e "$OUT" ] && echo yes || echo no)"
fi

# ============================================================================
# C6 — Source comment contains resolved plans-dir path
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
printf '%s\n' "$INTENT_CONTENT" > "$TMP/${SID}-intent.md"
printf '%s\n' "$OUTLINE_CONTENT" > "$TMP/${SID}-outline.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -qF "<!-- Source: $TMP/${SID}-intent.md -->" "$OUT" \
   && grep -qF "<!-- Source: $TMP/${SID}-outline.md -->" "$OUT"; then
    pass "C6: Source comments contain resolved plans-dir path"
else
    fail "C6: rc=$RC — Source comment missing or unresolved"
fi

# ============================================================================
# C7 — Argument validation
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"

run_with_timeout 10 "$SUT" --session-id "$SID" --output "$OUT" >/dev/null 2>&1
RC_NO_PLANS=$?
run_with_timeout 10 "$SUT" --plans-dir "$TMP" --output "$OUT" >/dev/null 2>&1
RC_NO_SID=$?
run_with_timeout 10 "$SUT" --plans-dir "$TMP" --session-id "$SID" >/dev/null 2>&1
RC_NO_OUT=$?
run_with_timeout 10 "$SUT" --plans-dir "$TMP" --session-id "$SID" --output "$OUT" --bogus >/dev/null 2>&1
RC_BOGUS=$?

if [ "$RC_NO_PLANS" -eq 1 ] \
   && [ "$RC_NO_SID" -eq 1 ] \
   && [ "$RC_NO_OUT" -eq 1 ] \
   && [ "$RC_BOGUS" -eq 1 ]; then
    pass "C7: argument validation → exit 1 for missing/unknown flags"
else
    fail "C7: no_plans=$RC_NO_PLANS no_sid=$RC_NO_SID no_out=$RC_NO_OUT bogus=$RC_BOGUS"
fi

# ============================================================================
# C8 — Overwrite stale intent-only output when outline added later
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
printf '%s\n' "$INTENT_CONTENT" > "$TMP/${SID}-intent.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC1=$?
R1_OK=$([ "$RC1" -eq 0 ] && grep -qF "## Section 1:" "$OUT" && ! grep -qF "## Section 2:" "$OUT" && echo yes || echo no)
printf '%s\n' "$OUTLINE_CONTENT" > "$TMP/${SID}-outline.md"
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC2=$?
if [ "$R1_OK" = "yes" ] && [ "$RC2" -eq 0 ] \
   && grep -qF "## Section 1:" "$OUT" \
   && grep -qF "## Section 2:" "$OUT"; then
    pass "C8: stale intent-only output replaced with both sections"
else
    fail "C8: round1=$R1_OK rc2=$RC2"
fi

# ============================================================================
# C10 — Path with spaces
# ============================================================================
SPACE_TMP="$(mktemp -d)"
ALL_TMPS+=("$SPACE_TMP")
SPACE_DIR="$SPACE_TMP/with space"
mkdir -p "$SPACE_DIR/drafts"
OUT="$SPACE_DIR/drafts/test-context.md"
printf '%s\n' "$INTENT_CONTENT" > "$SPACE_DIR/${SID}-intent.md"
printf '%s\n' "$OUTLINE_CONTENT" > "$SPACE_DIR/${SID}-outline.md"
run_sut "$SPACE_DIR" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
SEP_COUNT=$(grep -cE "^---$" "$OUT" 2>/dev/null || echo 0)
S1_LINE=$(grep -nF "## Section 1: Intent" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
SEP_LINE=$(grep -nE "^---$" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
S2_LINE=$(grep -nF "## Section 2: Outline" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
if [ "$RC" -eq 0 ] \
   && [ -f "$OUT" ] \
   && [ "$SEP_COUNT" -eq 1 ] \
   && [ -n "$S1_LINE" ] && [ -n "$SEP_LINE" ] && [ -n "$S2_LINE" ] \
   && [ "$S1_LINE" -lt "$SEP_LINE" ] && [ "$SEP_LINE" -lt "$S2_LINE" ]; then
    pass "C10: path with spaces handled correctly"
else
    fail "C10: rc=$RC sep_count=$SEP_COUNT s1=$S1_LINE sep=$SEP_LINE s2=$S2_LINE"
fi

# ============================================================================
# C11 — No trailing newline in inputs
# ============================================================================
TMP="$(mk_tmp)"
OUT="$TMP/drafts/test-context.md"
printf '%s' "$INTENT_CONTENT" > "$TMP/${SID}-intent.md"
printf '%s' "$OUTLINE_CONTENT" > "$TMP/${SID}-outline.md"
# Sanity: confirm fixtures truly lack trailing newline.
INT_TAIL=$(tail -c1 "$TMP/${SID}-intent.md" | wc -l | tr -d ' ')
OUT_TAIL=$(tail -c1 "$TMP/${SID}-outline.md" | wc -l | tr -d ' ')
run_sut "$TMP" "$SID" "$OUT" >/dev/null 2>&1
RC=$?
SEP_COUNT=$(grep -cE "^---$" "$OUT" 2>/dev/null || echo 0)
S2_COUNT=$(grep -cE "^## Section 2: Outline \(Design Proposal\)$" "$OUT" 2>/dev/null || echo 0)
S1_LINE=$(grep -nF "## Section 1: Intent" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
SEP_LINE=$(grep -nE "^---$" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
S2_LINE=$(grep -nF "## Section 2: Outline" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
if [ "$INT_TAIL" = "0" ] && [ "$OUT_TAIL" = "0" ] \
   && [ "$RC" -eq 0 ] \
   && [ "$SEP_COUNT" -eq 1 ] \
   && [ "$S2_COUNT" -eq 1 ] \
   && [ "$S1_LINE" -lt "$SEP_LINE" ] && [ "$SEP_LINE" -lt "$S2_LINE" ]; then
    pass "C11: no-trailing-newline inputs → newline injected, --- on its own line"
else
    fail "C11: int_tail=$INT_TAIL out_tail=$OUT_TAIL rc=$RC sep=$SEP_COUNT s2=$S2_COUNT order=$S1_LINE,$SEP_LINE,$S2_LINE"
fi

# ============================================================================
# C9 — No leftover tempfiles in any temp dir used above
# ============================================================================
LEFTOVERS=0
for d in "${ALL_TMPS[@]}"; do
    [ -d "$d" ] || continue
    n=$(find "$d" -name '.build-codex-context.*' 2>/dev/null | wc -l | tr -d ' ')
    LEFTOVERS=$((LEFTOVERS + n))
done
if [ "$LEFTOVERS" -eq 0 ]; then
    pass "C9: no leftover .build-codex-context.* tempfiles"
else
    fail "C9: $LEFTOVERS leftover tempfile(s)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

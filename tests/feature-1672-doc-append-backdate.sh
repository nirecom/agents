#!/usr/bin/env bash
# Tests: bin/doc-append.py, bin/github-issues/issue-to-history.sh
# Tags: history, docs, backdate, bin, scope:issue-specific
#
# Tests for issue #1672 --allow-backdate: doc-append.py's ascending-date
# guard (DATE_ORDER_TOLERANCE_DAYS=7) is skipped when --allow-backdate is
# passed, so /issue-reconcile can backfill long-closed issues. Also verifies
# issue-to-history.sh forwards --allow-backdate / --no-auto-rotate to
# doc-append unchanged.
#
# TL3 gap (what this test does NOT catch):
# - Real /issue-reconcile invoking issue-to-history.sh end-to-end against a
#   live gh CLI and a real docs/history.md (this test uses temp fixtures and
#   DRY_RUN passthrough checks only).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: none (docs-only
# backfill tool, not in the risk-category list).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC_APPEND_PY="$AGENTS_DIR/bin/doc-append.py"
ISSUE_TO_HISTORY="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_da() {
    # run_da <file> [args...] — invokes doc-append.py against the local
    # worktree copy directly (not the globally-installed shim, which may
    # point at a different checkout of the repo).
    uv run python "$DOC_APPEND_PY" "$@"
}

setup_fixture() {
    # setup_fixture <last_date> — writes a docs/history.md with one existing
    # FEATURE entry dated <last_date>. Prints the tmp dir's history.md path.
    local last_date="$1"
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/docs"
    cat > "$tmp/docs/history.md" <<EOF
### FEATURE: Existing entry ($last_date)
Background: existing bg
Changes: existing changes
EOF
    echo "$tmp/docs/history.md"
}

if [ ! -f "$DOC_APPEND_PY" ]; then
    fail "precondition: $DOC_APPEND_PY missing"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# --- Case 1: backdated append WITHOUT --allow-backdate rejected, file untouched ---
F1=$(setup_fixture "2026-01-20")
BEFORE_SUM=$(sha256sum "$F1" | awk '{print $1}')
run_da "$F1" --no-auto-rotate --category FEATURE --subject "Too old" \
    --date "2026-01-01" --background "bg" --changes "ch" >/tmp/c1.out 2>/tmp/c1.err
RC=$?
AFTER_SUM=$(sha256sum "$F1" | awk '{print $1}')
if [ "$RC" -ne 0 ] && [ "$BEFORE_SUM" = "$AFTER_SUM" ]; then
    pass "1: backdated append without --allow-backdate rejected, file byte-identical"
else
    fail "1: rc=$RC before=$BEFORE_SUM after=$AFTER_SUM stderr=$(cat /tmp/c1.err)"
fi
rm -rf "$(dirname "$(dirname "$F1")")"

# --- Case 2: same append WITH --allow-backdate succeeds, entry present ---
F2=$(setup_fixture "2026-01-20")
run_da "$F2" --no-auto-rotate --allow-backdate --category FEATURE --subject "Too old but allowed" \
    --date "2026-01-01" --background "bg" --changes "ch" >/tmp/c2.out 2>/tmp/c2.err
RC=$?
if [ "$RC" -eq 0 ] && grep -q "Too old but allowed" "$F2"; then
    pass "2: --allow-backdate accepts backdated append, entry present"
else
    fail "2: rc=$RC stderr=$(cat /tmp/c2.err) content=$(cat "$F2")"
fi
rm -rf "$(dirname "$(dirname "$F2")")"

# --- Case 3: exactly 7 days before last entry accepted WITHOUT the flag (boundary) ---
F3=$(setup_fixture "2026-01-20")
run_da "$F3" --no-auto-rotate --category FEATURE --subject "Exactly 7 days before" \
    --date "2026-01-13" --background "bg" --changes "ch" >/tmp/c3.out 2>/tmp/c3.err
RC=$?
if [ "$RC" -eq 0 ] && grep -q "Exactly 7 days before" "$F3"; then
    pass "3: 7-day-old entry accepted without --allow-backdate (tolerance boundary)"
else
    fail "3: rc=$RC stderr=$(cat /tmp/c3.err)"
fi
rm -rf "$(dirname "$(dirname "$F3")")"

# --- Case 4: 8 days before rejected WITHOUT flag, accepted WITH flag ---
F4a=$(setup_fixture "2026-01-20")
run_da "$F4a" --no-auto-rotate --category FEATURE --subject "8 days before" \
    --date "2026-01-12" --background "bg" --changes "ch" >/tmp/c4a.out 2>/tmp/c4a.err
RC4A=$?
if [ "$RC4A" -ne 0 ]; then
    pass "4a: 8-day-old entry rejected without --allow-backdate (past boundary)"
else
    fail "4a: expected rejection, rc=$RC4A"
fi
rm -rf "$(dirname "$(dirname "$F4a")")"

F4b=$(setup_fixture "2026-01-20")
run_da "$F4b" --no-auto-rotate --allow-backdate --category FEATURE --subject "8 days before allowed" \
    --date "2026-01-12" --background "bg" --changes "ch" >/tmp/c4b.out 2>/tmp/c4b.err
RC4B=$?
if [ "$RC4B" -eq 0 ] && grep -q "8 days before allowed" "$F4b"; then
    pass "4b: 8-day-old entry accepted with --allow-backdate"
else
    fail "4b: rc=$RC4B stderr=$(cat /tmp/c4b.err)"
fi
rm -rf "$(dirname "$(dirname "$F4b")")"

# --- Case 5: flag is inert for a normal forward-dated append ---
F5=$(setup_fixture "2026-01-20")
run_da "$F5" --no-auto-rotate --allow-backdate --category FEATURE --subject "Forward dated" \
    --date "2026-02-01" --background "bg" --changes "ch" >/tmp/c5.out 2>/tmp/c5.err
RC=$?
if [ "$RC" -eq 0 ] && grep -q "Forward dated" "$F5"; then
    pass "5: --allow-backdate inert on normal forward-dated append"
else
    fail "5: rc=$RC stderr=$(cat /tmp/c5.err)"
fi
rm -rf "$(dirname "$(dirname "$F5")")"

# --- Case 6: --allow-backdate does NOT disable unrelated BUGFIX/--test-gap guard ---
F6=$(setup_fixture "2026-01-20")
run_da "$F6" --no-auto-rotate --allow-backdate --category BUGFIX --subject "Missing test gap" \
    --date "2026-01-21" --background "bg" --changes "ch" >/tmp/c6.out 2>/tmp/c6.err
RC=$?
if [ "$RC" -ne 0 ] && grep -qi "test-gap" /tmp/c6.err; then
    pass "6: --allow-backdate does not bypass BUGFIX --test-gap requirement on history.md"
else
    fail "6: rc=$RC stderr=$(cat /tmp/c6.err)"
fi
rm -rf "$(dirname "$(dirname "$F6")")"

# --- Case 7: pre-existing entries still sorted ascending; new backdated entry lands at tail ---
tmp7=$(mktemp -d)
mkdir -p "$tmp7/docs"
F7="$tmp7/docs/history.md"
cat > "$F7" <<EOF
### FEATURE: Newest existing (2026-01-20)
Background: b
Changes: c

### FEATURE: Oldest existing (2026-01-05)
Background: b
Changes: c

### FEATURE: Mid existing (2026-01-15)
Background: b
Changes: c
EOF
run_da "$F7" --no-auto-rotate --allow-backdate --category FEATURE --subject "Backfilled tail entry" \
    --date "2025-01-01" --background "bg" --changes "ch" >/tmp/c7.out 2>/tmp/c7.err
RC=$?
LINE_OLDEST=$(grep -n "Oldest existing" "$F7" | head -1 | cut -d: -f1)
LINE_MID=$(grep -n "Mid existing" "$F7" | head -1 | cut -d: -f1)
LINE_NEWEST=$(grep -n "Newest existing" "$F7" | head -1 | cut -d: -f1)
LINE_TAIL=$(grep -n "Backfilled tail entry" "$F7" | head -1 | cut -d: -f1)
if [ "$RC" -eq 0 ] && [ -n "$LINE_OLDEST" ] && [ -n "$LINE_MID" ] && [ -n "$LINE_NEWEST" ] && [ -n "$LINE_TAIL" ] \
    && [ "$LINE_OLDEST" -lt "$LINE_MID" ] && [ "$LINE_MID" -lt "$LINE_NEWEST" ] && [ "$LINE_NEWEST" -lt "$LINE_TAIL" ]; then
    pass "7: pre-existing entries sorted ascending, backdated entry appended at tail"
else
    fail "7: rc=$RC oldest=$LINE_OLDEST mid=$LINE_MID newest=$LINE_NEWEST tail=$LINE_TAIL content=$(cat "$F7")"
fi
rm -rf "$tmp7"

# --- Case 8: issue-to-history.sh DRY_RUN passthrough — --allow-backdate ---
if [ -x "$ISSUE_TO_HISTORY" ]; then
    out8_with=$(ISSUE_BODY=$'## Background\n\nb\n\n## Changes\n\nc' ISSUE_CATEGORY=FEATURE \
        ISSUE_NUMBER=0 ISSUE_TITLE="smoke" DRY_RUN=1 \
        bash "$ISSUE_TO_HISTORY" 0 --allow-backdate 2>&1)
    out8_without=$(ISSUE_BODY=$'## Background\n\nb\n\n## Changes\n\nc' ISSUE_CATEGORY=FEATURE \
        ISSUE_NUMBER=0 ISSUE_TITLE="smoke" DRY_RUN=1 \
        bash "$ISSUE_TO_HISTORY" 0 2>&1)
    if echo "$out8_with" | grep -q -- "--allow-backdate" && ! echo "$out8_without" | grep -q -- "--allow-backdate"; then
        pass "8: issue-to-history.sh forwards --allow-backdate to doc-append args iff passed"
    else
        fail "8: with='$out8_with' without='$out8_without'"
    fi
else
    fail "8 (precondition): $ISSUE_TO_HISTORY not found or not executable"
fi

# --- Case 9: issue-to-history.sh DRY_RUN passthrough — --no-auto-rotate ---
if [ -x "$ISSUE_TO_HISTORY" ]; then
    out9_with=$(ISSUE_BODY=$'## Background\n\nb\n\n## Changes\n\nc' ISSUE_CATEGORY=FEATURE \
        ISSUE_NUMBER=0 ISSUE_TITLE="smoke" DRY_RUN=1 \
        bash "$ISSUE_TO_HISTORY" 0 --no-auto-rotate 2>&1)
    out9_without=$(ISSUE_BODY=$'## Background\n\nb\n\n## Changes\n\nc' ISSUE_CATEGORY=FEATURE \
        ISSUE_NUMBER=0 ISSUE_TITLE="smoke" DRY_RUN=1 \
        bash "$ISSUE_TO_HISTORY" 0 2>&1)
    if echo "$out9_with" | grep -q -- "--no-auto-rotate" && ! echo "$out9_without" | grep -q -- "--no-auto-rotate"; then
        pass "9: issue-to-history.sh forwards --no-auto-rotate to doc-append args iff passed"
    else
        fail "9: with='$out9_with' without='$out9_without'"
    fi
else
    fail "9 (precondition): $ISSUE_TO_HISTORY not found or not executable"
fi

# --- Case 10: both flags passed together are both forwarded ---
if [ -x "$ISSUE_TO_HISTORY" ]; then
    out10=$(ISSUE_BODY=$'## Background\n\nb\n\n## Changes\n\nc' ISSUE_CATEGORY=FEATURE \
        ISSUE_NUMBER=0 ISSUE_TITLE="smoke" DRY_RUN=1 \
        bash "$ISSUE_TO_HISTORY" 0 --allow-backdate --no-auto-rotate 2>&1)
    if echo "$out10" | grep -q -- "--allow-backdate" && echo "$out10" | grep -q -- "--no-auto-rotate"; then
        pass "10: both --allow-backdate and --no-auto-rotate forwarded together"
    else
        fail "10: out='$out10'"
    fi
else
    fail "10 (precondition): $ISSUE_TO_HISTORY not found or not executable"
fi

rm -f /tmp/c1.out /tmp/c1.err /tmp/c2.out /tmp/c2.err /tmp/c3.out /tmp/c3.err \
    /tmp/c4a.out /tmp/c4a.err /tmp/c4b.out /tmp/c4b.err /tmp/c5.out /tmp/c5.err \
    /tmp/c6.out /tmp/c6.err /tmp/c7.out /tmp/c7.err

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

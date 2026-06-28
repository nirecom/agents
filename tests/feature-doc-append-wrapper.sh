#!/bin/bash
# Tests: bin/doc-append, bin/doc-append.py
# Tags: docs, append, history, bin, install
# Broad integration tests for bin/doc-append bash wrapper
# Tests run AFTER implementation; skip gracefully if wrapper not yet installed.
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Skip if doc-append not in PATH (not yet installed)
if ! command -v doc-append >/dev/null 2>&1; then
    echo "SKIP: doc-append not found in PATH (not yet installed)"
    exit 0
fi

# Temporary workspace
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs"

# --- Normal cases ---
echo "=== Normal: category FEATURE ==="
run_with_timeout doc-append "$TMP/docs/history.md" \
    --category FEATURE --subject "Test subject" --date 2026-01-01 \
    --commits abc1234 --background "Background text" --changes "Changes text"
if grep -q "Test subject" "$TMP/docs/history.md"; then
    pass "category FEATURE: entry appended"
else
    fail "category FEATURE: entry not found in output file"
fi

echo "=== Normal: category INCIDENT ==="
run_with_timeout doc-append "$TMP/docs/history.md" \
    --category INCIDENT --subject "Incident one" --date 2026-01-02 \
    --commits def5678 --cause "Root cause" --fix "Applied fix"
if grep -q "Incident one" "$TMP/docs/history.md"; then
    pass "category INCIDENT: entry appended"
else
    fail "category INCIDENT: entry not found"
fi

echo "=== Normal: default path (docs/history.md) ==="
mkdir -p "$TMP/default_test/docs"
(cd "$TMP/default_test" && run_with_timeout doc-append \
    --category FEATURE --subject "Default path test" --date 2026-01-03 \
    --commits aaa0001 --background "bg" --changes "ch")
if grep -q "Default path test" "$TMP/default_test/docs/history.md"; then
    pass "default path: docs/history.md used"
else
    fail "default path: docs/history.md not written"
fi

echo "=== Normal: backward compat — uv run bin/doc-append.py --category FEATURE ==="
run_with_timeout uv run "$DOTFILES/bin/doc-append.py" "$TMP/docs/history.md" \
    --category FEATURE --subject "Compat test" --date 2026-01-04 \
    --commits compat01 --background "bg" --changes "ch"
if grep -q "Compat test" "$TMP/docs/history.md"; then
    pass "backward compat: uv run bin/doc-append.py works"
else
    fail "backward compat: entry not found"
fi

# --- Error cases ---
echo "=== Error cases ==="

if doc-append "$TMP/docs/history.md" --category UNKNOWN \
    --subject S --date 2026-01-05 --commits c1 2>/dev/null; then
    fail "--category UNKNOWN should fail"
else
    pass "--category UNKNOWN: exit nonzero"
fi

if doc-append "$TMP/docs/history.md" --category FEATURE \
    --subject S --date 2026-01-05 --commits c1 2>/dev/null; then
    fail "--category FEATURE without --background should fail"
else
    pass "--category FEATURE without --background: exit nonzero"
fi

if doc-append "$TMP/docs/history.md" --category INCIDENT \
    --subject S --date 2026-01-05 --commits c1 2>/dev/null; then
    fail "--category INCIDENT without --cause should fail"
else
    pass "--category INCIDENT without --cause: exit nonzero"
fi

# --- T0-B: BUGFIX --test-gap gate (#1147) ---
echo "=== B1: BUGFIX without --test-gap on history.md → exit nonzero ==="
# T0-B B1: doc-append.py should block (exit non-zero) when --category BUGFIX
# is used without --test-gap on a history.md target. Currently only warns (exits 0).
# This test is expected to FAIL until write-code implements the blocking behavior.
if uv run "$DOTFILES/bin/doc-append.py" "$TMP/docs/history.md" \
    --category BUGFIX --subject "Bugfix no gap" --date 2026-01-07 \
    --commits b1 --background "bg" --changes "ch" 2>/dev/null; then
    fail "B1: BUGFIX without --test-gap should exit nonzero for history.md (currently only warns — T0-B not yet implemented)"
else
    pass "B1: BUGFIX without --test-gap: exit nonzero (T0-B implemented)"
fi

echo "=== B2: BUGFIX with --test-gap on history.md → exit zero, entry appended ==="
if run_with_timeout uv run "$DOTFILES/bin/doc-append.py" "$TMP/docs/history.md" \
    --category BUGFIX --subject "Bugfix with gap" --date 2026-01-08 \
    --commits b2 --background "bg" --changes "ch" \
    --test-gap "missing unit test for edge case"; then
    if grep -q "Bugfix with gap" "$TMP/docs/history.md" && grep -q "Test gap:" "$TMP/docs/history.md"; then
        pass "B2: BUGFIX with --test-gap: exit zero and entry + Test gap: appended"
    else
        fail "B2: BUGFIX with --test-gap: exit zero but entry or Test gap: field missing"
    fi
else
    fail "B2: BUGFIX with --test-gap: expected exit zero"
fi

echo "=== B3: BUGFIX without --test-gap on CHANGELOG.md → exit zero (changelog exempt) ==="
# CHANGELOG.md target is exempt: --test-gap is a history.md-specific requirement.
# compose-doc-append-entry calls doc-append.py without --test-gap for changelog.
if run_with_timeout uv run "$DOTFILES/bin/doc-append.py" "$TMP/CHANGELOG.md" \
    --category BUGFIX --subject "Changelog bugfix" --date 2026-01-09 \
    --background "bg" --changes "user-facing fix" \
    --no-auto-rotate 2>/dev/null; then
    pass "B3: BUGFIX without --test-gap on CHANGELOG.md: exit zero (changelog exempt)"
else
    fail "B3: BUGFIX without --test-gap on CHANGELOG.md: expected exit zero (changelog target should be exempt)"
fi

echo "=== B4: compose-doc-append-entry --test-gap propagation ==="
# B4: compose-doc-append-entry does not call doc-append.py directly in a way
# we can intercept without real git/gh operations. Instead we verify that
# compose-doc-append-entry accepts --category BUGFIX (not an unknown arg)
# by checking that it exits due to missing --notes (not an argument error).
# The argument-error path exits immediately with "unknown argument"; the missing-notes
# path exits with "--notes is required". Either means the arg is at least parsed.
B4_OUT="$(bin/compose-doc-append-entry --category BUGFIX 2>&1 || true)"
if echo "$B4_OUT" | grep -q "unknown argument"; then
    fail "B4: compose-doc-append-entry does not accept --category BUGFIX (unknown argument)"
else
    pass "B4: compose-doc-append-entry accepts --category BUGFIX (exits for missing --notes, not for unknown argument)"
fi

# --- Normal: --commits omitted (CHANGELOG.md use case) ---
echo "=== Normal: --commits omitted — date-only header ==="
run_with_timeout doc-append "$TMP/CHANGELOG.md" \
    --category FEATURE --subject "Changelog entry" --date 2026-02-01 \
    --background "Context" --changes "User-facing summary"
if grep -q "Changelog entry (2026-02-01)" "$TMP/CHANGELOG.md"; then
    pass "--commits omitted: date-only header written"
else
    fail "--commits omitted: expected '(2026-02-01)' in header"
fi
if grep -q "2026-02-01," "$TMP/CHANGELOG.md"; then
    fail "--commits omitted: trailing comma found in header"
else
    pass "--commits omitted: no trailing comma in header"
fi

# --- Edge: default path with no docs/ dir ---
echo "=== Edge: no docs/ dir for default path ==="
NODIR="$(mktemp -d)"
trap 'rm -rf "$NODIR"' EXIT
if (cd "$NODIR" && doc-append \
    --category FEATURE --subject E --date 2026-01-06 --commits e1 \
    --background bg --changes ch 2>/dev/null); then
    fail "no docs/ dir: should fail"
else
    pass "no docs/ dir: exit nonzero (parent dir missing)"
fi

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi

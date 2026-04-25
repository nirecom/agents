#!/bin/bash
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

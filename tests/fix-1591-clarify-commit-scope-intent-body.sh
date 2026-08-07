#!/bin/bash
# tests/fix-1591-clarify-commit-scope-intent-body.sh
# Tests: bin/github-issues/clarify-commit-scope.sh
# Tags: clarify-intent, github, issues, scan-outbound, security, scope:issue-specific, layer:TL2
#
# Issue #1591 — clarify-commit-scope Path C composes the intent Title+Body into a
# temp file, runs gh_outbound_guard "$INTENT_PATH" < tmp, and on block writes the
# reason to a sidecar <PLANS_DIR>/<sid>-intent-scan-block.txt (the caller discards
# stderr), prints SCAN_BLOCKED, exits 2. On success it calls gh issue create with
# --title = Title line and --body = Background+Scope only.
#
# RED until /write-code creates gh-outbound-guard.sh + intent-to-issue.sh and
# rewrites Path C.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCS="$AGENTS_DIR/bin/github-issues/clarify-commit-scope.sh"
GUARD_LIB="$AGENTS_DIR/bin/lib/gh-outbound-guard.sh"
REAL_SCANNER="$AGENTS_DIR/bin/scan-outbound.sh"

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

TMP=""
SID="sid-test-1591"

setup() {
    TMP="$(mktemp -d)"
    export MOCK_LOG_DIR="$TMP"
    mkdir -p "$TMP/mock-bin" "$TMP/plans" "$TMP/acd/bin"
    # Real scanner isolated in a controlled AGENTS_CONFIG_DIR.
    cp "$REAL_SCANNER" "$TMP/acd/bin/scan-outbound.sh"
    chmod +x "$TMP/acd/bin/scan-outbound.sh"
    : > "$TMP/acd/.private-info-allowlist"
    : > "$TMP/acd/.private-info-blocklist"
    # gh mock — records every call; issue create returns a canned URL.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$*" in
  issue\ create*) echo "https://github.com/nirecom/agents/issues/999"; exit 0 ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_CONFIG_DIR="$TMP/acd"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    unset MOCK_LOG_DIR WORKFLOW_PLANS_DIR 2>/dev/null || true
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    TMP=""
}

write_intent() {
    cat > "$TMP/plans/${SID}-intent.md" <<EOF
# Tracking issue — ${SID}

**Title:** Add outbound scan guard

## Issues
- closes #1591

## Background / Motivation
BACKGROUND_MARKER: scanner is blind to gh subprocess calls.$1

## Scope
SCOPE_MARKER: wrap gh free-text calls.

## Accepted Tradeoffs
TRADEOFF_MARKER: internal note, must not leak into the issue body.
EOF
}

if [ ! -f "$GUARD_LIB" ]; then
    fail "C-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# C-1: clean intent.md -> gh issue create with --title = Title line and
# --body containing Background+Scope only (no internal Tradeoffs section).
setup
write_intent ""
OUT=$(run_with_timeout 20 bash "$CCS" \
    --session-id "$SID" --plans-dir "$TMP/plans" --issues "" 2>/dev/null)
RC=$?
GH=$(cat "$TMP/gh-calls.log" 2>/dev/null || true)
if [ "$RC" -eq 0 ] \
    && echo "$GH" | grep -q "issue create" \
    && echo "$GH" | grep -q "Add outbound scan guard" \
    && echo "$GH" | grep -q "BACKGROUND_MARKER" \
    && echo "$GH" | grep -q "SCOPE_MARKER" \
    && ! echo "$GH" | grep -q "TRADEOFF_MARKER"; then
    pass "C-1: clean intent -> gh issue create title=Title, body=Background+Scope (no internal)"
else
    fail "C-1: expected clean create title/body; got rc=$RC gh='$GH'"
fi
teardown

# C-2: intent.md with a blocked pattern -> SCAN_BLOCKED on stdout, exit 2,
# sidecar file created with reason text, gh issue create NEVER invoked.
setup
write_intent " deploy host 10.0.0.1 leak"
OUT=$(run_with_timeout 20 bash "$CCS" \
    --session-id "$SID" --plans-dir "$TMP/plans" --issues "" 2>/dev/null)
RC=$?
GH=$(cat "$TMP/gh-calls.log" 2>/dev/null || true)
SIDECAR="$TMP/plans/${SID}-intent-scan-block.txt"
if [ "$RC" -eq 2 ] \
    && echo "$OUT" | grep -q "SCAN_BLOCKED" \
    && [ -s "$SIDECAR" ] \
    && ! echo "$GH" | grep -q "issue create"; then
    pass "C-2: blocked intent -> SCAN_BLOCKED, exit 2, sidecar written, no gh create"
else
    fail "C-2: expected SCAN_BLOCKED exit2 sidecar no-create; got rc=$RC out='$OUT' sidecar-exists=$([ -s "$SIDECAR" ] && echo y || echo n) gh='$GH'"
fi
teardown

# C-3: missing intent.md -> exit 1 (Path C cannot compose a body).
setup
# deliberately do NOT write the intent file
OUT=$(run_with_timeout 20 bash "$CCS" \
    --session-id "$SID" --plans-dir "$TMP/plans" --issues "" 2>/dev/null)
RC=$?
GH=$(cat "$TMP/gh-calls.log" 2>/dev/null || true)
if [ "$RC" -eq 1 ] && ! echo "$GH" | grep -q "issue create"; then
    pass "C-3: missing intent.md -> exit 1, no gh create"
else
    fail "C-3: expected exit 1 no-create; got rc=$RC gh='$GH'"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))

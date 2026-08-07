#!/bin/bash
# tests/fix-1591-issue-create-scan.sh
# Tests: bin/github-issues/issue-create.sh
# Tags: github, issues, scan-outbound, security, scope:issue-specific, layer:TL2
#
# Issue #1591 — issue-create.sh composes $TITLE + (body-file contents or $BODY)
# into one temp file and guards it before the real gh issue create. A blocked
# pattern in ANY field aborts (exit 1) before gh is invoked; body-file CONTENT is
# scanned (not just its filename). All-clean reaches gh.
#
# ISSUE_CREATE_SKIP_SCHEMA=1 isolates the guard from the Background/Changes schema
# check. RED until /write-code creates gh-outbound-guard.sh and wires the guard.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IC="$AGENTS_DIR/bin/github-issues/issue-create.sh"
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

setup() {
    TMP="$(mktemp -d)"
    export MOCK_LOG_DIR="$TMP"
    mkdir -p "$TMP/mock-bin" "$TMP/acd/bin"
    cp "$REAL_SCANNER" "$TMP/acd/bin/scan-outbound.sh"
    chmod +x "$TMP/acd/bin/scan-outbound.sh"
    : > "$TMP/acd/.private-info-allowlist"
    : > "$TMP/acd/.private-info-blocklist"
    # is-github-dotcom-remote mock -> non-github (exit 1) so Phase 0a label
    # auto-repair is skipped and no preflight/sync mocks are needed.
    cat > "$TMP/acd/bin/is-github-dotcom-remote" <<'MOCKREMOTE'
#!/usr/bin/env bash
exit 1
MOCKREMOTE
    chmod +x "$TMP/acd/bin/is-github-dotcom-remote"
    # gh mock — logs; auth status advertises project scope; issue create returns URL.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$*" in
  auth\ status*) echo "scopes: 'project', 'repo'"; exit 0 ;;
  issue\ create*) echo "https://github.com/nirecom/agents/issues/999"; exit 0 ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_CONFIG_DIR="$TMP/acd"
    export ISSUE_CREATE_SKIP_SCHEMA=1
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    unset MOCK_LOG_DIR ISSUE_CREATE_SKIP_SCHEMA 2>/dev/null || true
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    TMP=""
}

gh_created() { cat "$TMP/gh-calls.log" 2>/dev/null | grep -q "issue create"; }

if [ ! -f "$GUARD_LIB" ]; then
    fail "IC-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# IC-1: blocked pattern ONLY in --title -> abort before gh, exit 1.
setup
RC=0
run_with_timeout 20 bash "$IC" --title "host 10.0.0.1 title" --body "clean body text" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_created; then
    pass "IC-1: blocked --title -> exit 1, gh issue create not reached"
else
    fail "IC-1: expected exit 1 no-create; got rc=$RC created=$(gh_created && echo y || echo n)"
fi
teardown

# IC-2: blocked pattern ONLY in --body -> abort before gh, exit 1.
setup
RC=0
run_with_timeout 20 bash "$IC" --title "clean title" --body "leak 10.0.0.1 here" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_created; then
    pass "IC-2: blocked --body -> exit 1, gh issue create not reached"
else
    fail "IC-2: expected exit 1 no-create; got rc=$RC created=$(gh_created && echo y || echo n)"
fi
teardown

# IC-3: blocked pattern ONLY inside --body-file CONTENTS (filename clean) -> abort.
# Proves body-file content is scanned, not just the path.
setup
BF="$TMP/body.md"; printf 'clean line\ninternal host 10.0.0.1 leaked\n' > "$BF"
RC=0
run_with_timeout 20 bash "$IC" --title "clean title" --body-file "$BF" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_created; then
    pass "IC-3: blocked --body-file CONTENT -> exit 1, gh not reached (content scanned)"
else
    fail "IC-3: expected exit 1 no-create; got rc=$RC created=$(gh_created && echo y || echo n)"
fi
teardown

# IC-4: all-clean -> gh issue create IS reached.
setup
RC=0
run_with_timeout 20 bash "$IC" --title "clean title" --body "perfectly ordinary body" >/dev/null 2>&1 || RC=$?
if gh_created; then
    pass "IC-4: all-clean -> gh issue create reached (rc=$RC)"
else
    fail "IC-4: expected gh issue create reached; got rc=$RC gh='$(cat "$TMP/gh-calls.log" 2>/dev/null)'"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))

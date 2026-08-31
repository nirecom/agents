#!/bin/bash
# tests/fix-1591-forge-write-scan.sh
# Tests: bin/github-issues/reopen-with-update.sh, bin/lib/github-contents-write.sh, bin/lib/github-git-data-write.sh
# Tags: github, issues, contents-api, git-data-api, scan-outbound, security, scope:issue-specific, layer:TL2
#
# Issue #1591 — outbound-scan guards on forge-write paths: reopen-with-update.sh,
# github-contents-write.sh, github-git-data-write.sh. Block aborts before gh api push.
# RED until /write-code creates gh-outbound-guard.sh and wires each script.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REOPEN="$AGENTS_DIR/bin/github-issues/reopen-with-update.sh"
CONTENTS="$AGENTS_DIR/bin/lib/github-contents-write.sh"
GITDATA="$AGENTS_DIR/bin/lib/github-git-data-write.sh"
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
BLOCKED_IP="10.0.0.1"   # RFC 1918 private IP — hard-block under a non-tests label.

setup() {
    TMP="$(mktemp -d)"
    export MOCK_LOG_DIR="$TMP"
    mkdir -p "$TMP/mock-bin" "$TMP/acd/bin"
    cp "$REAL_SCANNER" "$TMP/acd/bin/scan-outbound.sh"
    chmod +x "$TMP/acd/bin/scan-outbound.sh"
    : > "$TMP/acd/.private-info-allowlist"
    : > "$TMP/acd/.private-info-blocklist"
    # gh mock — logs every call. Returns a body containing $BLOCKED_IP for
    # `issue view` so reopen's composed body carries the blocked pattern.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$*" in
  repo\ view*)   echo "nirecom/agents"; exit 0 ;;
  issue\ reopen*) exit 0 ;;
  issue\ view*)  echo "existing body with host ${MOCK_VIEW_IP:-10.0.0.1} inside"; exit 0 ;;
  auth\ status*) echo "scopes: 'repo'"; exit 0 ;;
  api*)          echo "{}"; exit 0 ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_CONFIG_DIR="$TMP/acd"
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    unset MOCK_LOG_DIR MOCK_VIEW_IP 2>/dev/null || true
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    TMP=""
}

gh_api_called()   { cat "$TMP/gh-calls.log" 2>/dev/null | grep -qE '^gh api '; }
gh_edit_called()  { cat "$TMP/gh-calls.log" 2>/dev/null | grep -q 'issue edit'; }

if [ ! -f "$GUARD_LIB" ]; then
    fail "F-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# F-1: reopen-with-update — fetched body contains blocked pattern -> guard blocks
# the composed body before `gh issue edit --body-file`, exit 1.
setup
RC=0
run_with_timeout 20 bash "$REOPEN" 4242 >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_edit_called; then
    pass "F-1: reopen blocked body -> exit 1 before gh issue edit"
else
    fail "F-1: expected exit 1 no-edit; got rc=$RC edit=$(gh_edit_called && echo y || echo n)"
fi
teardown

# F-2: github-contents-write — blocked pattern in FILE content -> abort before gh api.
setup
CF="$TMP/history.md"; printf '# history\ninternal host %s here\n' "$BLOCKED_IP" > "$CF"
RC=0
run_with_timeout 20 bash "$CONTENTS" \
    --owner nirecom --repo agents --path docs/history.md \
    --file "$CF" --message "docs: update" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-2: contents-write blocked FILE content -> exit 1 before gh api"
else
    fail "F-2: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown

# F-3: github-contents-write — blocked pattern ONLY in --message (file clean) ->
# abort before gh api. Proves the commit message is scanned, not just the file.
setup
CF="$TMP/history.md"; printf '# history\nperfectly clean content\n' > "$CF"
RC=0
run_with_timeout 20 bash "$CONTENTS" \
    --owner nirecom --repo agents --path docs/history.md \
    --file "$CF" --message "deploy note host $BLOCKED_IP" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-3: contents-write blocked --message (clean file) -> exit 1 before gh api"
else
    fail "F-3: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown

# F-4: github-git-data-write — blocked pattern in one file's content (multi-file)
# -> abort before gh api blob push, exit 1.
setup
F1="$TMP/a.md"; printf 'clean a\n' > "$F1"
F2="$TMP/b.md"; printf 'leak host %s in b\n' "$BLOCKED_IP" > "$F2"
RC=0
run_with_timeout 20 bash "$GITDATA" \
    --owner nirecom --repo agents --branch main --message "docs: rotate" \
    --file "docs/a.md=$F1" --file "docs/b.md=$F2" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-4: git-data-write blocked file content (multi-file) -> exit 1 before gh api"
else
    fail "F-4: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown

# F-5: github-git-data-write — blocked pattern ONLY in --message (all files clean,
# multi-file) -> message-only leak still caught, exit 1 before gh api.
setup
F1="$TMP/a.md"; printf 'clean a\n' > "$F1"
F2="$TMP/b.md"; printf 'clean b\n' > "$F2"
RC=0
run_with_timeout 20 bash "$GITDATA" \
    --owner nirecom --repo agents --branch main --message "note host $BLOCKED_IP" \
    --file "docs/a.md=$F1" --file "docs/b.md=$F2" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-5: git-data-write blocked --message (clean files) -> exit 1 before gh api"
else
    fail "F-5: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown

# F-6: reopen-with-update — fetched body is CLEAN (no blocked pattern) -> guard
# allows the composed body through, real `gh issue edit --body-file` IS reached.
setup
export MOCK_VIEW_IP="a-clean-hostname-token"
RC=0
run_with_timeout 20 bash "$REOPEN" 4242 >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && gh_edit_called; then
    pass "F-6: reopen clean body -> exit 0, gh issue edit reached"
else
    fail "F-6: expected exit 0 edit called; got rc=$RC edit=$(gh_edit_called && echo y || echo n)"
fi
teardown

# F-7: github-contents-write — CLEAN file content AND clean --message -> guard
# allows through, real `gh api` call IS reached.
setup
CF="$TMP/history.md"; printf '# history\nperfectly clean content\n' > "$CF"
RC=0
run_with_timeout 20 bash "$CONTENTS" \
    --owner nirecom --repo agents --path docs/history.md \
    --file "$CF" --message "docs: update" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && gh_api_called; then
    pass "F-7: contents-write clean content+message -> exit 0, gh api reached"
else
    fail "F-7: expected exit 0 api called; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown

# F-8: github-git-data-write — CLEAN content in all files (multi-file) AND clean
# --message -> guard allows through, real `gh api` call IS reached.
setup
F1="$TMP/a.md"; printf 'clean a\n' > "$F1"
F2="$TMP/b.md"; printf 'clean b\n' > "$F2"
RC=0
run_with_timeout 20 bash "$GITDATA" \
    --owner nirecom --repo agents --branch main --message "docs: rotate" \
    --file "docs/a.md=$F1" --file "docs/b.md=$F2" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && gh_api_called; then
    pass "F-8: git-data-write clean files+message (multi-file) -> exit 0, gh api reached"
else
    fail "F-8: expected exit 0 api called; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))

#!/bin/bash
# Test suite for hooks/commit-msg warn-mode behavior.
#
# Tests target POST-implementation behavior:
#   - rc captured via `|| rc=$?` so set -e doesn't abort the post-message banner
#   - case branches on rc: 0 ok, 1 hard block, 2 warn (auto-block when no TTY)
#   - Hard violation banner "Commit blocked" still emitted
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
COMMITMSG_SRC="$DOTFILES_DIR/hooks/commit-msg"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_AGENTS="$TMPBASE/agents"
mkdir -p "$FAKE_AGENTS/bin" "$FAKE_AGENTS/hooks"
cp "$SCANNER_SRC"    "$FAKE_AGENTS/bin/scan-outbound.sh"
cp "$COMMITMSG_SRC"  "$FAKE_AGENTS/hooks/commit-msg"
chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh" "$FAKE_AGENTS/hooks/commit-msg"
: > "$FAKE_AGENTS/.private-info-allowlist"
cat > "$FAKE_AGENTS/.private-info-blocklist" <<'EOF'
forbiddenword[0-9]+
warn:suspicious[a-z]+pattern
EOF

# Mask gh so private-repo skip cannot trigger
STUB_BIN="$TMPBASE/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB_BIN/gh"
EXEC_PATH="$STUB_BIN:$PATH"

make_repo() {
    local repo="$1"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config core.hooksPath "$FAKE_AGENTS/hooks"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    PATH="$EXEC_PATH" git -C "$repo" -c core.hooksPath= commit -q -m "init"
    # Stage one trivial file so the per-test commit has content to commit
    echo "content" > "$repo/data.txt"
    git -C "$repo" add data.txt
}

run_commit_with_msg() {
    local repo="$1" msg="$2"
    local out
    set +e
    out="$(PATH="$EXEC_PATH" run_with_timeout git -C "$repo" commit -m "$msg" </dev/null 2>&1)"
    CM_RC=$?
    set -e
    CM_OUT="$out"
}

echo "=== Normal: clean message -> commit succeeds ==="
REPO="$TMPBASE/repo-clean"
make_repo "$REPO"
run_commit_with_msg "$REPO" "totally fine commit message"
if [ "$CM_RC" = "0" ]; then
    pass "clean -> exit 0"
else
    fail "clean -> expected rc=0, got rc=$CM_RC. out=[$CM_OUT]"
fi

echo ""
echo "=== Normal: hard violation in message -> exit 1 with 'Commit blocked' ==="
REPO="$TMPBASE/repo-hard"
make_repo "$REPO"
run_commit_with_msg "$REPO" "fix: leak forbiddenword42 here"
if [ "$CM_RC" = "1" ]; then
    pass "hard -> exit 1"
else
    fail "hard -> expected rc=1, got rc=$CM_RC. out=[$CM_OUT]"
fi
if echo "$CM_OUT" | grep -qF "Commit blocked"; then
    pass "hard -> 'Commit blocked' banner present (proves rc captured)"
else
    fail "hard -> 'Commit blocked' missing. out=[$CM_OUT]"
fi

echo ""
echo "=== Normal: warn-only message, no TTY -> auto-block ==="
REPO="$TMPBASE/repo-warn"
make_repo "$REPO"
run_commit_with_msg "$REPO" "wip: suspiciousxxxpattern in message"
if [ "$CM_RC" = "1" ]; then
    pass "warn no-TTY -> exit 1 (auto-block)"
else
    fail "warn no-TTY -> expected rc=1, got rc=$CM_RC. out=[$CM_OUT]"
fi
if echo "$CM_OUT" | grep -Eq "no TTY|auto-block|auto blocked|automatically blocked"; then
    pass "warn no-TTY -> auto-block message present"
else
    fail "warn no-TTY -> expected 'no TTY' or 'auto-block' in output. out=[$CM_OUT]"
fi

echo ""
echo "=== Regression (set -e): hard message keeps banner after rc capture ==="
REPO="$TMPBASE/repo-regress"
make_repo "$REPO"
run_commit_with_msg "$REPO" "leak: forbiddenword99"
if [ "$CM_RC" = "1" ] && echo "$CM_OUT" | grep -qF "Commit blocked"; then
    pass "set -e safety: rc=1 + banner present"
else
    fail "set -e safety: rc=$CM_RC banner=$(echo "$CM_OUT" | grep -c "Commit blocked" || true). out=[$CM_OUT]"
fi

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi

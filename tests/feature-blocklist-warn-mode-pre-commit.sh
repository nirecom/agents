#!/bin/bash
# Test suite for hooks/pre-commit warn-mode behavior.
#
# Tests target POST-implementation behavior:
#   - rc captured via `|| rc=$?` so set -e doesn't abort the post-loop banner
#   - case branches on rc: 0 ok, 1 hard block, 2 warn (prompt y/N or auto-block)
#   - No TTY -> warn auto-blocks with message containing "no TTY" or "auto-blocked"
#   - Hard violation banner "Commit blocked" still emitted after the loop
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
PRECOMMIT_SRC="$DOTFILES_DIR/hooks/pre-commit"
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

# Build a fake "agents" tree (so $_cfg_dir/.. resolves to the agents root)
FAKE_AGENTS="$TMPBASE/agents"
mkdir -p "$FAKE_AGENTS/bin" "$FAKE_AGENTS/hooks"
cp "$SCANNER_SRC"   "$FAKE_AGENTS/bin/scan-outbound.sh"
cp "$PRECOMMIT_SRC" "$FAKE_AGENTS/hooks/pre-commit"
chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh" "$FAKE_AGENTS/hooks/pre-commit"
: > "$FAKE_AGENTS/.private-info-allowlist"
cat > "$FAKE_AGENTS/.private-info-blocklist" <<'EOF'
forbiddenword[0-9]+
warn:suspicious[a-z]+pattern
EOF

# Mask `gh` so private-repo skip cannot trigger.
# Instead of pruning PATH, we put a directory containing a `gh` stub that
# always returns non-zero (and reports nothing) at the front of PATH.
STUB_BIN="$TMPBASE/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB_BIN/gh"
EXEC_PATH="$STUB_BIN:$PATH"

# Per-test repo setup
make_repo() {
    local repo="$1"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config core.hooksPath "$FAKE_AGENTS/hooks"
    # No remote -> private-repo check returns empty, scanning proceeds
    # Initial commit so HEAD exists
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    PATH="$EXEC_PATH" git -C "$repo" -c core.hooksPath= commit -q -m "init"
}

# Run pre-commit for staged changes. Captures rc, stdout+stderr (combined).
# Sets globals: PC_RC, PC_OUT
run_commit() {
    local repo="$1" msg="$2"
    local out
    set +e
    out="$(PATH="$EXEC_PATH" run_with_timeout git -C "$repo" commit -m "$msg" </dev/null 2>&1)"
    PC_RC=$?
    set -e
    PC_OUT="$out"
}

echo "=== Normal: clean staged file -> commit succeeds ==="
REPO="$TMPBASE/repo-clean"
make_repo "$REPO"
echo "totally fine content" > "$REPO/file.txt"
git -C "$REPO" add file.txt
run_commit "$REPO" "clean commit"
if [ "$PC_RC" = "0" ]; then
    pass "clean -> exit 0"
else
    fail "clean -> expected rc=0, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "=== Normal: hard violation -> exit 1 with 'Commit blocked' ==="
REPO="$TMPBASE/repo-hard"
make_repo "$REPO"
echo "this has forbiddenword42 in it" > "$REPO/secret.txt"
git -C "$REPO" add secret.txt
run_commit "$REPO" "hard commit"
if [ "$PC_RC" = "1" ]; then
    pass "hard -> exit 1"
else
    fail "hard -> expected rc=1, got rc=$PC_RC. out=[$PC_OUT]"
fi
if echo "$PC_OUT" | grep -qF "Commit blocked"; then
    pass "hard -> 'Commit blocked' banner present (proves rc captured + post-loop reached)"
else
    fail "hard -> 'Commit blocked' missing. out=[$PC_OUT]"
fi

echo ""
echo "=== Normal: warn-only, no TTY -> auto-block ==="
REPO="$TMPBASE/repo-warn"
make_repo "$REPO"
echo "this has suspiciousxxxpattern in it" > "$REPO/maybe.txt"
git -C "$REPO" add maybe.txt
run_commit "$REPO" "warn commit"
if [ "$PC_RC" = "1" ]; then
    pass "warn no-TTY -> exit 1 (auto-block)"
else
    fail "warn no-TTY -> expected rc=1, got rc=$PC_RC. out=[$PC_OUT]"
fi
if echo "$PC_OUT" | grep -Eq "no TTY|auto-block|auto blocked|automatically blocked"; then
    pass "warn no-TTY -> auto-block message present"
else
    fail "warn no-TTY -> expected 'no TTY' or 'auto-block' in output. out=[$PC_OUT]"
fi

echo ""
echo "=== Normal: warn + hard mixed, no TTY -> hard 'Commit blocked' wins ==="
REPO="$TMPBASE/repo-mixed"
make_repo "$REPO"
echo "forbiddenword7 then suspiciousyyypattern" > "$REPO/mixed.txt"
git -C "$REPO" add mixed.txt
run_commit "$REPO" "mixed commit"
if [ "$PC_RC" = "1" ]; then
    pass "mixed -> exit 1"
else
    fail "mixed -> expected rc=1, got rc=$PC_RC. out=[$PC_OUT]"
fi
if echo "$PC_OUT" | grep -qF "Commit blocked"; then
    pass "mixed -> 'Commit blocked' banner present"
else
    fail "mixed -> 'Commit blocked' missing. out=[$PC_OUT]"
fi

echo ""
echo "=== Idempotency: hard violation twice -> same rc + same banner ==="
REPO="$TMPBASE/repo-idem"
make_repo "$REPO"
echo "forbiddenword12" > "$REPO/idem.txt"
git -C "$REPO" add idem.txt
run_commit "$REPO" "first try"
RC1=$PC_RC; OUT1_HAS_BANNER=$(echo "$PC_OUT" | grep -c "Commit blocked" || true)
# Stage again (commit failed so the file is still staged)
run_commit "$REPO" "second try"
RC2=$PC_RC; OUT2_HAS_BANNER=$(echo "$PC_OUT" | grep -c "Commit blocked" || true)
if [ "$RC1" = "$RC2" ] && [ "$OUT1_HAS_BANNER" = "$OUT2_HAS_BANNER" ] && [ "$RC1" = "1" ]; then
    pass "idempotent: both runs rc=$RC1 with banner"
else
    fail "idempotent: rc1=$RC1 rc2=$RC2 banner1=$OUT1_HAS_BANNER banner2=$OUT2_HAS_BANNER"
fi

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi

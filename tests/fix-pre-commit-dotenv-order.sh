#!/bin/bash
# Tests: agents/.env, bin/scan-outbound.sh, hooks/pre-commit
# Tags: pre-commit-dotenv-order
# Test suite for hooks/pre-commit — dotenv-vs-private-repo order fix.
#
# Currently the dotenv-add check runs BEFORE the private-repo check, so even
# private repos block adding `.env`. The fix swaps them so private-repo check
# runs first and exits 0 before the dotenv check runs.
#
# Expected post-fix behavior:
#   - private repo + new .env -> rc=0 (skipped)
#   - public repo + new .env -> rc=1 (blocked)
#   - no remote + new .env -> rc=1 (blocked: unknown visibility, treat as public)
#   - non-github host + new .env -> rc=0 (skipped: scan only runs for github)
#   - modify existing .env on public -> rc=0 (only NEW .env files trigger)
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

# Build a fake "agents" tree.
FAKE_AGENTS="$TMPBASE/agents"
mkdir -p "$FAKE_AGENTS/bin" "$FAKE_AGENTS/hooks"
if [ -f "$SCANNER_SRC" ]; then
    cp "$SCANNER_SRC" "$FAKE_AGENTS/bin/scan-outbound.sh"
    chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh"
fi
cp "$PRECOMMIT_SRC" "$FAKE_AGENTS/hooks/pre-commit"
chmod +x "$FAKE_AGENTS/hooks/pre-commit"
: > "$FAKE_AGENTS/.private-info-allowlist"

# Default gh stub (no remote info: exit 1).
STUB_BIN="$TMPBASE/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB_BIN/gh"
EXEC_PATH="$STUB_BIN:$PATH"

# Per-test gh stub.
make_gh_stub() {
    local stub_dir="$1" value="$2"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ]; then echo "$value"; fi
EOF
    chmod +x "$stub_dir/gh"
}

# Per-test repo setup. URL must be https:// or git@host: format.
make_repo() {
    local repo="$1" remote_url="$2"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config core.hooksPath "$FAKE_AGENTS/hooks"
    if [ -n "$remote_url" ]; then
        git -C "$repo" remote add origin "$remote_url"
    fi
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    PATH="$EXEC_PATH" AGENTS_CONFIG_DIR="$FAKE_AGENTS" \
        env -u AGENT_AUTO_BRANCH ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath= commit -q -m "init"
}

# Sets PC_RC, PC_OUT. `exec_path` lets each test inject its own gh stub.
# AGENTS_CONFIG_DIR points to FAKE_AGENTS so pre-commit's _load_env_file does
# not pick up the real repo .env (which sets ENFORCE_WORKTREE=on and blocks).
# ENFORCE_WORKTREE and AGENT_AUTO_BRANCH are explicitly unset for the same reason.
run_commit() {
    local repo="$1" msg="$2" exec_path="${3:-$EXEC_PATH}"
    local out
    set +e
    out="$(PATH="$exec_path" AGENTS_CONFIG_DIR="$FAKE_AGENTS" \
        run_with_timeout env -u AGENT_AUTO_BRANCH ENFORCE_WORKTREE=off \
        git -C "$repo" commit -m "$msg" </dev/null 2>&1)"
    PC_RC=$?
    set -e
    PC_OUT="$out"
}

# Per-test stub helper: builds a stubdir with custom gh, returns combined PATH.
test_path_with_gh() {
    local stub_dir="$1" value="$2"
    make_gh_stub "$stub_dir" "$value"
    echo "$stub_dir:$PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Test 1: private repo + new .env -> commit succeeds ==="
REPO="$TMPBASE/repo1"
make_repo "$REPO" "https://github.com/foo/private"
STUBDIR="$TMPBASE/stub1"
PATH1="$(test_path_with_gh "$STUBDIR" "true")"
echo "SECRET=x" > "$REPO/.env"
git -C "$REPO" add .env
run_commit "$REPO" "add env" "$PATH1"
if [ "$PC_RC" = "0" ]; then
    pass "private + new .env -> rc=0"
else
    fail "private + new .env -> expected rc=0, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "=== Test 2: public repo + new .env -> blocked ==="
REPO="$TMPBASE/repo2"
make_repo "$REPO" "https://github.com/foo/public"
STUBDIR="$TMPBASE/stub2"
PATH2="$(test_path_with_gh "$STUBDIR" "false")"
echo "SECRET=x" > "$REPO/.env"
git -C "$REPO" add .env
run_commit "$REPO" "add env" "$PATH2"
if [ "$PC_RC" = "1" ]; then
    pass "public + new .env -> rc=1"
else
    fail "public + new .env -> expected rc=1, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "=== Test 3: no remote + new .env -> blocked ==="
REPO="$TMPBASE/repo3"
make_repo "$REPO" ""
echo "SECRET=x" > "$REPO/.env"
git -C "$REPO" add .env
run_commit "$REPO" "add env"
if [ "$PC_RC" = "1" ]; then
    pass "no remote + new .env -> rc=1"
else
    fail "no remote + new .env -> expected rc=1, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "=== Test 4: non-github host + new .env -> skipped ==="
REPO="$TMPBASE/repo4"
make_repo "$REPO" "https://gitlab.com/foo/bar"
echo "SECRET=x" > "$REPO/.env"
git -C "$REPO" add .env
run_commit "$REPO" "add env"
if [ "$PC_RC" = "0" ]; then
    pass "non-github + new .env -> rc=0"
else
    fail "non-github + new .env -> expected rc=0, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "=== Test 5: private repo (ssh remote) + agents/.env -> skipped ==="
REPO="$TMPBASE/repo5"
make_repo "$REPO" "git@github.com:foo/private.git"
STUBDIR="$TMPBASE/stub5"
PATH5="$(test_path_with_gh "$STUBDIR" "true")"
mkdir -p "$REPO/agents"
echo "SECRET=x" > "$REPO/agents/.env"
git -C "$REPO" add agents/.env
run_commit "$REPO" "add nested env" "$PATH5"
if [ "$PC_RC" = "0" ]; then
    pass "private + agents/.env -> rc=0"
else
    fail "private + agents/.env -> expected rc=0, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "=== Test 6: public repo + clean file -> success ==="
REPO="$TMPBASE/repo6"
make_repo "$REPO" "https://github.com/foo/public"
STUBDIR="$TMPBASE/stub6"
PATH6="$(test_path_with_gh "$STUBDIR" "false")"
echo "totally fine content" >> "$REPO/README.md"
git -C "$REPO" add README.md
run_commit "$REPO" "doc edit" "$PATH6"
if [ "$PC_RC" = "0" ]; then
    pass "public + clean file -> rc=0"
else
    fail "public + clean file -> expected rc=0, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "=== Test 7: public repo + modify existing .env -> success ==="
REPO="$TMPBASE/repo7"
make_repo "$REPO" "https://github.com/foo/public"
STUBDIR="$TMPBASE/stub7"
PATH7="$(test_path_with_gh "$STUBDIR" "false")"
# Commit the .env first (bypassing hooks) so it exists in HEAD.
echo "SECRET=v1" > "$REPO/.env"
git -C "$REPO" add .env
PATH="$EXEC_PATH" AGENTS_CONFIG_DIR="$FAKE_AGENTS" \
    env -u AGENT_AUTO_BRANCH ENFORCE_WORKTREE=off \
    git -C "$REPO" -c core.hooksPath= commit -q -m "seed env"
# Now modify it.
echo "SECRET=v2" > "$REPO/.env"
git -C "$REPO" add .env
run_commit "$REPO" "modify env" "$PATH7"
if [ "$PC_RC" = "0" ]; then
    pass "public + modify existing .env -> rc=0"
else
    fail "public + modify existing .env -> expected rc=0, got rc=$PC_RC. out=[$PC_OUT]"
fi

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi

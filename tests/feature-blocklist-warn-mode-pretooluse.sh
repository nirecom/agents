#!/bin/bash
# Test suite for hooks/scan-outbound.js (PreToolUse hook) warn-mode behavior.
#
# Tests target POST-implementation behavior:
#   - JS hook uses spawnSync, fail-closed on result.error/null status
#   - rc=2 (warn) -> block + reason "Ask the user"
#   - rc=1 (hard) -> block + reason "Private information"
#   - Approve passthrough for non Edit/Write/Bash tools
#   - Scanner timeout -> block (fail-closed)
#   - Scanner spawn error -> block (fail-closed)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
HOOK_SRC="$DOTFILES_DIR/hooks/scan-outbound.js"
ISPRIV_SRC="$DOTFILES_DIR/hooks/lib/is-private-repo.js"
PARSEGIT_SRC="$DOTFILES_DIR/hooks/lib/parse-git-args.js"
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

# Build a fake "agents" tree mirroring the layout the hook expects:
#   agents/hooks/scan-outbound.js
#   agents/hooks/lib/is-private-repo.js
#   agents/hooks/lib/parse-git-args.js
#   agents/bin/scan-outbound.sh
#   agents/.private-info-allowlist
#   agents/.private-info-blocklist
FAKE_AGENTS="$TMPBASE/agents"
mkdir -p "$FAKE_AGENTS/bin" "$FAKE_AGENTS/hooks/lib"
cp "$SCANNER_SRC"   "$FAKE_AGENTS/bin/scan-outbound.sh"
cp "$HOOK_SRC"      "$FAKE_AGENTS/hooks/scan-outbound.js"
cp "$ISPRIV_SRC"    "$FAKE_AGENTS/hooks/lib/is-private-repo.js"
[ -f "$PARSEGIT_SRC" ] && cp "$PARSEGIT_SRC" "$FAKE_AGENTS/hooks/lib/parse-git-args.js"
chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh"
: > "$FAKE_AGENTS/.private-info-allowlist"
cat > "$FAKE_AGENTS/.private-info-blocklist" <<'EOF'
forbiddenword[0-9]+
warn:suspicious[a-z]+pattern
EOF

HOOK="$FAKE_AGENTS/hooks/scan-outbound.js"

# Mask gh so private-repo skip cannot trigger
STUB_BIN="$TMPBASE/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB_BIN/gh"
EXEC_PATH="$STUB_BIN:$PATH"

# Use a path outside any git repo
NOREPO_PATH="$TMPBASE/notrepo/foo.txt"
mkdir -p "$(dirname "$NOREPO_PATH")"

# Run hook with a JSON payload on stdin. Sets HK_OUT, HK_RC.
run_hook() {
    local payload="$1"
    set +e
    HK_OUT="$(printf '%s' "$payload" | PATH="$EXEC_PATH" run_with_timeout node "$HOOK" 2>/dev/null)"
    HK_RC=$?
    set -e
}

expect_approve() {
    local desc="$1"
    if echo "$HK_OUT" | grep -q '"decision":"approve"'; then
        pass "$desc"
    else
        fail "$desc — expected approve, got: [$HK_OUT]"
    fi
}

expect_block_with() {
    local desc="$1" needle="$2"
    if echo "$HK_OUT" | grep -q '"decision":"block"' && echo "$HK_OUT" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc — expected block + '$needle', got: [$HK_OUT]"
    fi
}

echo "=== Normal: clean Edit content -> approve ==="
run_hook "$(cat <<JSON
{"tool_name":"Edit","tool_input":{"file_path":"$NOREPO_PATH","new_string":"totally fine content"}}
JSON
)"
expect_approve "clean Edit -> approve"

echo ""
echo "=== Normal: Edit with hard match -> block + 'Private information' ==="
run_hook "$(cat <<JSON
{"tool_name":"Edit","tool_input":{"file_path":"$NOREPO_PATH","new_string":"oops forbiddenword42 leaked"}}
JSON
)"
expect_block_with "Edit hard -> block + 'Private information'" "Private information"

echo ""
echo "=== Normal: Edit with warn match -> block + 'Ask the user' ==="
run_hook "$(cat <<JSON
{"tool_name":"Edit","tool_input":{"file_path":"$NOREPO_PATH","new_string":"contains suspiciousxxxpattern here"}}
JSON
)"
expect_block_with "Edit warn -> block + 'Ask the user'" "Ask the user"

echo ""
echo "=== Error: scanner timeout -> block (fail-closed) ==="
# Replace scanner with a script that sleeps longer than the 10s timeout
cat > "$FAKE_AGENTS/bin/scan-outbound.sh" <<'EOF'
#!/bin/bash
sleep 30
EOF
chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh"
run_hook "$(cat <<JSON
{"tool_name":"Edit","tool_input":{"file_path":"$NOREPO_PATH","new_string":"any content"}}
JSON
)"
if echo "$HK_OUT" | grep -q '"decision":"block"'; then
    pass "scanner timeout -> block (fail-closed)"
else
    fail "scanner timeout -> expected block, got: [$HK_OUT]"
fi
# Restore real scanner
cp "$SCANNER_SRC" "$FAKE_AGENTS/bin/scan-outbound.sh"
chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh"

echo ""
echo "=== Error: scanner spawn error (scanner missing) -> block ==="
mv "$FAKE_AGENTS/bin/scan-outbound.sh" "$FAKE_AGENTS/bin/scan-outbound.sh.bak"
run_hook "$(cat <<JSON
{"tool_name":"Edit","tool_input":{"file_path":"$NOREPO_PATH","new_string":"any content"}}
JSON
)"
if echo "$HK_OUT" | grep -q '"decision":"block"'; then
    pass "scanner missing -> block (fail-closed)"
else
    fail "scanner missing -> expected block, got: [$HK_OUT]"
fi
mv "$FAKE_AGENTS/bin/scan-outbound.sh.bak" "$FAKE_AGENTS/bin/scan-outbound.sh"
chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh"

echo ""
echo "=== Normal: Bash git commit with warn pattern in -m -> block + 'Ask the user' ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"git commit -m \"msg with suspiciousxxxpattern in it\""}}
JSON
)"
expect_block_with "Bash commit warn -> block + 'Ask the user'" "Ask the user"

echo ""
echo "=== Security: tool_name 'Read' -> approve (passthrough) ==="
run_hook "$(cat <<JSON
{"tool_name":"Read","tool_input":{"file_path":"$NOREPO_PATH"}}
JSON
)"
expect_approve "Read tool -> approve"

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi

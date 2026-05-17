#!/usr/bin/env bash
# Tests for hooks/show-user-verified-context.js
# PreToolUse Bash hook: detects <<WORKFLOW_USER_VERIFIED>> in tool_input.command,
# emits "User verification context:" systemMessage with staged files and open PR URL
# BEFORE the permission dialog renders (sentinel is permissions.ask-listed).
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-user-verified-context.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$@"
  else
    perl -e 'alarm 60; exec @ARGV' -- "$@"
  fi
}

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
WORK_DIR="${NODE_TMPDIR}/show-user-verified-test-$$"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

extract_msg() {
  run_with_timeout node -e "
    let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.exit(1);}
    process.stdout.write(d.systemMessage||'');
  " 2>/dev/null
}

# Sentinel JSON snippets
SENTINEL_CMD='echo \"<<WORKFLOW_USER_VERIFIED>>\"'

# Set up a temp git repo for staged-file tests
GIT_REPO="$WORK_DIR/repo"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.email "test@example.com"
git -C "$GIT_REPO" config user.name "Test"
echo "hello" > "$GIT_REPO/foo.txt"
git -C "$GIT_REPO" add foo.txt

# ── U1: Positive — sentinel in command → systemMessage ───────────────────
echo "=== U1: sentinel in command → User verification context: ==="
U1_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
U1_RESULT=$(run_hook "$U1_JSON")
U1_MSG=$(echo "$U1_RESULT" | extract_msg)
if echo "$U1_MSG" | grep -q "User verification context:" && echo "$U1_MSG" | grep -q "Staged files:"; then
  pass "U1 sentinel in command → systemMessage with User verification context:"
else
  fail "U1 — expected 'User verification context:' and 'Staged files:', got: $U1_MSG"
fi

# ── U2: Wrong tool (Write) → noop ─────────────────────────────────────────
echo "=== U2: wrong tool (Write) → noop ==="
U2_JSON="{\"tool_name\":\"Write\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\"}}"
U2_RESULT=$(run_hook "$U2_JSON")
if [ -z "$U2_RESULT" ]; then
  pass "U2 wrong tool → noop"
else
  fail "U2 wrong tool — expected empty stdout, got: $U2_RESULT"
fi

# ── U3: Sentinel in stdout only, NOT in command → noop ─────────────────────
echo "=== U3: sentinel in stdout only (not command) → noop ==="
U3_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat some-file.txt\",\"cwd\":\"$GIT_REPO\"}}"
U3_RESULT=$(run_hook "$U3_JSON")
if [ -z "$U3_RESULT" ]; then
  pass "U3 sentinel in stdout only → noop (command-based detection)"
else
  fail "U3 — expected empty stdout, got: $U3_RESULT"
fi

# ── U4: No staged files → (none) ──────────────────────────────────────────
echo "=== U4: no staged files → (none) ==="
EMPTY_REPO="$WORK_DIR/empty-repo"
mkdir -p "$EMPTY_REPO"
git -C "$EMPTY_REPO" init -q
git -C "$EMPTY_REPO" config user.email "test@example.com"
git -C "$EMPTY_REPO" config user.name "Test"
U4_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$EMPTY_REPO\"}}"
U4_RESULT=$(run_hook "$U4_JSON")
U4_MSG=$(echo "$U4_RESULT" | extract_msg)
if echo "$U4_MSG" | grep -q "User verification context:" && echo "$U4_MSG" | grep -q "(none)"; then
  pass "U4 no staged files → (none)"
else
  fail "U4 — expected '(none)', got: $U4_MSG"
fi

# ── U5: Open PR exists → Open PR: <url> ────────────────────────────────────
echo "=== U5: open PR → Open PR: url ==="
IS_WINDOWS_U5=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS_U5=1 ;;
esac
[ "${OS:-}" = "Windows_NT" ] && IS_WINDOWS_U5=1
if [ "$IS_WINDOWS_U5" = "1" ]; then
  # Node.js spawnSync on Windows cannot find bash-script shims via a POSIX-format PATH
  # inherited from Git-Bash. The getPrUrl behavior is covered by native-shell integration.
  pass "U5 open PR shim — skipped on Windows (POSIX PATH not searchable by Node.js spawnSync)"
else
  GH_BIN_DIR="$WORK_DIR/gh-shim"
  mkdir -p "$GH_BIN_DIR"
  cat > "$GH_BIN_DIR/gh" << 'SHIM'
#!/usr/bin/env bash
echo "https://github.com/nirecom/agents/pull/314"
exit 0
SHIM
  chmod +x "$GH_BIN_DIR/gh"
  U5_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
  U5_RESULT=$(PATH="$GH_BIN_DIR:$PATH" run_hook "$U5_JSON")
  U5_MSG=$(echo "$U5_RESULT" | extract_msg)
  if echo "$U5_MSG" | grep -q "Open PR: https://github.com/nirecom/agents/pull/314"; then
    pass "U5 open PR → Open PR: url in systemMessage"
  else
    fail "U5 — expected 'Open PR: https://...', got: $U5_MSG"
  fi
fi

# ── U6: gh exits 1 (no PR) → no Open PR: line ──────────────────────────────
echo "=== U6: gh exits 1 → no Open PR: line ==="
GH_FAIL_DIR="$WORK_DIR/gh-fail"
mkdir -p "$GH_FAIL_DIR"
cat > "$GH_FAIL_DIR/gh" << 'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$GH_FAIL_DIR/gh"
U6_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
U6_RESULT=$(PATH="$GH_FAIL_DIR:$PATH" run_hook "$U6_JSON")
U6_MSG=$(echo "$U6_RESULT" | extract_msg)
if echo "$U6_MSG" | grep -q "Staged files:" && ! echo "$U6_MSG" | grep -q "Open PR:"; then
  pass "U6 gh exits 1 → staged files shown, no Open PR: line"
else
  fail "U6 — unexpected output: $U6_MSG"
fi

# ── U7: gh not on PATH → graceful, no crash ────────────────────────────────
echo "=== U7: gh not on PATH → graceful degradation ==="
U7_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
# Simulate "gh not on PATH" by shadowing gh with an always-fail shim,
# without stripping node or other tools from PATH.
GH_ABSENT_DIR="$WORK_DIR/gh-absent"
mkdir -p "$GH_ABSENT_DIR"
cat > "$GH_ABSENT_DIR/gh" << 'SHIM'
#!/usr/bin/env bash
exit 127
SHIM
chmod +x "$GH_ABSENT_DIR/gh"
U7_RESULT=$(PATH="$GH_ABSENT_DIR:$PATH" run_hook "$U7_JSON")
U7_MSG=$(echo "$U7_RESULT" | extract_msg)
if echo "$U7_MSG" | grep -q "Staged files:" && ! echo "$U7_MSG" | grep -q "Open PR:"; then
  pass "U7 gh not on PATH → graceful, staged files shown, no Open PR:"
else
  fail "U7 — unexpected output: $U7_MSG"
fi

# ── U8: Non-git cwd → graceful degradation ─────────────────────────────────
echo "=== U8: non-git cwd → graceful ==="
NON_GIT="$WORK_DIR/non-git"
mkdir -p "$NON_GIT"
U8_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$NON_GIT\"}}"
U8_RESULT=$(run_hook "$U8_JSON")
U8_MSG=$(echo "$U8_RESULT" | extract_msg)
if echo "$U8_MSG" | grep -q "User verification context:"; then
  pass "U8 non-git cwd → graceful (no crash, systemMessage emitted)"
else
  fail "U8 — expected User verification context:, got: $U8_MSG"
fi

# ── U9: Idempotency — two runs produce identical output ────────────────────
echo "=== U9: idempotency ==="
U9_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
U9_R1=$(run_hook "$U9_JSON")
U9_R2=$(run_hook "$U9_JSON")
if [ "$U9_R1" = "$U9_R2" ] && [ -n "$U9_R1" ]; then
  pass "U9 idempotency — two runs produce identical systemMessages"
else
  fail "U9 — run1: $U9_R1 | run2: $U9_R2"
fi

# ── U10: Partial sentinel (no << / >>) → noop ──────────────────────────────
echo "=== U10: partial sentinel → noop ==="
U10_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo WORKFLOW_USER_VERIFIED\",\"cwd\":\"$GIT_REPO\"}}"
U10_RESULT=$(run_hook "$U10_JSON")
if [ -z "$U10_RESULT" ]; then
  pass "U10 partial sentinel (no <</>>) → noop"
else
  fail "U10 — expected empty, got: $U10_RESULT"
fi

# ── U11: cwd resolution — CLAUDE_PROJECT_DIR fallback ──────────────────────
echo "=== U11: CLAUDE_PROJECT_DIR fallback when cwd absent ==="
OTHER_REPO="$WORK_DIR/other-repo"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config user.email "test@example.com"
git -C "$OTHER_REPO" config user.name "Test"
echo "bar" > "$OTHER_REPO/bar.txt"
git -C "$OTHER_REPO" add bar.txt
# No cwd field in the JSON input
U11_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\"}}"
U11_RESULT=$(CLAUDE_PROJECT_DIR="$OTHER_REPO" run_hook "$U11_JSON")
U11_MSG=$(echo "$U11_RESULT" | extract_msg)
if echo "$U11_MSG" | grep -q "bar.txt" && ! echo "$U11_MSG" | grep -q "foo.txt"; then
  pass "U11 CLAUDE_PROJECT_DIR fallback — correct repo used (bar.txt from other-repo)"
else
  fail "U11 — expected bar.txt from other-repo, got: $U11_MSG"
fi

# ── U12: PreToolUse payload (no tool_response) → systemMessage produced ─────
echo "=== U12: PreToolUse payload without tool_response → systemMessage ==="
U12_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
U12_RESULT=$(run_hook "$U12_JSON")
U12_MSG=$(echo "$U12_RESULT" | extract_msg)
if echo "$U12_MSG" | grep -q "User verification context:" && echo "$U12_MSG" | grep -q "foo.txt"; then
  pass "U12 PreToolUse payload (no tool_response) → systemMessage with staged file"
else
  fail "U12 — expected User verification context: with foo.txt, got: $U12_MSG"
fi

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

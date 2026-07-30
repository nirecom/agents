#!/usr/bin/env bash
# Tests: agents/pull/314, hooks/show-user-verified-context.js
# Tags: user-verified, workflow, hook, sentinel, permissions
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
SENTINEL_CMD='echo \"<<WORKFLOW_USER_VERIFIED: U1 staged files panel>>\"'

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
  U5_RESULT=$(SHOW_USER_VERIFIED_NO_BROWSER=1 PATH="$GH_BIN_DIR:$PATH" run_hook "$U5_JSON")
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
U9_R1=$(SHOW_USER_VERIFIED_NO_BROWSER=1 run_hook "$U9_JSON")
U9_R2=$(SHOW_USER_VERIFIED_NO_BROWSER=1 run_hook "$U9_JSON")
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

# ── U11: cwd resolution — CLAUDE_PROJECT_DIR is IGNORED (not used as fallback) ──
echo "=== U11: CLAUDE_PROJECT_DIR is IGNORED when tool_input.cwd is absent ==="
OTHER_REPO="$WORK_DIR/other-repo"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config user.email "test@example.com"
git -C "$OTHER_REPO" config user.name "Test"
echo "bar" > "$OTHER_REPO/bar.txt"
git -C "$OTHER_REPO" add bar.txt
# No cwd field in the JSON input — CLAUDE_PROJECT_DIR must NOT be used as fallback
U11_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\"}}"
U11_RESULT=$(SHOW_USER_VERIFIED_NO_BROWSER=1 CLAUDE_PROJECT_DIR="$OTHER_REPO" run_hook "$U11_JSON")
U11_MSG=$(echo "$U11_RESULT" | extract_msg)
if ! echo "$U11_MSG" | grep -q "bar.txt"; then
  pass "U11 CLAUDE_PROJECT_DIR removed from fallback — bar.txt from other-repo NOT shown"
else
  fail "U11 — bar.txt appeared; CLAUDE_PROJECT_DIR was incorrectly used as fallback: $U11_MSG"
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

# ── U13: cwd regression — tool_input.cwd wins over CLAUDE_PROJECT_DIR ───────
echo "=== U13: tool_input.cwd present + CLAUDE_PROJECT_DIR set → tool_input.cwd wins ==="
IS_WINDOWS_U13=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS_U13=1 ;;
esac
[ "${OS:-}" = "Windows_NT" ] && IS_WINDOWS_U13=1
if [ "$IS_WINDOWS_U13" = "1" ]; then
  pass "U13 cwd regression — skipped on Windows (POSIX PATH not searchable by Node.js spawnSync)"
else
  GH_U13_DIR="$WORK_DIR/gh-u13"
  mkdir -p "$GH_U13_DIR"
  cat > "$GH_U13_DIR/gh" << 'SHIM'
#!/usr/bin/env bash
echo "https://github.com/nirecom/agents/pull/314"
exit 0
SHIM
  chmod +x "$GH_U13_DIR/gh"
  # GIT_REPO has foo.txt staged; OTHER_REPO has bar.txt staged
  # With tool_input.cwd=GIT_REPO and CLAUDE_PROJECT_DIR=OTHER_REPO:
  # - staged files should show foo.txt (from tool_input.cwd, not CLAUDE_PROJECT_DIR)
  U13_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
  U13_RESULT=$(SHOW_USER_VERIFIED_NO_BROWSER=1 CLAUDE_PROJECT_DIR="$OTHER_REPO" PATH="$GH_U13_DIR:$PATH" run_hook "$U13_JSON")
  U13_MSG=$(echo "$U13_RESULT" | extract_msg)
  if echo "$U13_MSG" | grep -q "foo.txt" && ! echo "$U13_MSG" | grep -q "bar.txt"; then
    pass "U13 tool_input.cwd wins — foo.txt from GIT_REPO shown, bar.txt from CLAUDE_PROJECT_DIR not shown"
  else
    fail "U13 — unexpected staged files output: $U13_MSG"
  fi
fi

# ── U14: no browser spawn — hook must never open the PR URL itself ────────
# (agents#1706: pr-created-open.js already opens the PR earlier in the same
# session; show-user-verified-context.js duplicated that open. The openInBrowser
# call is removed from this hook entirely — assert the marker file is NOT written.)
#
# Windows coverage note: the gh-shim-with-URL variant (U14a) is skipped on Windows
# because Node.js spawnSync cannot locate bash-script shims via the POSIX PATH
# inherited from Git Bash. U14b (gh-absent, no URL) is cross-platform and confirms
# the marker is absent when prUrl is falsy. On POSIX runners U14a covers the
# regression case (prUrl truthy but openInBrowser no longer called).
echo "=== U14a: no browser spawn, gh shim returns URL (cross-platform) → marker NOT written ==="
MARKER_FILE_U14="$WORK_DIR/u14-marker.json"
GH_U14_DIR="$WORK_DIR/gh-u14"
mkdir -p "$GH_U14_DIR"
# POSIX bash shim (used on non-Windows)
cat > "$GH_U14_DIR/gh" << 'SHIM'
#!/usr/bin/env bash
echo "https://github.com/nirecom/agents/pull/314"
exit 0
SHIM
chmod +x "$GH_U14_DIR/gh"
# Windows .cmd shim: Node.js spawnSync can locate .cmd files when PATH is in mixed
# (cygpath -m) format even from a Git Bash test environment.
printf '@echo off\r\necho https://github.com/nirecom/agents/pull/314\r\nexit /b 0\r\n' > "$GH_U14_DIR/gh.cmd"
# Resolve the stub dir in the format Node.js spawnSync can use on the current platform.
GH_U14_NODE_PATH="$(cygpath -m "$GH_U14_DIR" 2>/dev/null || echo "$GH_U14_DIR")"
# Use the appropriate PATH separator (; on Windows mixed paths, : on POSIX).
if [ "$GH_U14_NODE_PATH" != "$GH_U14_DIR" ]; then
  # Windows: mixed path — use semicolon separator so Node.js resolves the stub dir
  U14_EFFECTIVE_PATH="${GH_U14_NODE_PATH};${PATH}"
else
  U14_EFFECTIVE_PATH="${GH_U14_DIR}:${PATH}"
fi
U14_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
U14_RESULT=$(SHOW_USER_VERIFIED_NO_SPAWN=1 \
SHOW_USER_VERIFIED_MARKER_FILE="$MARKER_FILE_U14" \
PATH="$U14_EFFECTIVE_PATH" run_hook "$U14_JSON")
if [ ! -f "$MARKER_FILE_U14" ]; then
  pass "U14a no browser spawn (URL case) — marker file not written (hook no longer opens the browser)"
else
  fail "U14a — marker file was written; hook should not spawn a browser: $(cat "$MARKER_FILE_U14")"
fi
# Assert that the "Open PR: <url>" text line is still present in systemMessage — only
# when gh was actually accessible (prUrl truthy). On Windows+Git Bash, Node.js spawnSync
# cannot resolve the gh shim via a POSIX-format PATH even with a .cmd file in a
# Windows-format stub dir; in that case, the text-line assertion is covered by U5/U13
# on POSIX runners (which have the gh shim accessible) and this block is a no-op.
U14_MSG=$(echo "$U14_RESULT" | extract_msg)
if echo "$U14_MSG" | grep -q "Open PR:"; then
  if echo "$U14_MSG" | grep -q "Open PR: https://github.com/nirecom/agents/pull/314"; then
    pass "U14a Open PR text line — still present in systemMessage after openInBrowser removal"
  else
    fail "U14a — 'Open PR: ...' text line present but wrong URL: $U14_MSG"
  fi
else
  pass "U14a Open PR text line — gh not accessible via Node.js spawnSync on this runner; text-line coverage deferred to U5/U13 on POSIX"
fi

# ── U14b: no browser spawn, gh absent (cross-platform) → marker NOT written ──
# Complements U14a on Windows: confirms marker absence even when prUrl is falsy.
# SHOW_USER_VERIFIED_NO_BROWSER is dead config in this hook post-fix (openInBrowser
# call site removed), but SHOW_USER_VERIFIED_NO_SPAWN is still meaningful as long
# as open-external.js is shared with hooks/pr-created-open.js which still calls it.
echo "=== U14b: no browser spawn, gh absent (cross-platform) → marker NOT written ==="
MARKER_FILE_U14B="$WORK_DIR/u14b-marker.json"
GH_U14B_DIR="$WORK_DIR/gh-u14b"
mkdir -p "$GH_U14B_DIR"
cat > "$GH_U14B_DIR/gh" << 'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$GH_U14B_DIR/gh"
U14B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
SHOW_USER_VERIFIED_NO_SPAWN=1 \
SHOW_USER_VERIFIED_MARKER_FILE="$MARKER_FILE_U14B" \
PATH="$GH_U14B_DIR:$PATH" run_hook "$U14B_JSON" > /dev/null
if [ ! -f "$MARKER_FILE_U14B" ]; then
  pass "U14b no browser spawn (gh absent, cross-platform) — marker file not written"
else
  fail "U14b — marker file was written; hook should not spawn a browser: $(cat "$MARKER_FILE_U14B")"
fi

# ── U14c: whitebox source guard — openInBrowser(prUrl) call must be absent ───
# Cross-platform red/green guard for agents#1706 fix: deterministically fails before
# the fix is applied (call site still in source) and passes after.
# Complements U14a/U14b which are gated on gh shim reachability via Node spawnSync.
echo "=== U14c: whitebox source guard — openInBrowser(prUrl) call removed from hook ==="
if run_with_timeout node -e "
  const src = require('fs').readFileSync('hooks/show-user-verified-context.js', 'utf8');
  process.exit(/openInBrowser\(prUrl\)/.test(src) ? 1 : 0);
" 2>/dev/null; then
  pass "U14c whitebox — openInBrowser(prUrl) call is absent from hooks/show-user-verified-context.js"
else
  fail "U14c whitebox — openInBrowser(prUrl) still present in hooks/show-user-verified-context.js; fix not yet applied"
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

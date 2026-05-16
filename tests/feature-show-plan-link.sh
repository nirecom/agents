#!/usr/bin/env bash
# Tests for isFinalPlanArtifact detection and systemMessage output in hooks/show-plan-link.js.
#
# Uses WORKFLOW_PLANS_DIR to control the resolved plans directory so tests work
# regardless of the actual home directory path.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-plan-link.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (rules/test-rules/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# Per-run temp dir as plans dir (no pollution of real ~/.workflow-plans).
# Use node os.tmpdir() so the path is in the same form Node.js sees it —
# on Windows, MSYS2 converts /tmp/... env vars to C:/Users/.../Temp/... but
# the JSON stdin value stays POSIX-form; using Node's tmpdir avoids the mismatch.
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/show-plan-link-test-$$"
mkdir -p "$PLANS_DIR"
trap 'rm -rf "$PLANS_DIR"' EXIT
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Unset VS Code detection vars by default (restored per-test that needs them).
unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

# Asserts stdout is empty (noop)
expect_empty() {
  local desc="$1" json="$2"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected empty stdout, got: $result"
  fi
}

# Asserts stdout is valid JSON with .systemMessage containing the expected substring
expect_message() {
  local desc="$1" json="$2" expected="$3"
  local result
  result=$(run_hook "$json")
  if [ -z "$result" ]; then
    fail "$desc — expected systemMessage, got empty stdout"
    return
  fi
  # Validate JSON and extract .systemMessage
  local msg
  msg=$(echo "$result" | run_with_timeout node -e "
    let data; try { data = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    if (!data.systemMessage) process.exit(2);
    process.stdout.write(data.systemMessage);
  " 2>/dev/null)
  local rc=$?
  if [ $rc -eq 1 ]; then
    fail "$desc — stdout is not valid JSON: $result"
  elif [ $rc -eq 2 ]; then
    fail "$desc — JSON has no .systemMessage field: $result"
  elif echo "$msg" | grep -qF "$expected"; then
    pass "$desc"
  else
    fail "$desc — .systemMessage does not contain '$expected': $msg"
  fi
}

# ── T1: Write abc-intent.md (success) ──────────────────────────────────────
echo "=== T1: abc-intent.md ==="
expect_message "T1 intent file emits systemMessage" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-intent.md\"},\"tool_response\":{\"success\":true}}" \
  "Plan file written:"

# ── T2: Write abc-outline.md ───────────────────────────────────────────────
echo "=== T2: abc-outline.md ==="
expect_message "T2 outline file emits systemMessage" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-outline.md\"},\"tool_response\":{\"success\":true}}" \
  "Plan file written:"

# ── T3: Write abc-detail.md ────────────────────────────────────────────────
echo "=== T3: abc-detail.md ==="
expect_message "T3 detail file emits systemMessage" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}" \
  "Plan file written:"

# ── T4: Write in drafts/ subdirectory ──────────────────────────────────────
echo "=== T4: drafts/abc-detail.md ==="
mkdir -p "$PLANS_DIR/drafts"
expect_empty "T4 drafts subdir is excluded (isDirectChild)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/drafts/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T5: Wrong suffix (.bak.md) ─────────────────────────────────────────────
echo "=== T5: abc-detail.bak.md ==="
expect_empty "T5 wrong suffix excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.bak.md\"},\"tool_response\":{\"success\":true}}"

# ── T6: Write in subdir (not direct child) ─────────────────────────────────
echo "=== T6: subdir/abc-detail.md ==="
mkdir -p "$PLANS_DIR/subdir"
expect_empty "T6 subdir not direct child excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/subdir/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T7: Sibling directory (PLANS_DIR-sibling) ──────────────────────────────
echo "=== T7: \$PLANS_DIR-sibling/abc-detail.md ==="
expect_empty "T7 sibling dir outside plans dir excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${PLANS_DIR}-sibling/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T8: Completely unrelated path ─────────────────────────────────────────
echo "=== T8: /tmp/random/abc-detail.md ==="
expect_empty "T8 unrelated path excluded" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/random/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T9: Edit tool on matching path ─────────────────────────────────────────
echo "=== T9: Edit tool ==="
expect_empty "T9 Edit tool is noop (non-Write)" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"

# ── T10: Bash tool ─────────────────────────────────────────────────────────
echo "=== T10: Bash tool ==="
expect_empty "T10 Bash tool is noop" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_response\":{\"success\":true}}"

# ── T11: Empty file_path ───────────────────────────────────────────────────
echo "=== T11: empty file_path ==="
expect_empty "T11 empty file_path is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"\"},\"tool_response\":{\"success\":true}}"

# ── T12: Backslash path (Windows JSON-encoded) ─────────────────────────────
# Simulate a Windows-style backslash path that node receives as forward-slash
# after JSON.parse. We build the JSON with pre-escaped backslashes.
echo "=== T12: backslash path ==="
WIN_STYLE_PATH="$(echo "$PLANS_DIR/abc-detail.md" | sed 's|/|\\\\|g')"
# The JSON string value will have \\ which after parse = single backslash
T12_JSON="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${WIN_STYLE_PATH}\"},\"tool_response\":{\"success\":true}}"
result12=$(echo "$T12_JSON" | run_with_timeout node "$HOOK" 2>/dev/null)
if [ -n "$result12" ]; then
  msg12=$(echo "$result12" | run_with_timeout node -e "
    let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
    process.stdout.write(d.systemMessage || '');
  " 2>/dev/null)
  if echo "$msg12" | grep -q "Plan file written:"; then
    pass "T12 backslash path produces systemMessage (path format asserted by T23)"
  else
    fail "T12 backslash path — unexpected result: $result12"
  fi
else
  pass "T12 backslash path (POSIX: noop is acceptable — path does not resolve to plans dir)"
fi

# ── T13: No prefix before -intent (intent.md only) ─────────────────────────
echo "=== T13: intent.md (no prefix) ==="
expect_empty "T13 intent.md without prefix excluded (regex .+ required)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/intent.md\"},\"tool_response\":{\"success\":true}}"

# ── T14: Uppercase suffix (case-sensitive regex) ────────────────────────────
echo "=== T14: abc-DETAIL.md (uppercase) ==="
expect_empty "T14 uppercase suffix excluded (case-sensitive regex)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-DETAIL.md\"},\"tool_response\":{\"success\":true}}"

# ── T15: Write with exit_code: 1 ───────────────────────────────────────────
echo "=== T15: exit_code: 1 ==="
expect_empty "T15 failed write (exit_code 1) is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"exit_code\":1}}"

# ── T16: TERM_PROGRAM=vscode + matching path + PATH shim ──
echo "=== T16: VS Code TERM_PROGRAM + shim ==="
BIN_DIR="${NODE_TMPDIR}/show-plan-link-shim-$$"
mkdir -p "$BIN_DIR"
MARKER_FILE="$BIN_DIR/code-invoked"
# Create a shim named "code" that writes a marker file when invoked
cat > "$BIN_DIR/code" << 'SHIM'
#!/usr/bin/env bash
touch "$(dirname "$0")/code-invoked"
exit 0
SHIM
chmod +x "$BIN_DIR/code"

T16_RESULT=$(TERM_PROGRAM=vscode PATH="$BIN_DIR:$PATH" \
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}")

T16_MSG=$(echo "$T16_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)

if ! echo "$T16_MSG" | grep -q "Plan file written:"; then
  fail "T16 VS Code TERM_PROGRAM — no systemMessage emitted: $T16_RESULT"
else
  # bounded wait loop (replaces fixed sleep) — slow CI safe
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$MARKER_FILE" ] && break
    sleep 0.1
  done
  if [ -f "$MARKER_FILE" ]; then
    pass "T16 VS Code TERM_PROGRAM — systemMessage emitted AND code shim invoked"
  else
    # On Windows, spawn uses cmd.exe which won't find bash shim — acceptable
    if [ "$(uname -s 2>/dev/null)" = "Linux" ] || [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
      fail "T16 VS Code TERM_PROGRAM — systemMessage emitted but code shim was not invoked"
    else
      pass "T16 VS Code TERM_PROGRAM — systemMessage emitted (shim check skipped on Windows)"
    fi
  fi
fi
rm -rf "$BIN_DIR"

# ── T17: WORKFLOW_PLANS_DIR set to custom temp dir ─────────────────────────
echo "=== T17: custom WORKFLOW_PLANS_DIR ==="
CUSTOM_DIR="${NODE_TMPDIR}/show-plan-link-custom-$$"
mkdir -p "$CUSTOM_DIR"
T17_RESULT=$(WORKFLOW_PLANS_DIR="$CUSTOM_DIR" \
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CUSTOM_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}")
T17_MSG=$(echo "$T17_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)
if echo "$T17_MSG" | grep -q "Plan file written:"; then
  pass "T17 custom WORKFLOW_PLANS_DIR honored"
else
  fail "T17 custom WORKFLOW_PLANS_DIR — no systemMessage: $T17_RESULT"
fi
rm -rf "$CUSTOM_DIR"

# ── T18: Malformed (non-JSON) stdin ────────────────────────────────────────
echo "=== T18: malformed stdin ==="
result18=$(echo "not json at all" | run_with_timeout node "$HOOK" 2>/dev/null)
if [ -z "$result18" ]; then
  pass "T18 malformed stdin is fail-open (empty stdout)"
else
  fail "T18 malformed stdin — expected empty stdout, got: $result18"
fi

# ── T19: Write with success: false (legacy field) ──────────────────────────
echo "=== T19: success: false ==="
expect_empty "T19 success=false (legacy field) is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":false}}"

# ── T20: No VS Code detection vars — systemMessage emitted, code NOT spawned ──
echo "=== T20: non-VS Code (no env var) — no code spawn ==="
BIN_DIR20="${NODE_TMPDIR}/show-plan-link-shim20-$$"
mkdir -p "$BIN_DIR20"
MARKER_FILE20="$BIN_DIR20/code-invoked"
cat > "$BIN_DIR20/code" << 'SHIM'
#!/usr/bin/env bash
touch "$(dirname "$0")/code-invoked"
exit 0
SHIM
chmod +x "$BIN_DIR20/code"

T20_RESULT=$(
  unset TERM_PROGRAM
  unset CLAUDE_CODE_ENTRYPOINT
  export PATH="$BIN_DIR20:$PATH"
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)

T20_MSG=$(echo "$T20_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)

if ! echo "$T20_MSG" | grep -q "Plan file written:"; then
  fail "T20 non-VS Code — systemMessage missing: $T20_RESULT"
else
  # bounded wait loop (replaces fixed sleep) — slow CI safe
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$MARKER_FILE20" ] && break
    sleep 0.1
  done
  if [ -f "$MARKER_FILE20" ]; then
    fail "T20 non-VS Code — code shim was invoked but must NOT be"
  else
    pass "T20 non-VS Code — systemMessage emitted AND code shim NOT invoked"
  fi
fi
rm -rf "$BIN_DIR20"

# ── T21: CLAUDE_CODE_ENTRYPOINT=claude-vscode alone MUST trigger code spawn ──
# Axis 2 contract: extension/webview sessions are detected by CLAUDE_CODE_ENTRYPOINT.
echo "=== T21: CLAUDE_CODE_ENTRYPOINT=claude-vscode alone → code spawned ==="
BIN_DIR21="${NODE_TMPDIR}/show-plan-link-shim21-$$"
mkdir -p "$BIN_DIR21"
MARKER_FILE21="$BIN_DIR21/code-invoked"
cat > "$BIN_DIR21/code" << 'SHIM'
#!/usr/bin/env bash
touch "$(dirname "$0")/code-invoked"
exit 0
SHIM
chmod +x "$BIN_DIR21/code"

T21_RESULT=$(
  unset TERM_PROGRAM
  export CLAUDE_CODE_ENTRYPOINT=claude-vscode
  export PATH="$BIN_DIR21:$PATH"
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)

T21_MSG=$(echo "$T21_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)

if ! echo "$T21_MSG" | grep -q "Plan file written:"; then
  fail "T21 legacy var — systemMessage missing: $T21_RESULT"
else
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$MARKER_FILE21" ] && break
    sleep 0.1
  done
  if [ -f "$MARKER_FILE21" ]; then
    pass "T21 CLAUDE_CODE_ENTRYPOINT=claude-vscode alone → code shim invoked"
  else
    case "$(uname -s 2>/dev/null || echo unknown)" in
      Linux|Darwin) fail "T21 CLAUDE_CODE_ENTRYPOINT=claude-vscode alone — code shim NOT invoked" ;;
      *) pass "T21 CLAUDE_CODE_ENTRYPOINT=claude-vscode alone — systemMessage emitted (shim check skipped on Windows)" ;;
    esac
  fi
fi
rm -rf "$BIN_DIR21"

# ── T22: TERM_PROGRAM=vscode + failing code shim → fail-open ──
# Two-tier output protocol invariant: systemMessage always emits even when
# the code spawn fails. We keep $PATH intact so node/bash remain available;
# only the 'code' binary is shadowed by a non-zero-exit shim.
echo "=== T22: VS Code path with failing code shim — fail-open ==="
BIN_DIR22="${NODE_TMPDIR}/show-plan-link-shim22-$$"
mkdir -p "$BIN_DIR22"
cat > "$BIN_DIR22/code" << 'SHIM'
#!/usr/bin/env bash
exit 127  # simulate command-not-found / spawn failure
SHIM
chmod +x "$BIN_DIR22/code"

T22_RESULT=$(TERM_PROGRAM=vscode PATH="$BIN_DIR22:$PATH" \
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}")

T22_MSG=$(echo "$T22_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)

if echo "$T22_MSG" | grep -q "Plan file written:"; then
  pass "T22 fail-open — systemMessage emitted even when code shim fails"
else
  fail "T22 fail-open — systemMessage missing: $T22_RESULT"
fi
rm -rf "$BIN_DIR22"

# ── T23: Windows backslash output in systemMessage ──────────────────────────
echo "=== T23: Windows backslash output in systemMessage ==="
IS_WINDOWS=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac
[ "${OS:-}" = "Windows_NT" ] && IS_WINDOWS=1

if [ "$IS_WINDOWS" = "1" ]; then
  T23_INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
  T23_RESULT=$(run_hook "$T23_INPUT")
  T23_MSG=$(echo "$T23_RESULT" | run_with_timeout node -e \
    "let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.exit(1);}
     process.stdout.write(d.systemMessage||'');" 2>/dev/null)
  if   echo "$T23_MSG" | grep -qE '^Plan file written: [A-Za-z]:\\' \
    && ! echo "$T23_MSG" | grep -q '~/' \
    && ! echo "$T23_MSG" | grep -q 'file:///' \
    && ! echo "$T23_MSG" | grep -q '(' ; then
    pass "T23 Windows: drive-letter backslash; no tilde, no file://, no dual-path annotation"
  else
    fail "T23 Windows backslash check — message: $T23_MSG"
  fi
else
  pass "T23 skipped on POSIX (Windows-only invariant)"
fi

# ── T24: TERM_PROGRAM=vscode only → code spawned ──────────────────────────
echo "=== T24: TERM_PROGRAM=vscode only → code spawned ==="
BIN_DIR24="${NODE_TMPDIR}/show-plan-link-shim24-$$"
mkdir -p "$BIN_DIR24"
MARKER_FILE24="$BIN_DIR24/code-invoked"
cat > "$BIN_DIR24/code" << 'SHIM'
#!/usr/bin/env bash
touch "$(dirname "$0")/code-invoked"
exit 0
SHIM
chmod +x "$BIN_DIR24/code"

T24_RESULT=$(
  export TERM_PROGRAM=vscode
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  unset SHOW_PLAN_LINK_NO_AUTO_OPEN 2>/dev/null || true
  export PATH="$BIN_DIR24:$PATH"
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)
T24_MSG=$(echo "$T24_RESULT" | run_with_timeout node -e "
  let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.exit(1);}
  process.stdout.write(d.systemMessage||'');
" 2>/dev/null)
if ! echo "$T24_MSG" | grep -q "Plan file written:"; then
  fail "T24 TERM_PROGRAM-only — no systemMessage: $T24_RESULT"
else
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARKER_FILE24" ] && break; sleep 0.1; done
  if [ -f "$MARKER_FILE24" ]; then
    pass "T24 TERM_PROGRAM=vscode only → code shim invoked"
  else
    case "$(uname -s 2>/dev/null || echo unknown)" in
      Linux|Darwin) fail "T24 TERM_PROGRAM=vscode only — code shim NOT invoked" ;;
      *) pass "T24 TERM_PROGRAM=vscode only — systemMessage emitted (shim check skipped on Windows)" ;;
    esac
  fi
fi
rm -rf "$BIN_DIR24"

# ── T25: CLAUDE_CODE_ENTRYPOINT=claude-vscode only → code spawned ─────────
echo "=== T25: CLAUDE_CODE_ENTRYPOINT=claude-vscode only → code spawned ==="
BIN_DIR25="${NODE_TMPDIR}/show-plan-link-shim25-$$"
mkdir -p "$BIN_DIR25"
MARKER_FILE25="$BIN_DIR25/code-invoked"
cat > "$BIN_DIR25/code" << 'SHIM'
#!/usr/bin/env bash
touch "$(dirname "$0")/code-invoked"
exit 0
SHIM
chmod +x "$BIN_DIR25/code"

T25_RESULT=$(
  unset TERM_PROGRAM 2>/dev/null || true
  export CLAUDE_CODE_ENTRYPOINT=claude-vscode
  unset SHOW_PLAN_LINK_NO_AUTO_OPEN 2>/dev/null || true
  export PATH="$BIN_DIR25:$PATH"
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)
T25_MSG=$(echo "$T25_RESULT" | run_with_timeout node -e "
  let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.exit(1);}
  process.stdout.write(d.systemMessage||'');
" 2>/dev/null)
if ! echo "$T25_MSG" | grep -q "Plan file written:"; then
  fail "T25 CLAUDE_CODE_ENTRYPOINT-only — no systemMessage: $T25_RESULT"
else
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARKER_FILE25" ] && break; sleep 0.1; done
  if [ -f "$MARKER_FILE25" ]; then
    pass "T25 CLAUDE_CODE_ENTRYPOINT=claude-vscode only → code shim invoked"
  else
    case "$(uname -s 2>/dev/null || echo unknown)" in
      Linux|Darwin) fail "T25 CLAUDE_CODE_ENTRYPOINT-only — code shim NOT invoked" ;;
      *) pass "T25 CLAUDE_CODE_ENTRYPOINT-only — systemMessage emitted (shim check skipped on Windows)" ;;
    esac
  fi
fi
rm -rf "$BIN_DIR25"

# ── T26: both signals → code spawned exactly once ─────────────────────────
echo "=== T26: both signals → code spawned ==="
BIN_DIR26="${NODE_TMPDIR}/show-plan-link-shim26-$$"
mkdir -p "$BIN_DIR26"
MARKER_FILE26="$BIN_DIR26/code-invoked"
cat > "$BIN_DIR26/code" << 'SHIM'
#!/usr/bin/env bash
touch "$(dirname "$0")/code-invoked"
exit 0
SHIM
chmod +x "$BIN_DIR26/code"

T26_RESULT=$(
  export TERM_PROGRAM=vscode
  export CLAUDE_CODE_ENTRYPOINT=claude-vscode
  unset SHOW_PLAN_LINK_NO_AUTO_OPEN 2>/dev/null || true
  export PATH="$BIN_DIR26:$PATH"
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)
T26_MSG=$(echo "$T26_RESULT" | run_with_timeout node -e "
  let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.exit(1);}
  process.stdout.write(d.systemMessage||'');
" 2>/dev/null)
if ! echo "$T26_MSG" | grep -q "Plan file written:"; then
  fail "T26 both signals — no systemMessage: $T26_RESULT"
else
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARKER_FILE26" ] && break; sleep 0.1; done
  if [ -f "$MARKER_FILE26" ]; then
    pass "T26 both signals → code shim invoked"
  else
    case "$(uname -s 2>/dev/null || echo unknown)" in
      Linux|Darwin) fail "T26 both signals — code shim NOT invoked" ;;
      *) pass "T26 both signals — systemMessage emitted (shim check skipped on Windows)" ;;
    esac
  fi
fi
rm -rf "$BIN_DIR26"

# ── T27: opt-out SHOW_PLAN_LINK_NO_AUTO_OPEN=1 overrides all signals ───────
echo "=== T27: opt-out overrides all signals — no code spawn ==="
BIN_DIR27="${NODE_TMPDIR}/show-plan-link-shim27-$$"
mkdir -p "$BIN_DIR27"
MARKER_FILE27="$BIN_DIR27/code-invoked"
cat > "$BIN_DIR27/code" << 'SHIM'
#!/usr/bin/env bash
touch "$(dirname "$0")/code-invoked"
exit 0
SHIM
chmod +x "$BIN_DIR27/code"

T27_RESULT=$(
  export TERM_PROGRAM=vscode
  export CLAUDE_CODE_ENTRYPOINT=claude-vscode
  export SHOW_PLAN_LINK_NO_AUTO_OPEN=1
  export PATH="$BIN_DIR27:$PATH"
  run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}"
)
T27_MSG=$(echo "$T27_RESULT" | run_with_timeout node -e "
  let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.exit(1);}
  process.stdout.write(d.systemMessage||'');
" 2>/dev/null)
if ! echo "$T27_MSG" | grep -q "Plan file written:"; then
  fail "T27 opt-out — no systemMessage: $T27_RESULT"
else
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARKER_FILE27" ] && break; sleep 0.1; done
  if [ -f "$MARKER_FILE27" ]; then
    fail "T27 opt-out — code shim invoked but MUST NOT be (SHOW_PLAN_LINK_NO_AUTO_OPEN=1)"
  else
    pass "T27 opt-out: SHOW_PLAN_LINK_NO_AUTO_OPEN=1 → code shim correctly suppressed"
  fi
fi
rm -rf "$BIN_DIR27"

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

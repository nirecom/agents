#!/usr/bin/env bash
# Tests for isPlanFile detection in hooks/show-diff.js.
#
# These tests assert the CORRECT POST-FIX behavior (isPlanFile, checking
# ~/.workflow-plans/ broadly via isUnderPath).  Tests use WORKFLOW_PLANS_DIR
# to control the resolved plans directory, so they work regardless of the
# actual home directory path.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-diff.js"
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

# Resolve Node-visible home dir (forward slashes, Windows-native on Windows)
NODE_HOME="$(run_with_timeout node -e "process.stdout.write(require('os').homedir().replace(/\\\\/g,'/'))")"

# Set WORKFLOW_PLANS_DIR to the real home's .workflow-plans so isUnderPath matches
export WORKFLOW_PLANS_DIR="$NODE_HOME/.workflow-plans"
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

# Asserts stdout is empty (noop — plan file detected or non-watched tool)
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

# Asserts stdout is non-empty (diff shown)
expect_nonempty() {
  local desc="$1" json="$2"
  local result
  result=$(run_hook "$json")
  if [ -n "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected non-empty stdout (diff), got empty"
  fi
}

# Build Windows backslash version for T6/T7
WIN_PLANS_DIR="$(echo "$WORKFLOW_PLANS_DIR" | sed 's|/|\\|g')"

# ── T1: POSIX path under ~/.workflow-plans/ (non-drafts) ───────────────────
# Final artifacts (intent/outline/detail) are NOT suppressed — diff preview shown.
echo "=== T1: \$WORKFLOW_PLANS_DIR/foo-intent.md ==="
expect_nonempty "T1 plan intent file shows diff (final artifact)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKFLOW_PLANS_DIR/foo-intent.md\",\"content\":\"x\"}}"

# ── T2: POSIX path under ~/.workflow-plans/drafts/ ─────────────────────────
echo "=== T2: \$WORKFLOW_PLANS_DIR/drafts/foo.md ==="
expect_empty "T2 plan drafts file is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKFLOW_PLANS_DIR/drafts/foo.md\",\"content\":\"x\"}}"

# ── T3: POSIX path — date-stamped detail plan ──────────────────────────────
# Final artifacts are NOT suppressed — diff preview shown.
echo "=== T3: \$WORKFLOW_PLANS_DIR/20260512-issues-migration-detail.md ==="
expect_nonempty "T3 date-stamped detail plan shows diff (final artifact)" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKFLOW_PLANS_DIR/20260512-issues-migration-detail.md\",\"content\":\"x\"}}"

# ── T4: workflow-plans-archive (similar prefix but NOT ~/.workflow-plans/) ─
# Not a plan file — diff should be shown. Tests trailing-slash boundary:
# isUnderPath($WORKFLOW_PLANS_DIR-archive/foo, $WORKFLOW_PLANS_DIR) === false
echo "=== T4: \$WORKFLOW_PLANS_DIR-archive/foo.md ==="
expect_nonempty "T4 workflow-plans-archive path shows diff" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKFLOW_PLANS_DIR-archive/foo.md\",\"content\":\"x\"}}"

# ── T5: /src/plans/foo.md (no plans prefix) ────────────────────────────────
# Not a plan file — diff should be shown.
echo "=== T5: /src/plans/foo.md ==="
expect_nonempty "T5 src/plans path shows diff" \
  '{"tool_name":"Write","tool_input":{"file_path":"/src/plans/foo.md","content":"x"}}'

# ── T6: Windows backslash path — JSON parse failure → noop fallback ────────
# Bash string interpolation cannot produce valid JSON for Windows backslash paths
# (unescaped \n in "nire" becomes a newline in JSON). The hook's JSON.parse fails
# and falls back to noopExit. Real Claude Code produces properly-encoded JSON
# ("C:\\\\Users\\\\..." → "C:\\Users\\...") which the hook handles correctly.
echo "=== T6: ${WIN_PLANS_DIR}\\foo.md (Windows path) ==="
expect_empty "T6 Windows plans path (malformed JSON) → noop fallback" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${WIN_PLANS_DIR}\\\\foo.md\",\"content\":\"x\"}}"

# ── T7: Windows backslash path under plans\drafts\ ─────────────────────────
echo "=== T7: ${WIN_PLANS_DIR}\\drafts\\bar.md (Windows path) ==="
expect_empty "T7 Windows plans/drafts path is noop" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${WIN_PLANS_DIR}\\\\drafts\\\\bar.md\",\"content\":\"x\"}}"

# ── T8: Empty file_path ────────────────────────────────────────────────────
echo "=== T8: empty file_path ==="
expect_empty "T8 empty file_path is noop" \
  '{"tool_name":"Write","tool_input":{"file_path":"","content":"x"}}'

# ── T9: Non-watched tool (Bash) ───────────────────────────────────────────
# Hook only watches Write/Edit/MultiEdit/editFiles — Bash is ignored.
echo "=== T9: Bash tool (non-watched) ==="
expect_empty "T9 Bash tool is noop" \
  '{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# ══════════════════════════════════════════════════════════════════════════
# CONFIRM_* diff-suppression tests (#445)
# show-diff.js must suppress inline diff when CONFIRM_*=off for the matching
# plan suffix. These tests will FAIL until hooks/show-diff.js is updated to
# call isConfirmOff() — that is expected and acceptable at the test-writing
# stage.
# ══════════════════════════════════════════════════════════════════════════

# Use a per-run temp plans dir so we can create real files (the hook reads
# the existing file to compute the overwrite-side diff).
NODE_TMPDIR_CONF="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
CONF_PLANS_DIR="${NODE_TMPDIR_CONF}/show-diff-conf-$$"
# Empty cfg dir: prevents loadDefaultEnv() from loading the real .env and
# leaking CONFIRM_* values into tests that rely on those being unset.
CONF_EMPTY_CFG_DIR="${NODE_TMPDIR_CONF}/show-diff-conf-cfg-empty-$$"
mkdir -p "$CONF_PLANS_DIR" "$CONF_EMPTY_CFG_DIR"
echo "prior content" > "$CONF_PLANS_DIR/foo-intent.md"
echo "prior content" > "$CONF_PLANS_DIR/foo-outline.md"
echo "prior content" > "$CONF_PLANS_DIR/foo-detail.md"

# Cleanup at exit (merge with potential existing trap)
cleanup_conf() { rm -rf "$CONF_PLANS_DIR" "$CONF_EMPTY_CFG_DIR"; }
trap cleanup_conf EXIT

# Helper: run the hook with overridden env in a subshell. Asserts stdout is empty.
expect_empty_with_env() {
  local desc="$1" json="$2"
  shift 2
  local result
  result=$(
    export WORKFLOW_PLANS_DIR="$CONF_PLANS_DIR"
    export AGENTS_CONFIG_DIR="$CONF_EMPTY_CFG_DIR"
    for assignment in "$@"; do
      key="${assignment%%=*}"
      val="${assignment#*=}"
      export "$key=$val"
    done
    echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
  )
  if [ -z "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected empty stdout, got non-empty"
  fi
}

# Helper: run the hook with overridden env in a subshell. Asserts stdout is non-empty.
expect_nonempty_with_env() {
  local desc="$1" json="$2"
  shift 2
  local result
  result=$(
    export WORKFLOW_PLANS_DIR="$CONF_PLANS_DIR"
    export AGENTS_CONFIG_DIR="$CONF_EMPTY_CFG_DIR"
    for assignment in "$@"; do
      key="${assignment%%=*}"
      val="${assignment#*=}"
      export "$key=$val"
    done
    echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
  )
  if [ -n "$result" ]; then
    pass "$desc"
  else
    fail "$desc — expected non-empty stdout (diff), got empty"
  fi
}

# ── T-CONF1: CONFIRM_DETAIL=off on detail.md → empty (diff suppressed) ────
echo "=== T-CONF1: CONFIRM_DETAIL=off on detail.md ==="
expect_empty_with_env "T-CONF1 CONFIRM_DETAIL=off suppresses diff for detail.md" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CONF_PLANS_DIR/foo-detail.md\",\"content\":\"new content\"}}" \
  CONFIRM_DETAIL=off

# ── T-CONF2: CONFIRM_OUTLINE=off on outline.md → empty ────────────────────
echo "=== T-CONF2: CONFIRM_OUTLINE=off on outline.md ==="
expect_empty_with_env "T-CONF2 CONFIRM_OUTLINE=off suppresses diff for outline.md" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CONF_PLANS_DIR/foo-outline.md\",\"content\":\"new content\"}}" \
  CONFIRM_OUTLINE=off

# ── T-CONF3: CONFIRM_INTENT=off on intent.md → empty ──────────────────────
echo "=== T-CONF3: CONFIRM_INTENT=off on intent.md ==="
expect_empty_with_env "T-CONF3 CONFIRM_INTENT=off suppresses diff for intent.md" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CONF_PLANS_DIR/foo-intent.md\",\"content\":\"new content\"}}" \
  CONFIRM_INTENT=off

# ── T-CONF4: CONFIRM_DETAIL=on on detail.md → non-empty (diff shown) ──────
echo "=== T-CONF4: CONFIRM_DETAIL=on on detail.md ==="
expect_nonempty_with_env "T-CONF4 CONFIRM_DETAIL=on does NOT suppress diff for detail.md" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CONF_PLANS_DIR/foo-detail.md\",\"content\":\"new content\"}}" \
  CONFIRM_DETAIL=on

# ── T-CONF5: Cross-suffix CONFIRM_INTENT=off on detail.md → non-empty ─────
echo "=== T-CONF5: cross-suffix CONFIRM_INTENT=off on detail.md ==="
expect_nonempty_with_env "T-CONF5 cross-suffix CONFIRM_INTENT=off does NOT suppress diff for detail.md" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CONF_PLANS_DIR/foo-detail.md\",\"content\":\"new content\"}}" \
  CONFIRM_INTENT=off

# ── T-CONF6: .env-overlay (loadDefaultEnv picks up file when env unset) ───
echo "=== T-CONF6: .env overlay sets CONFIRM_DETAIL=off ==="
CONF_CFG_DIR="${NODE_TMPDIR_CONF}/show-diff-conf-cfg-$$"
mkdir -p "$CONF_CFG_DIR"
printf 'CONFIRM_DETAIL=off\n' > "$CONF_CFG_DIR/.env"

T_CONF6_RESULT=$(
  export WORKFLOW_PLANS_DIR="$CONF_PLANS_DIR"
  export AGENTS_CONFIG_DIR="$CONF_CFG_DIR"
  unset CONFIRM_DETAIL
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CONF_PLANS_DIR/foo-detail.md\",\"content\":\"new content\"}}" \
    | run_with_timeout node "$HOOK" 2>/dev/null
)

if [ -z "$T_CONF6_RESULT" ]; then
  pass "T-CONF6 .env overlay CONFIRM_DETAIL=off suppresses diff"
else
  fail "T-CONF6 .env overlay CONFIRM_DETAIL=off — expected empty stdout, got non-empty"
fi
rm -rf "$CONF_CFG_DIR"

# ── Results ──────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi

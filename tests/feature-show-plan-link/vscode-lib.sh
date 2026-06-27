# VS Code lib tests (T-VSCODE-LIB-1~3, SPL-V, SPL-P).
# Sourced by ../feature-show-plan-link.sh — inherits all vars and functions.
#
# T-VSCODE-LIB: vscode-open.js extraction (#741-confirm-plan-ux)
# Verifies hooks/lib/vscode-open.js exposes the expected functions and
# show-plan-link.js still re-exports workspaceFolderUriFrom for backward compat.
#
# SPL-V: When isVsCode=true, systemMessage contains vscode://file/ markdown link.
# SPL-P: When isVsCode=false, systemMessage contains plain absolute path (no vscode://file/).
#
# L3 gap (what this test does NOT catch):
# - Whether vscode://file/ URIs actually render as clickable links in VS Code extension chat webview
# - Whether systemMessage markdown is rendered or displayed as plain text in the extension
# Closest-to-action mitigation: user tests clicking the link after implementation (WORKFLOW_USER_VERIFIED preflight)
# via bin/check-verification-gate.sh category: hook-registration

# Use Windows-form (pwd -W) for paths embedded inside `node -e` string literals.
# AGENTS_DIR (declared earlier) uses plain `pwd` and works for `node "$HOOK"` args
# because Git Bash auto-converts those, but path strings inside `node -e` text are
# not converted and must already be in Node-resolvable form on Windows.
AGENTS_DIR_NODE="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
VSCODE_LIB="$AGENTS_DIR_NODE/hooks/lib/vscode-open.js"
HOOK_NODE="$AGENTS_DIR_NODE/hooks/show-plan-link.js"

# ── T-VSCODE-LIB-1: vscode-open.js exports expected functions ──────────────
echo "=== T-VSCODE-LIB-1: vscode-open.js exports ==="
if [ ! -f "$VSCODE_LIB" ]; then
  echo "SKIP: T-VSCODE-LIB-1 — hooks/lib/vscode-open.js not yet created"
else
  T_VL1_RESULT=$(run_with_timeout node -e "
    const v = require('$VSCODE_LIB');
    const required = ['isVsCode','shouldOpenInVsCode','workspaceFolderUriFrom','resolveWorkspaceFolderUri','spawnCode','openInVsCode','toVsCodeFileUri'];
    const missing = required.filter(n => typeof v[n] !== 'function');
    if (missing.length) {
      process.stdout.write('MISSING:' + missing.join(','));
      process.exit(1);
    }
    process.stdout.write('OK');
  " 2>&1)
  if [ "$T_VL1_RESULT" = "OK" ]; then
    pass "T-VSCODE-LIB-1 vscode-open.js exports all required functions"
  else
    fail "T-VSCODE-LIB-1 vscode-open.js missing exports: $T_VL1_RESULT"
  fi
fi

# ── T-VSCODE-LIB-2: show-plan-link still re-exports workspaceFolderUriFrom ──
echo "=== T-VSCODE-LIB-2: show-plan-link.js re-export backward compat ==="
T_VL2_RESULT=$(run_with_timeout node -e "
  const m = require('$HOOK_NODE');
  if (typeof m.workspaceFolderUriFrom !== 'function') {
    process.stdout.write('not_function');
    process.exit(1);
  }
  const got = m.workspaceFolderUriFrom('/home/user');
  process.stdout.write(got || 'null');
" 2>&1)
if [ "$T_VL2_RESULT" = "file:///home/user" ]; then
  pass "T-VSCODE-LIB-2 show-plan-link re-exports workspaceFolderUriFrom correctly"
else
  fail "T-VSCODE-LIB-2 expected 'file:///home/user', got: $T_VL2_RESULT"
fi

# ── T-VSCODE-LIB-3: show-plan-link.js uses vscode-open.js (post-dedup assertion) ─
# SKIP when require('./lib/vscode-open') not yet present — becomes active after
# write-code step runs the dedup. When active, checks that none of the 6 VS Code
# helper functions remain as top-level inline definitions.
echo "=== T-VSCODE-LIB-3: show-plan-link.js dedup — no inline helper functions ==="
SPL_SOURCE="$AGENTS_DIR_NODE/hooks/show-plan-link.js"
if ! grep -qE "require\(['\"]\.\/lib\/vscode-open['\"]\)" "$SPL_SOURCE" 2>/dev/null; then
  echo "SKIP: T-VSCODE-LIB-3 — show-plan-link.js not yet deduplicated (write-code step pending)"
else
  T_VL3_FAIL=0
  for fn_name in isVsCode shouldOpenInVsCode workspaceFolderUriFrom resolveWorkspaceFolderUri spawnCode openInVsCode; do
    if grep -qE "^function ${fn_name}\(" "$SPL_SOURCE"; then
      fail "T-VSCODE-LIB-3 inline function def still present after dedup: ${fn_name}"
      T_VL3_FAIL=1
    fi
  done
  if [ "$T_VL3_FAIL" -eq 0 ]; then
    pass "T-VSCODE-LIB-3 show-plan-link.js uses vscode-open.js (no inline helper defs)"
  fi
fi

# ── SPL-V: isVsCode=true → systemMessage contains vscode://file/ markdown link ──
# When CLAUDE_CODE_ENTRYPOINT=claude-vscode (isVsCode returns true), show-plan-link.js
# should include a vscode://file/ URI in the systemMessage for quick navigation.
echo "=== SPL-V: isVsCode=true — systemMessage contains vscode://file/ ==="
SPL_V_RESULT=$(
  unset TERM_PROGRAM 2>/dev/null || true
  export CLAUDE_CODE_ENTRYPOINT=claude-vscode
  unset VSCODE_CRASH_REPORTER_PROCESS_TYPE 2>/dev/null || true
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}" \
    | run_with_timeout node "$HOOK" 2>/dev/null
)
SPL_V_MSG=$(echo "$SPL_V_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)
if echo "$SPL_V_MSG" | grep -qF "vscode://file/"; then
  pass "SPL-V isVsCode=true — systemMessage contains vscode://file/ markdown link"
else
  fail "SPL-V isVsCode=true — systemMessage missing vscode://file/: $SPL_V_MSG"
fi

# ── SPL-P: isVsCode=false → systemMessage contains plain path (no vscode://file/) ──
# When neither TERM_PROGRAM nor CLAUDE_CODE_ENTRYPOINT signals VS Code, the
# systemMessage must contain the absolute file path without a vscode:// URI.
echo "=== SPL-P: isVsCode=false — systemMessage plain path (no vscode://file/) ==="
SPL_P_RESULT=$(
  unset TERM_PROGRAM 2>/dev/null || true
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PLANS_DIR/abc-detail.md\"},\"tool_response\":{\"success\":true}}" \
    | run_with_timeout node "$HOOK" 2>/dev/null
)
SPL_P_MSG=$(echo "$SPL_P_RESULT" | run_with_timeout node -e "
  let d; try { d = JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e) { process.exit(1); }
  process.stdout.write(d.systemMessage || '');
" 2>/dev/null)
if echo "$SPL_P_MSG" | grep -qF "Plan file written:" && ! echo "$SPL_P_MSG" | grep -qF "vscode://file/"; then
  pass "SPL-P isVsCode=false — systemMessage has plain path, no vscode://file/ URI"
else
  fail "SPL-P isVsCode=false — unexpected systemMessage: $SPL_P_MSG"
fi

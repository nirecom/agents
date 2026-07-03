#!/bin/bash
# tests/fix-issue-1198-clarify-guard-worktree.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, clarify-intent, guard-loop, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Whether the real enforce-worktree.js hook fires and dispatches to this
#   predicate in a live Claude Code session (PreToolUse registration).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# L1 table-driven unit test for isAllowedClarifyGuardLoop(cmd, repoRoot) —
# the main-worktree allow predicate for the CI-C0 guard-loop wrapper
# (bin/github-issues/clarify-guard-loop.sh, issue #1198).
#
# Contract:
#   Allow exactly: bash "<AGENTS_CONFIG_DIR>/bin/github-issues/clarify-guard-loop.sh" [args...]
#   (double-quoted script path). Reject: chaining (&& ; | || bare &), command
#   substitution ($(...) / backticks), a different script path, any redirect
#   in the arg tail, single-quoted path, wrong interpreter.
#
# Pre-implementation RED: every case FAILs with "not yet exported
# (pre-implementation)" while the predicate is missing. GREEN after /write-code.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _A="$(cygpath -m "$AGENTS_DIR")"
else
    _A="$AGENTS_DIR"
fi

STANDARD_JS="${_A}/hooks/enforce-worktree/main-worktree-allows/standard.js"
EW_JS="${_A}/hooks/enforce-worktree.js"
SCRIPT_PATH="${_A}/bin/github-issues/clarify-guard-loop.sh"
OTHER_SCRIPT="${_A}/bin/github-issues/check-closes-issues-nonempty.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
    else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

# --- T-series: table-driven predicate cases (single node process) -----------
# The case table lives in JS ({name, cmd, want}); node prints one PASS/FAIL
# line per case; bash tallies them. Env carries paths to avoid quoting issues.
TABLE_OUT=$(ACD_VAL="$_A" STD_JS_VAL="$STANDARD_JS" SP_VAL="$SCRIPT_PATH" OTHER_VAL="$OTHER_SCRIPT" \
run_with_timeout node -e '
  process.env.AGENTS_CONFIG_DIR = process.env.ACD_VAL || "";
  const sp = process.env.SP_VAL;
  const other = process.env.OTHER_VAL;
  const repoRoot = "/some/repo/root";

  const cases = [
    { name: "T1: canonical double-quoted path + session-id + plans-dir",
      cmd: `bash "${sp}" --session-id abc --plans-dir /foo`, want: "allow" },
    { name: "T2: canonical + extra --non-github flag",
      cmd: `bash "${sp}" --session-id abc --plans-dir /foo --non-github`, want: "allow" },
    { name: "T3: && chaining after script",
      cmd: `bash "${sp}" --session-id abc && rm -rf /tmp/x`, want: "reject" },
    { name: "T4: pipe | in cmd",
      cmd: `bash "${sp}" --session-id abc | tee /tmp/out`, want: "reject" },
    { name: "T5: semicolon ; separator",
      cmd: `bash "${sp}" --session-id abc ; echo done`, want: "reject" },
    { name: "T6: $() command substitution in args",
      cmd: `bash "${sp}" --session-id $(cat /etc/passwd) --plans-dir /foo`, want: "reject" },
    { name: "T7: different script path",
      cmd: `bash "${other}" --session-id abc`, want: "reject" },
    { name: "T8: redirect > in args",
      cmd: `bash "${sp}" --session-id abc > /tmp/out`, want: "reject" },
    { name: "T9: single-quoted script path",
      cmd: `bash '"'"'${sp}'"'"' --session-id abc --plans-dir /foo`, want: "reject" },
    { name: "T10: bare & background operator",
      cmd: `bash "${sp}" --session-id abc & echo evil`, want: "reject" },
    { name: "T11: || chaining",
      cmd: `bash "${sp}" --session-id abc || rm -rf /tmp/x`, want: "reject" },
    { name: "T12: backtick substitution in args",
      cmd: "bash \"" + sp + "\" --session-id `touch /tmp/x`", want: "reject" },
    { name: "T13: append redirect >> in args",
      cmd: `bash "${sp}" --session-id abc >> /tmp/out`, want: "reject" },
    { name: "T14: wrong interpreter (node)",
      cmd: `node "${sp}" --session-id abc --plans-dir /foo`, want: "reject" },
  ];

  let fn;
  try {
    const m = require(process.env.STD_JS_VAL);
    fn = m.isAllowedClarifyGuardLoop;
  } catch (e) { fn = undefined; }

  for (const c of cases) {
    if (typeof fn !== "function") {
      console.log(`FAIL: ${c.name} — isAllowedClarifyGuardLoop not yet exported from standard.js (pre-implementation)`);
      continue;
    }
    let got;
    try { got = fn(c.cmd, repoRoot) ? "allow" : "reject"; }
    catch (e) { got = "throw:" + e.message.split("\n")[0]; }
    if (got === c.want) console.log(`PASS: ${c.name}`);
    else console.log(`FAIL: ${c.name} — want=${c.want} got=${got} cmd=${c.cmd}`);
  }
' 2>&1)

if [ -z "$TABLE_OUT" ]; then
    fail "T-series: node table runner produced no output (harness error)"
else
    while IFS= read -r line; do
        case "$line" in
            PASS:*) pass "${line#PASS: }" ;;
            FAIL:*) fail "${line#FAIL: }" ;;
            *)      fail "T-series harness noise: $line" ;;
        esac
    done <<< "$TABLE_OUT"
fi

# --- EX-series: export wiring ------------------------------------------------
# EX-1: exported from hooks/enforce-worktree/main-worktree-allows/standard.js
EX1_RESULT=$(STD_JS_VAL="$STANDARD_JS" run_with_timeout node -e '
  try {
    const m = require(process.env.STD_JS_VAL);
    console.log(typeof m.isAllowedClarifyGuardLoop);
  } catch (e) { console.log("load-error"); }
' 2>/dev/null)
if [ "$EX1_RESULT" = "function" ]; then
    pass "EX-1: isAllowedClarifyGuardLoop exported from main-worktree-allows/standard.js"
else
    fail "EX-1: isAllowedClarifyGuardLoop not yet exported from hooks/enforce-worktree/main-worktree-allows/standard.js (pre-implementation; got typeof=$EX1_RESULT)"
fi

# EX-2: re-exported from hooks/enforce-worktree.js module.exports
# (require is safe: main logic is gated behind require.main === module).
EX2_RESULT=$(EW_JS_VAL="$EW_JS" run_with_timeout node -e '
  try {
    const m = require(process.env.EW_JS_VAL);
    console.log(typeof m.isAllowedClarifyGuardLoop);
  } catch (e) { console.log("load-error"); }
' 2>/dev/null)
if [ "$EX2_RESULT" = "function" ]; then
    pass "EX-2: isAllowedClarifyGuardLoop re-exported from enforce-worktree.js"
else
    fail "EX-2: isAllowedClarifyGuardLoop not yet re-exported from hooks/enforce-worktree.js (pre-implementation; got typeof=$EX2_RESULT)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

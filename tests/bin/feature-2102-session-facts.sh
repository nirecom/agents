#!/usr/bin/env bash
# Tests: bin/workflow/read-session-facts, bin/workflow/lib/session-facts/keys.js, bin/workflow/lib/session-facts/collect.js, bin/workflow/lib/session-facts/gate-facts.js, install/settings-allow-commands.txt, hooks/bash-guard/allow.js, hooks/lib/allow-command-list.js
# Tags: tl2, workflow, session-facts, bundled-reader, ssot, runner, scope:issue-specific, pwsh-not-required

# #2102 item 2: `bin/workflow/read-session-facts` folds three read-only lookups
# (PLANS_DIR, the two CONFIRM gates, the persisted complexity record) into one Bash
# call. This entrypoint owns INV-6 -- the allow-list SSOT registration, which belongs
# to neither sibling -- and dispatches the contract and value suites.

# TL3 gap (what this test does NOT catch): whether Claude Code honours bash-guard's
# permissionDecision "allow" for this CLI on a live Bash call. Closest-to-action
# mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category:
# skill-orchestration.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBDIR="$REPO_ROOT/tests/bin/feature-2102-session-facts"
ALLOW_SSOT="$REPO_ROOT/install/settings-allow-commands.txt"
CLI_REL="bin/workflow/read-session-facts"
CLI="$REPO_ROOT/$CLI_REL"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo "=== INV-6: the bundled reader is registered in the allow-list SSOT ==="
# ssot-structure.sh checks the file's shape in general; this is the issue-specific pin
# that goes red the day THIS CLI is dropped from the list and every caller starts
# prompting for permission again.
if [ -f "$ALLOW_SSOT" ]; then pass "V1a: the allow-list SSOT exists"
else fail "V1a: the allow-list SSOT exists -- not found at $ALLOW_SSOT"; fi
check "V1b: $CLI_REL is listed exactly once" 1 \
  "$(grep -cxF -- "$CLI_REL" "$ALLOW_SSOT" 2>/dev/null || true)"
if [ -f "$CLI" ]; then pass "V1c: the CLI file exists"
else fail "V1c: the CLI file exists -- not found at $CLI"; fi
SHEBANG="$(head -n 1 "$CLI" 2>/dev/null || echo "")"
case "$SHEBANG" in
  *node*) pass "V1d: the shebang resolves to node" ;;
  *) fail "V1d: the shebang resolves to node -- got [$SHEBANG]" ;;
esac
# Non-vacuity for V1b: an entry that has always been there must still count once, so a
# `grep` that silently matched nothing cannot make V1b green by accident.
check "V1e: control -- bin/confirm-off is still listed exactly once" 1 \
  "$(grep -cxF -- "bin/confirm-off" "$ALLOW_SSOT" 2>/dev/null || true)"

echo ""
echo "=== INV-6b: bash-guard's self-script allow path admits this CLI ==="
# V1b only greps the SSOT list; the list is now read by hooks/bash-guard/allow.js, not
# expanded into settings.json spellings (#2265). Drive judgeBashCommand() with the
# argument-position form callers issue and require the SELF_SCRIPT allow. The shebang is
# node (V1d), so the node form is the one that must match.
BG_STATE_DIR="$TMPDIR_BASE/inv6-workflow"; mkdir -p "$BG_STATE_DIR" "$TMPDIR_BASE/inv6-plans"
bg_judge() {
  CLAUDE_WORKFLOW_DIR="$(nrm "$BG_STATE_DIR")" WORKFLOW_PLANS_DIR="$(nrm "$TMPDIR_BASE/inv6-plans")" \
  JUDGE="$(nrm "$REPO_ROOT/hooks/bash-guard/judge.js")" BG_CMD="$1" run_with_timeout node -e '
    "use strict";
    let line;
    try {
      const v = require(process.env.JUDGE).judgeBashCommand({ tool_name: "Bash",
        session_id: "sid-2102-no-state", tool_input: { command: process.env.BG_CMD } });
      line = String(v && v.verdict) + "\t" + String(v && v.code);
    } catch (e) { line = "<THREW:" + String((e && e.message) || e).split("\n")[0] + ">"; }
    process.stdout.write(line);
  ' 2>/dev/null
}
check "V1f: node \"\$AGENTS_CONFIG_DIR/$CLI_REL\" is allowed as a self script" \
  "allow	BG-ALLOW-SELF-SCRIPT" "$(bg_judge "node \"\$AGENTS_CONFIG_DIR/$CLI_REL\" --session x")"
check "V1g: control -- a lookalike name absent from the SSOT is not allowed" \
  "passThrough	BG-NO-HIT" "$(bg_judge "node \"\$AGENTS_CONFIG_DIR/$CLI_REL-fake\" --session x")"

echo ""
RC_ALL=0
FAILED=""
[ "$FAIL" -eq 0 ] || { RC_ALL=1; FAILED=" inv-6"; }
for c in contract values security; do
  echo "########## $c ##########"
  if bash "$SUBDIR/$c.sh"; then :; else
    rc=$?
    if [ "$rc" -eq 77 ]; then echo "SKIPPED: $c"; else RC_ALL=1; FAILED="$FAILED $c"; fi
  fi
  echo ""
done

echo "########## feature-2102-session-facts summary ##########"
if [ "$RC_ALL" -eq 0 ]; then
  echo "The bundled reader's contract, values and adversarial handling hold."
else
  echo "Failed suites:$FAILED"
fi
exit "$RC_ALL"

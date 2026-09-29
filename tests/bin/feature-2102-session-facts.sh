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

AGENTS_DIR="$REPO_ROOT"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
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
case_begin "V1ab-ssot-lists-cli" "install/settings-allow-commands.txt"
if [ -f "$ALLOW_SSOT" ]; then pass "V1a: the allow-list SSOT exists"
else fail "V1a: the allow-list SSOT exists -- not found at $ALLOW_SSOT"; fi
check "V1b: $CLI_REL is listed exactly once" 1 \
  "$(grep -cxF -- "$CLI_REL" "$ALLOW_SSOT" 2>/dev/null || true)"
case_end
case_begin "V1cd-cli-file-and-shebang" "bin/workflow/read-session-facts"
if [ -f "$CLI" ]; then pass "V1c: the CLI file exists"
else fail "V1c: the CLI file exists -- not found at $CLI"; fi
SHEBANG="$(head -n 1 "$CLI" 2>/dev/null || echo "")"
case "$SHEBANG" in
  *node*) pass "V1d: the shebang resolves to node" ;;
  *) fail "V1d: the shebang resolves to node -- got [$SHEBANG]" ;;
esac
case_end
# Non-vacuity for V1b: an entry that has always been there must still count once, so a
# `grep` that silently matched nothing cannot make V1b green by accident.
case_begin "V1e-ssot-control-entry" "install/settings-allow-commands.txt"
check "V1e: control -- bin/confirm-off is still listed exactly once" 1 \
  "$(grep -cxF -- "bin/confirm-off" "$ALLOW_SSOT" 2>/dev/null || true)"
case_end

echo ""
echo "=== INV-6b: bash-guard's self-script allow path admits this CLI ==="
# V1b only greps the SSOT list; the list is now read by hooks/bash-guard/allow.js, not
# expanded into settings.json spellings (#2265). Drive judgeBashCommand() with the
# argument-position form callers issue and require the SELF_SCRIPT allow. The shebang is
# node (V1d), so the node form is the one that must match.
BG_STATE_DIR="$TMPDIR_BASE/inv6-workflow"; mkdir -p "$BG_STATE_DIR" "$TMPDIR_BASE/inv6-plans"
# One node judges every command (argv); require.cache is cleared per row so no judge
# state carries over, and each row prints exactly one "<idx>\t<verdict>\t<code>" line.
bg_judge_batch() {
  CLAUDE_WORKFLOW_DIR="$(nrm "$BG_STATE_DIR")" WORKFLOW_PLANS_DIR="$(nrm "$TMPDIR_BASE/inv6-plans")" \
  JUDGE="$(nrm "$REPO_ROOT/hooks/bash-guard/judge.js")" run_with_timeout node -e '
    "use strict";
    process.argv.slice(1).forEach((cmd, i) => {
      for (const k of Object.keys(require.cache)) delete require.cache[k];
      let line;
      try {
        const v = require(process.env.JUDGE).judgeBashCommand({ tool_name: "Bash",
          session_id: "sid-2102-no-state", tool_input: { command: cmd } });
        line = String(v && v.verdict) + "\t" + String(v && v.code);
      } catch (e) { line = "<THREW:" + String((e && e.message) || e).split("\n")[0] + ">"; }
      process.stdout.write(i + "\t" + line + "\n");
    });
  ' "$@" 2>/dev/null
}
BG_OUT="$(bg_judge_batch "node \"\$AGENTS_CONFIG_DIR/$CLI_REL\" --session x" \
  "node \"\$AGENTS_CONFIG_DIR/$CLI_REL-fake\" --session x")"
bg_row() { printf '%s\n' "$BG_OUT" | sed -n "s/^$1	//p"; }
BG_N="$(printf '%s\n' "$BG_OUT" | grep -c '^[0-9]	' || true)"
[ "$BG_N" = 2 ] || fail "V1-batch: the batched judge returned $BG_N result lines for 2 rows (vacuity guard)"
case_begin "V1f-bash-guard-self-script-allow" "hooks/bash-guard/allow.js"
check "V1f: node \"\$AGENTS_CONFIG_DIR/$CLI_REL\" is allowed as a self script" \
  "allow	BG-ALLOW-SELF-SCRIPT" "$(bg_row 0)"
case_end
case_begin "V1g-lookalike-not-in-list" "hooks/lib/allow-command-list.js"
check "V1g: control -- a lookalike name absent from the SSOT is not allowed" \
  "passThrough	BG-NO-HIT" "$(bg_row 1)"
case_end

echo ""
RC_ALL=0
FAILED=""
[ "$FAIL" -eq 0 ] || { RC_ALL=1; FAILED=" inv-6"; }
run_suite() {
  local c="$1" rc
  echo "########## $c ##########"
  if bash "$SUBDIR/$c.sh"; then :; else
    rc=$?
    if [ "$rc" -eq 77 ]; then echo "SKIPPED: $c"; else RC_ALL=1; FAILED="$FAILED $c"; fi
  fi
  echo ""
}
case_begin "suite-contract" "bin/workflow/lib/session-facts/keys.js"
run_suite contract
case_end
case_begin "suite-values" "bin/workflow/lib/session-facts/gate-facts.js"
run_suite values
case_end
case_begin "suite-security" "bin/workflow/lib/session-facts/collect.js"
run_suite security
case_end

echo "########## feature-2102-session-facts summary ##########"
if [ "$RC_ALL" -eq 0 ]; then
  echo "The bundled reader's contract, values and adversarial handling hold."
else
  echo "Failed suites:$FAILED"
fi
exit "$RC_ALL"

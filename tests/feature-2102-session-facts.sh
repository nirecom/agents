#!/usr/bin/env bash
# Tests: bin/workflow/read-session-facts, bin/workflow/lib/session-facts/keys.js, bin/workflow/lib/session-facts/collect.js, bin/workflow/lib/session-facts/gate-facts.js, install/settings-allow-commands.txt
# Tags: tl2, workflow, session-facts, bundled-reader, ssot, runner, scope:issue-specific, pwsh-not-required

# #2102 item 2: `bin/workflow/read-session-facts` folds three read-only lookups
# (PLANS_DIR, the two CONFIRM gates, the persisted complexity record) into one Bash
# call. This entrypoint owns INV-6 -- the allow-list SSOT registration, which belongs
# to neither sibling -- and dispatches the contract and value suites.

# TL3 gap (what this test does NOT catch): whether install/assemble-settings.js actually
# emits the allow rule into a deployed ~/.claude/settings.json. Closest-to-action
# mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category:
# skill-orchestration.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBDIR="$REPO_ROOT/tests/feature-2102-session-facts"
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
echo "=== INV-6b: the real settings assembler actually deploys this rule ==="
# V1b only greps the SSOT list; it can't catch a broken generator or deploy path. This
# runs the real deployAssembledSettings pipeline against a throwaway fixture HOME (never
# the real ~/.claude/settings.json) and structurally parses the deployed permissions.allow
# array for the exact bash-c rule spelling, located programmatically from
# PATH_TEMPLATES_ARGV so it can never drift from settings-allow-rules.js's own source.
FIXTURE_HOME="$TMPDIR_BASE/inv6-home"; mkdir -p "$FIXTURE_HOME"
FIXTURE_HOME_N="$(nrm "$FIXTURE_HOME")"
REPO_ROOT_N="$(nrm "$REPO_ROOT")"
DEPLOY_OUT="$TMPDIR_BASE/inv6-deploy-result.json"
REPO_ROOT_N="$REPO_ROOT_N" FIXTURE_HOME_N="$FIXTURE_HOME_N" DEPLOY_OUT="$DEPLOY_OUT" \
  run_with_timeout node -e '
    "use strict";
    const fs = require("fs");
    const path = require("path");
    const deploy = require(path.join(process.env.REPO_ROOT_N, "install", "lib", "settings-deploy.js"));
    const allowRules = require(path.join(process.env.REPO_ROOT_N, "install", "lib", "settings-allow-rules.js"));
    const out = { error: "" };
    let result = null;
    try {
      result = deploy.deployAssembledSettings({
        agentsRoot: process.env.REPO_ROOT_N,
        homeDir: process.env.FIXTURE_HOME_N,
      });
    } catch (e) {
      out.error = String((e && e.message) || e);
    }
    if (result) {
      out.outPath = result.outPath;
      let deployed = null;
      try {
        deployed = JSON.parse(fs.readFileSync(result.outPath, "utf8"));
      } catch (e) {
        out.readError = String((e && e.message) || e);
      }
      const allow = deployed && deployed.permissions && Array.isArray(deployed.permissions.allow)
        ? deployed.permissions.allow : null;
      out.allowIsArray = Array.isArray(allow);
      const argvIdx = allowRules.PATH_TEMPLATES_ARGV.findIndex((t) =>
        t.indexOf("bash -c") !== -1 && t.indexOf("cd \"$AGENTS_CONFIG_DIR\"") === -1);
      out.argvIdxFound = argvIdx !== -1;
      if (argvIdx !== -1 && allow) {
        const rel = "bin/workflow/read-session-facts";
        const candidates = allowRules.pathRules(process.env.REPO_ROOT_N, "node", rel);
        const candidate = candidates[argvIdx * 2];
        out.candidate = candidate;
        out.matchCount = allow.filter((r) => r === candidate).length;
      }
    }
    fs.writeFileSync(process.env.DEPLOY_OUT, JSON.stringify(out));
  ' 2>"$TMPDIR_BASE/inv6-stderr.txt"
read_deploy_field() {
  DEPLOY_OUT="$DEPLOY_OUT" FIELD="$1" run_with_timeout node -e '
    "use strict";
    const fs = require("fs");
    let o = {};
    try { o = JSON.parse(fs.readFileSync(process.env.DEPLOY_OUT, "utf8")); } catch (e) {}
    const v = o[process.env.FIELD];
    process.stdout.write(v === undefined || v === null ? "" : String(v));
  '
}
if [ -f "$DEPLOY_OUT" ]; then pass "V1f: the assembler run produced a result to parse (non-vacuity)"
else fail "V1f: the assembler run produced a result to parse -- no output file, stderr: $(cat "$TMPDIR_BASE/inv6-stderr.txt" 2>/dev/null)"; fi
check "V1g: the assembler ran against the fixture HOME without error" "" "$(read_deploy_field error)"
check "V1h: the deployed permissions.allow parsed as a structural array" "true" "$(read_deploy_field allowIsArray)"
check "V1i: the read-session-facts bash-c wildcard spelling is locatable in the template table" \
  "true" "$(read_deploy_field argvIdxFound)"
check "V1j: the deployed allow-list contains that exact spelling exactly once" 1 "$(read_deploy_field matchCount)"

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

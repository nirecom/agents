#!/usr/bin/env bash
# tests/feature-codegraph-bootstrap.sh
# Tests: install/codegraph-mcp.js, install/linux/codegraph.sh, install/win/codegraph.ps1, install.sh, install.ps1
# Tags: codegraph, installer, mcp-registration, env-flag, fail-safe-off, idempotency, side-effect-absence, secret-leakage, usage-error, TL2, pwsh-not-required, scope:issue-specific
# Detail plan ST-19 (cases B1-B18). Dispatcher only: counters, assertions and the
# source order. Layer TL2 — install/linux/codegraph.sh and install/codegraph-mcp.js
# run as real processes against a redirected HOME, a stub PATH and a synthetic
# .env; only the three external binaries (npm / codegraph / claude) are stubs.
set -u

# TL3 gap (what this test does NOT catch):
# - `claude mcp add --scope user` really writing mcpServers.codegraph into the
#   real ~/.claude.json — the CLI is a stub here, so only its argv is pinned.
# - install/win/codegraph.ps1 completing non-interactively at the same flag
#   verdict, and install.ps1 / install.sh reaching the per-tool script at run time.
# - The asserted-absent side effects (CLAUDE.md replacement, hooks.UserPromptSubmit,
#   Cursor/Codex/Copilot configs) staying absent against the real upstream CLI.
# - CLAUDE.md file-type preservation where the shell cannot make a real symlink.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: installer.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-codegraph-bootstrap"

# install/win/codegraph.ps1 is named in `# Tests:` but NOT executed: this repo has no
# PowerShell test harness. The registration logic both OSes share lives in
# install/codegraph-mcp.js and IS executed here; PowerShell-only are fnm resolution,
# the get-config-var.ps1 call shape and the npm call.
CODEGRAPH_SH="$AGENTS_DIR/install/linux/codegraph.sh"
CODEGRAPH_MCP_JS="$AGENTS_DIR/install/codegraph-mcp.js"
RUN_WITH_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"
CASE_TIMEOUT=60

# TL3 gap, continued — win32 shim resolution (#2150):
# - whether a real `npm install -g` of the claude CLI on THIS host writes
#   byte-identical shim content (claude + claude.cmd + POSIX sibling) to the
#   fixture shape this suite now uses by default (WC-1..WC-3 cover the edge
#   cases) — WORKFLOW_USER_VERIFIED preflight, category: installer.

# No `# Serial:` header: every write lands under a per-run mktemp -d (redirected HOME,
# stub PATH, private AGENTS_CONFIG_DIR). Nothing touches the repo tree, the real home,
# global git config or a shared port, and no case depends on another case's leftovers.
PASS=0; FAIL=0; SKIP_ENV=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip_env() { echo "SKIP-ENV: $1"; SKIP_ENV=$((SKIP_ENV + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# Preflight: name the missing implementation explicitly, then still run every case. A
# 127 from a missing script is a real failure of the contract under test; skipping the
# run would also skip the proof that this harness is sound.
for f in "$CODEGRAPH_SH" "$CODEGRAPH_MCP_JS"; do
    [ -f "$f" ] || fail "IMPLEMENTATION MISSING: ${f#"$AGENTS_DIR"/} (detail plan ST-2 / ST-4)"
done
[ -f "$RUN_WITH_TIMEOUT" ] || { echo "FAIL: harness missing bin/run-with-timeout.sh"; exit 1; }

# B0 — entrypoint reachability. Every case below runs the script as
# `bash "$CODEGRAPH_SH"`, which succeeds whatever the file mode is; install.sh executes
# it directly, which does not. Without this pair the suite is green on a script the
# real installer cannot run. git's recorded mode is the contract, not the working-tree
# bit: core.fileMode is false on Windows checkouts, so only the index carries it
# (rules/coding.md, "bin/ Script Execute Bit").
B0_MODE="$(git -C "$AGENTS_DIR" ls-files -s -- install/linux/codegraph.sh 2>/dev/null | cut -d' ' -f1)"
assert_eq "B0-a: install/linux/codegraph.sh is tracked with mode 100755 (else: git update-index --chmod=+x install/linux/codegraph.sh)" \
    "100755" "${B0_MODE:-UNTRACKED}"
B0_CALL="$(grep -c '^[[:space:]]*"\$AGENTS_ROOT/install/linux/codegraph\.sh"' "$AGENTS_DIR/install.sh" 2>/dev/null || true)"
assert_eq "B0-b: install.sh invokes install/linux/codegraph.sh directly, so B0-a is the reachability contract" \
    "1" "${B0_CALL:-0}"

# shellcheck source=./feature-codegraph-bootstrap/harness.sh
. "$MODULE_DIR/harness.sh"
# shellcheck source=./feature-codegraph-bootstrap/fixtures.sh
. "$MODULE_DIR/fixtures.sh"
# shellcheck source=./feature-codegraph-bootstrap/cases.sh
. "$MODULE_DIR/cases.sh"
# shellcheck source=./feature-codegraph-bootstrap/ownership.sh
. "$MODULE_DIR/ownership.sh"
# shellcheck source=./feature-codegraph-bootstrap/telemetry-reset.sh
. "$MODULE_DIR/telemetry-reset.sh"
# shellcheck source=./feature-codegraph-bootstrap/cli-version.sh
. "$MODULE_DIR/cli-version.sh"
# shellcheck source=./feature-codegraph-bootstrap/win-shim.sh
. "$MODULE_DIR/win-shim.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP_ENV env-limited"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

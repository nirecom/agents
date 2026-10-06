#!/usr/bin/env bash
# tests/hooks/feature-canary6a-pkgmgr-interpc/pkg-mgr-ir.sh
# Tests: hooks/lib/bash-write-targets/pkg-mgr.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js
# Tags: scope:issue-specific, pkg-mgr, canary-6a, ir-migration, fail-closed, pwsh-not-required
# isPkgMgrWriteIR (#1411): npm/pnpm/yarn/pip/uv/cargo/go read-allowlist per tool (mirrors
# isGitWriteIR); any other subcommand form defaults to WRITE (fail-closed).
# RED-pending: SKIPs (exit 0) while pkg-mgr.js is absent; rows FAIL until correct after.
# L3 gap: live PreToolUse pipeline and session-scoped worktree path comparison.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

. "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! pkg_mgr_module_present; then
  skip "pkg-mgr.js not yet implemented — isPkgMgrWriteIR unavailable (RED-pending, fail-before-fix)"
  report_totals
  exit 0
fi

echo "=== PW: pkg-mgr WRITE subcommands → true (7 tools) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'PW_TABLE'
PW-npm-install^npm install^true
PW-npm-i^npm i^true
PW-npm-ci^npm ci^true
PW-npm-update^npm update^true
PW-pnpm-install^pnpm install^true
PW-pnpm-add^pnpm add lodash^true
PW-yarn-install^yarn install^true
PW-yarn-add^yarn add react^true
PW-pip-install^pip install pytest^true
PW-pip-uninstall^pip uninstall pytest^true
PW-pip3-install^pip3 install black^true
PW-uv-pip-install^uv pip install requests^true
PW-uv-add^uv add ruff^true
PW-cargo-build^cargo build^true
PW-cargo-check^cargo check^true
PW-cargo-install^cargo install ripgrep^true
PW-go-build^go build ./...^true
PW-go-mod-tidy^go mod tidy^true
PW_TABLE

echo "=== CFC: cargo fail-closed (not in read-list → write) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'CFC_TABLE'
CFC-check^cargo check^true
CFC-test^cargo test^true
CFC-run^cargo run^true
CFC-bench^cargo bench^true
CFC-doc^cargo doc^true
CFC-fetch^cargo fetch^true
CFC-vendor^cargo vendor^true
CFC-clean^cargo clean^true
CFC_TABLE

echo "=== PR: pkg-mgr READ subcommands → false ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'PR_TABLE'
PR-npm-list^npm list^false
PR-npm-ls^npm ls^false
PR-npm-view^npm view react^false
PR-pip-show^pip show black^false
PR-pip-list^pip list^false
PR-pip-freeze^pip freeze^false
PR-cargo-tree^cargo tree^false
PR-cargo-metadata^cargo metadata^false
PR-go-env^go env^false
PR-go-version^go version^false
PR-yarn-info^yarn info^false
PR-yarn-why^yarn why react^false
PR-npm-version-flag^npm --version^false
PR-cargo-version-flag^cargo --version^false
PR_TABLE

echo "=== FC: unknown subcommands → true (fail-closed) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'FC_TABLE'
FC-npm-frobnicate^npm frobnicate^true
FC-cargo-qux^cargo qux^true
FC-pip-zzz^pip zzz^true
FC_TABLE

echo "=== BARE: bare tool (no subcommand) → true (fail-closed) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'BARE_TABLE'
BARE-npm^npm^true
BARE-cargo^cargo^true
BARE-pip^pip^true
BARE_TABLE

echo "=== INV: invocation-form coverage (path-qualified / env-prefix) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'INV_TABLE'
INV-path-qualified^/usr/bin/npm install^true
INV-env-prefix^VAR=1 npm install^true
INV_TABLE

echo "=== UV: uv 2-stage subcommand resolution ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'UV_TABLE'
UV-pip-install^uv pip install requests^true
UV-pip-list^uv pip list^false
UV-pip-show^uv pip show foo^false
UV-add^uv add ruff^true
UV-tree^uv tree^false
UV_TABLE

echo "=== GO: go 2-stage subcommand resolution (go mod ...) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pkg_mgr_write_ir "$cmd")"
done <<'GO_TABLE'
GO-mod-tidy^go mod tidy^true
GO-mod-download^go mod download^true
GO-mod-graph^go mod graph^false
GO_TABLE

echo "=== CL: classify() of pkg-mgr write → read post-retire (SSOT moved to predicate) ==="
assert_eq "CL-npm-install classify → read" "read" "$(classify_ir 'npm install foo')"
assert_eq "CL-cargo-build classify → read" "read" "$(classify_ir 'cargo build')"
assert_eq "CL-npm-list classify → read (sanity)" "read" "$(classify_ir 'npm list')"

report_totals
exit "$FAIL"

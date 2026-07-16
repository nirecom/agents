#!/usr/bin/env bash
# tests/feature-canary6a-pkgmgr-interpc/lib.sh
# Tests: hooks/lib/bash-write-targets/pkg-mgr.js, hooks/lib/bash-write-targets.js
# Tags: scope:issue-specific, pkg-mgr, interpreter-c, canary-6a, test-helper, pwsh-not-required
# Shared helpers + node bridges for the canary6a pkg-mgr/interpreter-c parts.
# Sourced by each part; NOT run standalone. Contract: $1 = WORKTREE root.
#
# RED-pending (#1411 write-tests): isPkgMgrWriteIR (new module pkg-mgr.js) and
# isInterpreterCWriteIR (new export in bash-write-targets.js) do NOT exist yet.
# The bridges guard require()/typeof and emit "ERROR:no-module" / "ERROR:not-exported"
# instead of crashing so the harness records a clean FAIL. When pkg-mgr.js is
# entirely absent, the part MAY choose to SKIP (exit 0) so the dispatcher stays green.

set -uo pipefail

MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

PASS=0; FAIL=0; SKIP=0

WORKTREE="${1:-}"
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found — skipping tests"; exit 77; }

if command -v cygpath >/dev/null 2>&1; then WT_NODE="$(cygpath -m "$WORKTREE")"; else WT_NODE="$WORKTREE"; fi
GUARD_JS="${WT_NODE}/hooks/enforce-worktree.js"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# pkg_mgr_module_present → 0 when hooks/lib/bash-write-targets/pkg-mgr.js requires
# and exports isPkgMgrWriteIR, else 1. Used by parts to SKIP gracefully pre-impl.
pkg_mgr_module_present() {
  local r
  r="$(run_with_timeout 30 node -e "
    try { const m=require('${WT_NODE}/hooks/lib/bash-write-targets/pkg-mgr'); process.stdout.write(typeof m.isPkgMgrWriteIR==='function'?'yes':'no'); }
    catch (e) { process.stdout.write('no'); }
  " 2>/dev/null)"
  [ "$r" = "yes" ]
}

# pkg_mgr_write_ir <cmd> → "true"|"false"|"ERROR:*". isPkgMgrWriteIR in pkg-mgr.js.
pkg_mgr_write_ir() {
  run_with_timeout 30 node -e "
    let m; try { m=require('${WT_NODE}/hooks/lib/bash-write-targets/pkg-mgr'); }
    catch (e) { process.stdout.write('ERROR:no-module'); process.exit(0); }
    if (typeof m.isPkgMgrWriteIR !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(m.isPkgMgrWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# interpreter_c_write_ir <cmd> → "true"|"false"|"ERROR:*". isInterpreterCWriteIR
# in hooks/lib/bash-write-targets.js.
interpreter_c_write_ir() {
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/lib/bash-write-targets');
    if (typeof m.isInterpreterCWriteIR !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(m.isInterpreterCWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# classify_ir <cmd> → "read"|"write". Production path: classify(parse(cmd)).
classify_ir() {
  run_with_timeout 30 node -e "const {classify}=require('${WT_NODE}/hooks/lib/bash-write-patterns'); const {parse}=require('${WT_NODE}/hooks/lib/command-ir'); process.stdout.write(classify(parse(process.argv[1])))" -- "$1" 2>/dev/null
}

report_totals() {
  echo ""
  echo "Totals[$(basename "${BASH_SOURCE[1]:-part}")]: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
}

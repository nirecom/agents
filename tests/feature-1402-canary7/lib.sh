#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-targets/here.js, hooks/lib/bash-write-targets/encoded.js, hooks/lib/bash-write-targets/file-op.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: scope:issue-specific, canary-7, ir-migration, test-helper, pwsh-not-required
# Shared helpers + node bridges for the canary-7 IR migration parts.
# Sourced by each part; NOT run standalone. Contract: $1 = WORKTREE root.
#
# RED-pending (#1402 write-tests): here.js, encoded.js, file-op.js do NOT exist yet.
# Bridges guard require()/typeof and emit "ERROR:no-module" / "ERROR:not-exported"
# so the harness records a clean FAIL (not an uncaught exception crash).

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

# classify_ir <cmd> → "read"|"write". Production classify(parse(cmd)).
classify_ir() {
  run_with_timeout 30 node -e "
    const {classify}=require('${WT_NODE}/hooks/lib/bash-write-patterns');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    process.stdout.write(classify(parse(process.argv[1])));
  " -- "$1" 2>/dev/null
}

# here_write_ir <cmd> → "true"|"false"|"ERROR:*". isHereWriteIR from here.js.
here_write_ir() {
  run_with_timeout 30 node -e "
    let m; try { m=require('${WT_NODE}/hooks/lib/bash-write-targets/here'); }
    catch (e) { process.stdout.write('ERROR:no-module'); process.exit(0); }
    if (typeof m.isHereWriteIR !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(m.isHereWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# encoded_write_ir <cmd> → "true"|"false"|"ERROR:*". isEncodedCommandWriteIR from encoded.js.
encoded_write_ir() {
  run_with_timeout 30 node -e "
    let m; try { m=require('${WT_NODE}/hooks/lib/bash-write-targets/encoded'); }
    catch (e) { process.stdout.write('ERROR:no-module'); process.exit(0); }
    if (typeof m.isEncodedCommandWriteIR !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(m.isEncodedCommandWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# file_op_write_ir <cmd> → "true"|"false"|"ERROR:*". isExtendedFileOpWriteIR from file-op.js.
file_op_write_ir() {
  run_with_timeout 30 node -e "
    let m; try { m=require('${WT_NODE}/hooks/lib/bash-write-targets/file-op'); }
    catch (e) { process.stdout.write('ERROR:no-module'); process.exit(0); }
    if (typeof m.isExtendedFileOpWriteIR !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(m.isExtendedFileOpWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# file_op_targets <cmd> → JSON array string|"null"|"ERROR:*". extractFileOpTargets from file-op.js.
file_op_targets() {
  run_with_timeout 30 node -e "
    let m; try { m=require('${WT_NODE}/hooks/lib/bash-write-targets/file-op'); }
    catch (e) { process.stdout.write('ERROR:no-module'); process.exit(0); }
    if (typeof m.extractFileOpTargets !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try {
      const result=m.extractFileOpTargets(parse(process.argv[1]));
      process.stdout.write(result===null?'null':JSON.stringify(result));
    } catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# here_module_present → 0 when here.js exports isHereWriteIR function, else 1.
here_module_present() {
  local r
  r="$(run_with_timeout 30 node -e "
    try { const m=require('${WT_NODE}/hooks/lib/bash-write-targets/here'); process.stdout.write(typeof m.isHereWriteIR==='function'?'yes':'no'); }
    catch (e) { process.stdout.write('no'); }
  " 2>/dev/null)"
  [ "$r" = "yes" ]
}

# encoded_module_present → 0 when encoded.js exports isEncodedCommandWriteIR, else 1.
encoded_module_present() {
  local r
  r="$(run_with_timeout 30 node -e "
    try { const m=require('${WT_NODE}/hooks/lib/bash-write-targets/encoded'); process.stdout.write(typeof m.isEncodedCommandWriteIR==='function'?'yes':'no'); }
    catch (e) { process.stdout.write('no'); }
  " 2>/dev/null)"
  [ "$r" = "yes" ]
}

# file_op_module_present → 0 when file-op.js exports isExtendedFileOpWriteIR, else 1.
file_op_module_present() {
  local r
  r="$(run_with_timeout 30 node -e "
    try { const m=require('${WT_NODE}/hooks/lib/bash-write-targets/file-op'); process.stdout.write(typeof m.isExtendedFileOpWriteIR==='function'?'yes':'no'); }
    catch (e) { process.stdout.write('no'); }
  " 2>/dev/null)"
  [ "$r" = "yes" ]
}

# pwsh_write_ir <cmd> → "true"|"false". isPwshWriteIR from bash-write-targets.js.
pwsh_write_ir() {
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/lib/bash-write-targets');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(m.isPwshWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# interp_c_write_ir <cmd> → "true"|"false"|"ERROR:*". isInterpreterCWriteIR from bash-write-targets.js.
interp_c_write_ir() {
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/lib/bash-write-targets');
    if (typeof m.isInterpreterCWriteIR !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(m.isInterpreterCWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

report_totals() {
  echo ""
  echo "Totals[$(basename "${BASH_SOURCE[1]:-part}")]: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
}

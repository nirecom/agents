#!/usr/bin/env bash
# tests/feature-canary5-6git/lib.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/enforce-worktree/bash-write-scope.js
# Tags: enforce-worktree, test-helper, scope:issue-specific, pwsh-not-required
# Shared helpers + node bridges for the canary5-6git suite parts.
# Sourced by each partN-*.sh; NOT run standalone.
#
# Contract: $1 = WORKTREE root (agents repo). All node require() targets resolve
# here. Each part sources this file, runs assert_eq / assert cases, and exits $FAIL.
#
# Pre-implementation (WF-CODE / write-tests): several APIs under test (isGitWriteIR,
# extractGitWriteTargets, resolveGitSubArgv, isPosixRedirWriteIR, isPwshWriteIR,
# isFileOpWriteIR, the typed {resolveVia,path} target shape, the two-arg
# collectBashWriteTargets(ir,repoRoot) contract) do NOT exist yet. The RED-pending
# bridges guard require()/typeof and emit "ERROR:<why>" instead of crashing so the
# harness records a clean FAIL rather than aborting the whole run.

set -uo pipefail

# Git Bash / MSYS2 rewrites POSIX-looking argv (e.g. `/usr/bin/git`) into Windows
# paths before exec, which corrupts command strings passed to the node bridges as
# test fixtures (a path-qualified `git` would gain a space and lose its basename).
# Disable the conversion so bridges receive the RAW command string the hooks see
# in production. No-op on non-MSYS platforms.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

PASS=0; FAIL=0; SKIP=0

# Worktree root — passed by the dispatcher as $1; fall back to two-levels-up.
WORKTREE="${1:-}"
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found — skipping tests"; exit 77; }

# Node-friendly (forward-slash) worktree path for require() strings.
if command -v cygpath >/dev/null 2>&1; then
  WT_NODE="$(cygpath -m "$WORKTREE")"
else
  WT_NODE="$WORKTREE"
fi
GUARD_JS="${WT_NODE}/hooks/enforce-worktree.js"

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
  fi
}
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# ---------------------------------------------------------------------------
# classify / IR-predicate bridges. classify() accepts an IR object (parse())
# or a raw string — production path passes parse(cmd), so we mirror that.
# ---------------------------------------------------------------------------

# classify_ir <cmd> → "read"|"write".
classify_ir() {
  run_with_timeout 30 node -e "const {classify}=require('${WT_NODE}/hooks/lib/bash-write-patterns'); const {parse}=require('${WT_NODE}/hooks/lib/command-ir'); process.stdout.write(classify(parse(process.argv[1])))" -- "$1" 2>/dev/null
}

# isReadOnlyInterpreterC <cmd> → "true"|"false" (string-arg API).
ro_interp_c() {
  run_with_timeout 30 node -e "const {isReadOnlyInterpreterC}=require('${WT_NODE}/hooks/lib/bash-write-patterns'); process.stdout.write(String(isReadOnlyInterpreterC(process.argv[1])))" -- "$1" 2>/dev/null
}

# ---- RED-pending green-group IR predicates (Commit 2). ---------------------
# isPosixRedirWriteIR / isPwshWriteIR / isFileOpWriteIR are added by the impl to
# hooks/lib/bash-write-targets.js. Pre-impl they are undefined → the typeof guard
# emits "ERROR:not-exported" so the assertion FAILs cleanly (RED-pending).
green_pred() {
  local fn="$1" cmd="$2"
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/lib/bash-write-targets');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    const fn=m['$fn'];
    if (typeof fn !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    try { process.stdout.write(String(fn(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$cmd" 2>/dev/null
}

# ---- RED-pending git IR predicate (Commit 3). ------------------------------
# isGitWriteIR is added to hooks/lib/bash-write-patterns/patterns.js.
git_write_ir() {
  local cmd="$1"
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    if (typeof m.isGitWriteIR !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    try { process.stdout.write(String(m.isGitWriteIR(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$cmd" 2>/dev/null
}

# ---- WRITE_PATTERNS / STRIP_KINDS structural probes. -----------------------
# kind_count <kind> → number of WRITE_PATTERNS entries with that kind.
kind_count() {
  run_with_timeout 30 node -e "const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns'); process.stdout.write(String(WRITE_PATTERNS.filter(p=>p.kind===process.argv[1]).length))" -- "$1" 2>/dev/null
}
# strip_has <kind> → "true"|"false".
strip_has() {
  run_with_timeout 30 node -e "const {STRIP_KINDS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns'); process.stdout.write(String(STRIP_KINDS.has(process.argv[1])))" -- "$1" 2>/dev/null
}

# ---- collectWriteTargetsFromSegments typed-shape probe (Commit 1). ---------
# collect_first_target <cmd> → JSON of the FIRST collected target (object or
# scalar). Post-impl this is {"resolveVia":"ancestor","path":"..."}; pre-impl it
# is the bare string "..." → the assertion FAILs (RED-pending).
collect_first_target() {
  run_with_timeout 30 node -e "
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    const {collectWriteTargetsFromSegments}=require('${WT_NODE}/hooks/lib/bash-write-targets');
    const segs=parse(process.argv[1]).segments;
    const out=collectWriteTargetsFromSegments(segs);
    if (!out.targets || out.targets.length===0) { process.stdout.write('null'); process.exit(0); }
    process.stdout.write(JSON.stringify(out.targets[0]));
  " -- "$1" 2>/dev/null
}

# ---- string-API extractor pins (must stay bare arrays — D1). ---------------
call_extractor_str() {
  local mod="$1" fn="$2" cmd="$3"
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/lib/bash-write-targets/$mod');
    process.stdout.write(JSON.stringify(m['$fn'](process.argv[1])));
  " -- "$cmd" 2>/dev/null
}

# ---- L2 hook-boundary driver (matches fix-1391 Section D). -----------------
# run_bash_guard <cmd> <cwd> [ENV=val ...] → raw hook decision JSON on stdout.
run_bash_guard() {
  local cmd="$1"; shift
  local cwd="$1"; shift
  local payload
  payload="$(run_with_timeout 30 node -e "
    const j={ session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
    console.log(JSON.stringify(j));
  " -- "$cmd" 2>/dev/null)"
  (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
}

# TMP fixture root (Windows-safe forward-slash path).
mk_tmp_root() {
  local tag="$1"
  local d
  d="$(run_with_timeout 30 node -e "
    const os=require('os'),path=require('path'),fs=require('fs');
    const d=path.join(os.tmpdir(),'canary56-'+process.argv[1]+'-'+process.pid).replace(/\\\\/g,'/');
    fs.mkdirSync(d,{recursive:true}); console.log(d);
  " -- "$tag" 2>/dev/null)"
  [ -z "$d" ] && d="$(mktemp -d)"
  echo "$d"
}

# setup a main-worktree git repo under $1 (base dir) named $2 → prints node path.
setup_main_checkout() {
  local base="$1" name="$2"
  local repo="$base/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config core.hooksPath /dev/null
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q --no-verify -m "initial"
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$repo"; else echo "$repo"; fi
}

report_totals() {
  echo ""
  echo "Totals[$(basename "${BASH_SOURCE[1]:-part}")]: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
}

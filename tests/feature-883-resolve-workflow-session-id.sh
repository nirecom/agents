#!/bin/bash
# tests/feature-883-resolve-workflow-session-id.sh
# Tests: hooks/lib/resolve-workflow-session-id.js
# Tags: supervisor, em-supervisor, session-id, workflow-state, layer2
# RED for issue #883.
# L3 gap (what this test does NOT catch):
# - tests invoke resolveWorkflowSessionId() directly via node -e rather than
#   exercising the full Stop hook (supervisor-guard.js); end-to-end wiring of the
#   resolver into the block-reason injection path is covered by G20/G21 in
#   feature-719-supervisor-guard-hook.sh, not here.
# - real ~/.workflow-plans/ directory layout differences — tests use temp dirs,
#   so OS-specific quirks (e.g. SMB share mtime resolution) are not exercised.
# Closest-to-action mitigation: hook-registration / skill-orchestration categories
#   in bin/check-verification-gate.sh fire at WORKFLOW_USER_VERIFIED preflight
#   when supervisor-guard.js / workflow-state.js changes are staged.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

RESOLVE_WSID_NODE="$_AGENTS_DIR_NODE/hooks/lib/resolve-workflow-session-id.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_function() {
    local fn="$1" label="$2"
    node -e "const m=require('$RESOLVE_WSID_NODE'); if(typeof m['$fn']!=='function') process.exit(1);" 2>/dev/null
    if [ $? -ne 0 ]; then skip "$label (resolveWorkflowSessionId not implemented yet)"; return 1; fi
    return 0
}

# Today's local date as YYYYMMDD (used by date-sanity guard).
TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)
YESTERDAY=$(node -e "const d=new Date(Date.now()-86400000); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)

# Invoke resolveWorkflowSessionId({}) with WORKFLOW_PLANS_DIR=$1 and (optional) CLAUDE_ENV_FILE=$2.
# Stdout: 'NULL' or the resolved sid.
call_resolve() {
    local plans_dir="$1" env_file="${2:-}"
    if [ -n "$env_file" ]; then
        WORKFLOW_PLANS_DIR="$plans_dir" CLAUDE_ENV_FILE="$env_file" \
            run_with_timeout 5 node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null
    else
        # Explicitly unset CLAUDE_ENV_FILE so a leaked env var from the host shell
        # cannot influence the test outcome.
        WORKFLOW_PLANS_DIR="$plans_dir" \
            run_with_timeout 5 env -u CLAUDE_ENV_FILE node -e "
const m = require('$RESOLVE_WSID_NODE');
const r = m.resolveWorkflowSessionId({});
process.stdout.write(r == null ? 'NULL' : r);
" 2>/dev/null
    fi
}

# Set mtime on a list of files: pairs of (path, offset-seconds-from-now).
set_mtimes() {
    # Args: path1 offset1 path2 offset2 ...
    node -e "
const fs = require('fs');
const args = process.argv.slice(1);
const now = Date.now() / 1000;
for (let i = 0; i < args.length; i += 2) {
    const p = args[i];
    const off = parseFloat(args[i+1]);
    const t = now + off;
    fs.utimesSync(p, t, t);
}
" -- "$@" 2>/dev/null
}

run_r1() {
    require_function "resolveWorkflowSessionId" "R1: env+intent happy path" || return
    local tmp out envfile
    tmp="$(mktemp -d)"
    envfile="$tmp/claude.env"
    echo "CLAUDE_SESSION_ID=cc-uuid" > "$envfile"
    : > "$tmp/cc-uuid-intent.md"
    out=$(call_resolve "$tmp" "$envfile")
    rm -rf "$tmp"
    if [ "$out" = "cc-uuid" ]; then
        pass "R1: env+intent happy path"
    else
        fail "R1: env+intent happy path (out=$out)"
    fi
}

run_r2() {
    require_function "resolveWorkflowSessionId" "R2: env present but no intent.md -> context.md scan" || return
    local tmp out envfile
    tmp="$(mktemp -d)"
    envfile="$tmp/claude.env"
    echo "CLAUDE_SESSION_ID=cc-uuid" > "$envfile"
    # NOTE: no cc-uuid-intent.md — force fallthrough to mtime scan.
    : > "$tmp/${TODAY}-early-context.md"
    : > "$tmp/${TODAY}-later-context.md"
    set_mtimes "$tmp/${TODAY}-early-context.md" -4 "$tmp/${TODAY}-later-context.md" -2
    out=$(call_resolve "$tmp" "$envfile")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-later" ]; then
        pass "R2: env present but no intent.md -> context.md scan"
    else
        fail "R2: env present but no intent.md -> context.md scan (out=$out)"
    fi
}

run_r3() {
    require_function "resolveWorkflowSessionId" "R3: single same-day context.md" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-001252-context.md"
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-001252" ]; then
        pass "R3: single same-day context.md"
    else
        fail "R3: single same-day context.md (out=$out)"
    fi
}

run_r4() {
    require_function "resolveWorkflowSessionId" "R4: multiple same-day by mtime" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-a-context.md"
    : > "$tmp/${TODAY}-b-context.md"
    : > "$tmp/${TODAY}-c-context.md"
    # b is newest (T-2); a is T-6; c is T-4.
    set_mtimes \
        "$tmp/${TODAY}-a-context.md" -6 \
        "$tmp/${TODAY}-b-context.md" -2 \
        "$tmp/${TODAY}-c-context.md" -4
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-b" ]; then
        pass "R4: multiple same-day by mtime"
    else
        fail "R4: multiple same-day by mtime (out=$out)"
    fi
}

run_r5() {
    require_function "resolveWorkflowSessionId" "R5: empty plans-dir -> null" || return
    local tmp out
    tmp="$(mktemp -d)"
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R5: empty plans-dir -> null"
    else
        fail "R5: empty plans-dir -> null (out=$out)"
    fi
}

run_r6() {
    require_function "resolveWorkflowSessionId" "R6: nonexistent plans-dir -> null (no throw)" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Point at a path that does not exist.
    local bogus="$tmp/does-not-exist"
    out=$(call_resolve "$bogus")
    rm -rf "$tmp"
    if [ "$out" = "NULL" ]; then
        pass "R6: nonexistent plans-dir -> null (no throw)"
    else
        fail "R6: nonexistent plans-dir -> null (no throw) (out=$out)"
    fi
}

run_r7() {
    require_function "resolveWorkflowSessionId" "R7: adversarial filename blocked by charset validator" || return
    local tmp out
    tmp="$(mktemp -d)"
    # '..' has dots — fails /^[A-Za-z0-9_-]+$/. Must NOT be returned.
    : > "$tmp/..-context.md"
    : > "$tmp/${TODAY}-good-context.md"
    set_mtimes \
        "$tmp/..-context.md" -2 \
        "$tmp/${TODAY}-good-context.md" -4
    # Note: even though '..' has newer mtime, the charset validator should drop it,
    # leaving only ${TODAY}-good as a valid candidate.
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-good" ]; then
        pass "R7: adversarial filename blocked by charset validator"
    else
        fail "R7: adversarial filename blocked by charset validator (out=$out)"
    fi
}

run_r8() {
    require_function "resolveWorkflowSessionId" "R8: date-sanity guard excludes yesterday file" || return
    local tmp out
    tmp="$(mktemp -d)"
    : > "$tmp/${TODAY}-090000-context.md"
    : > "$tmp/${TODAY}-100000-context.md"
    : > "$tmp/${YESTERDAY}-235959-context.md"
    # Yesterday file has the newest mtime (most recent), but date-sanity must exclude it.
    # Within today's files, 100000 wins on mtime (T-4 > T-6).
    set_mtimes \
        "$tmp/${TODAY}-090000-context.md" -6 \
        "$tmp/${TODAY}-100000-context.md" -4 \
        "$tmp/${YESTERDAY}-235959-context.md" -2
    out=$(call_resolve "$tmp")
    rm -rf "$tmp"
    if [ "$out" = "${TODAY}-100000" ]; then
        pass "R8: date-sanity guard excludes yesterday file"
    else
        fail "R8: date-sanity guard excludes yesterday file (out=$out)"
    fi
}

run_r1
run_r2
run_r3
run_r4
run_r5
run_r6
run_r7
run_r8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

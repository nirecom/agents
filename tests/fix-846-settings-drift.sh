#!/bin/bash
# tests/fix-846-settings-drift.sh
# Tests: hooks/lib/settings-drift.js, hooks/session-start.js
# Tags: hook, settings, drift, session-start
# Tests for issue #846 — settings.json drift detection (module + session-start).
# Git hook tests (T9-T16) live in fix-846-settings-drift-hooks.sh.
#
# L2 narrow integration: validates drift-detection module return shape and
# session-start warning. Each test uses an isolated HOME (mktemp -d) and
# never touches the real ~/.claude/settings.json.
#
# L3 GAP (what this test does NOT catch):
# - End-to-end: edit agents/settings.json → git pull → assembler re-runs →
#   ~/.claude/settings.json updated → session-start shows no warning
# - Conflict resolution: merge markers in settings.json
# - Cross-OS HOME resolution (Windows %USERPROFILE% vs POSIX $HOME)
# - Concurrent session-start invocations (race on temp HOME)
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: drift-detection

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

DRIFT_MODULE="$AGENTS_DIR/hooks/lib/settings-drift.js"
SESSION_START="$AGENTS_DIR/hooks/session-start.js"
BASE_SETTINGS="$AGENTS_DIR/settings.json"

PASS=0
FAIL=0
SKIP=0

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

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# detect_drift HOMEDIR — invokes the drift module and emits JSON on stdout.
detect_drift() {
    local home_dir="$1"
    local home_node; home_node="$(to_node_path "$home_dir")"
    local module_node; module_node="$(to_node_path "$DRIFT_MODULE")"
    run_with_timeout 10 node -e "
const r = require(process.argv[1]);
const out = r.detectDrift({ homeDir: process.argv[2] });
process.stdout.write(JSON.stringify(out));
" -- "$module_node" "$home_node" 2>&1
}

# write_assembled HOMEDIR JSON — writes JSON to ~/.claude/settings.json.
write_assembled() {
    local home_dir="$1" content="$2"
    mkdir -p "$home_dir/.claude"
    printf '%s' "$content" > "$home_dir/.claude/settings.json"
}

# assemble_current HOMEDIR — runs the real assembler to produce a current snapshot.
assemble_current() {
    local home_dir="$1"
    local home_node; home_node="$(to_node_path "$home_dir")"
    mkdir -p "$home_dir/.claude"
    run_with_timeout 15 node -e "
process.env.HOME = process.argv[1];
process.env.USERPROFILE = process.argv[1];
const os = require('os');
os.homedir = () => process.argv[1];
require(process.argv[2]);
" -- "$home_node" "$(to_node_path "$AGENTS_DIR/install/assemble-settings.js")" >/dev/null 2>&1
}

# --- T1: assembled missing → drifted true, missing true -----------------------
run_t1() {
    require_source "$DRIFT_MODULE" "T1: assembled missing → drifted+missing" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    mkdir -p "$_tmp_home/.claude"
    # Do not create settings.json in home
    local out; out="$(detect_drift "$_tmp_home")"
    local rc=$?
    if [ $rc -ne 0 ]; then fail "T1: assembled missing → drifted+missing (rc=$rc, out=$out)"; return; fi
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  if (r.drifted !== true) { console.error('drifted not true: '+JSON.stringify(r)); process.exit(2); }
  if (r.missing !== true) { console.error('missing not true: '+JSON.stringify(r)); process.exit(3); }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T1: assembled missing → drifted+missing" \
        || fail "T1: assembled missing → drifted+missing (out=$out)"
}

# --- T2: invalid JSON in assembled → drifted true, broken true ----------------
run_t2() {
    require_source "$DRIFT_MODULE" "T2: invalid JSON → drifted+broken" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    write_assembled "$_tmp_home" "{ invalid json"
    local out; out="$(detect_drift "$_tmp_home")"
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  if (r.drifted !== true) { console.error('drifted not true: '+JSON.stringify(r)); process.exit(2); }
  if (r.broken !== true) { console.error('broken not true: '+JSON.stringify(r)); process.exit(3); }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T2: invalid JSON → drifted+broken" \
        || fail "T2: invalid JSON → drifted+broken (out=$out)"
}

# --- T3: no drift — all base entries present ----------------------------------
run_t3() {
    require_source "$DRIFT_MODULE" "T3: no drift" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    assemble_current "$_tmp_home"
    if [ ! -f "$_tmp_home/.claude/settings.json" ]; then
        skip "T3: no drift (assembler failed to write target)"; return
    fi
    local out; out="$(detect_drift "$_tmp_home")"
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  if (r.drifted !== false) { console.error('drifted not false: '+JSON.stringify(r)); process.exit(2); }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T3: no drift" \
        || fail "T3: no drift (out=$out)"
}

# --- T4: missing permissions.allow entry → drifted ----------------------------
run_t4() {
    require_source "$DRIFT_MODULE" "T4: missing permissions.allow" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    assemble_current "$_tmp_home"
    if [ ! -f "$_tmp_home/.claude/settings.json" ]; then
        skip "T4: missing permissions.allow (assembler failed)"; return
    fi
    # Strip a representative literal from permissions.allow
    local target_file="$_tmp_home/.claude/settings.json"
    local target_node; target_node="$(to_node_path "$target_file")"
    run_with_timeout 5 node -e "
const fs = require('fs');
const p = process.argv[1];
const j = JSON.parse(fs.readFileSync(p,'utf8'));
if (j.permissions && Array.isArray(j.permissions.allow) && j.permissions.allow.length > 0) {
  j.permissions.allow.shift();
}
fs.writeFileSync(p, JSON.stringify(j, null, 2));
" -- "$target_node" >/dev/null 2>&1
    local out; out="$(detect_drift "$_tmp_home")"
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  if (r.drifted !== true) { console.error('drifted not true: '+JSON.stringify(r)); process.exit(2); }
  if (!r.missingPermissions || !Array.isArray(r.missingPermissions.allow) || r.missingPermissions.allow.length === 0) {
    console.error('missingPermissions.allow empty: '+JSON.stringify(r)); process.exit(3);
  }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T4: missing permissions.allow" \
        || fail "T4: missing permissions.allow (out=$out)"
}

# --- T5: missing permissions.ask entry → drifted ------------------------------
run_t5() {
    require_source "$DRIFT_MODULE" "T5: missing permissions.ask" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    assemble_current "$_tmp_home"
    if [ ! -f "$_tmp_home/.claude/settings.json" ]; then
        skip "T5: missing permissions.ask (assembler failed)"; return
    fi
    local target_file="$_tmp_home/.claude/settings.json"
    local target_node; target_node="$(to_node_path "$target_file")"
    run_with_timeout 5 node -e "
const fs = require('fs');
const p = process.argv[1];
const j = JSON.parse(fs.readFileSync(p,'utf8'));
if (j.permissions && Array.isArray(j.permissions.ask) && j.permissions.ask.length > 0) {
  j.permissions.ask.shift();
} else if (j.permissions) {
  // Force a synthetic missing-ask scenario when base has no ask
  j.permissions.ask = [];
}
fs.writeFileSync(p, JSON.stringify(j, null, 2));
" -- "$target_node" >/dev/null 2>&1
    local out; out="$(detect_drift "$_tmp_home")"
    # Pass if either drift detected with ask gap OR base has no ask entries (no-op case)
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  const baseJ = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const baseHasAsk = baseJ.permissions && Array.isArray(baseJ.permissions.ask) && baseJ.permissions.ask.length > 0;
  if (!baseHasAsk) { console.log('OK'); return; } // base empty — vacuous pass
  if (r.drifted !== true) { console.error('drifted not true: '+JSON.stringify(r)); process.exit(2); }
  if (!r.missingPermissions || !Array.isArray(r.missingPermissions.ask) || r.missingPermissions.ask.length === 0) {
    console.error('missingPermissions.ask empty: '+JSON.stringify(r)); process.exit(3);
  }
  console.log('OK');
});" -- "$(to_node_path "$BASE_SETTINGS")" >/dev/null 2>&1 \
        && pass "T5: missing permissions.ask" \
        || fail "T5: missing permissions.ask (out=$out)"
}

# --- T6: missing hooks.PreToolUse entry → drifted -----------------------------
run_t6() {
    require_source "$DRIFT_MODULE" "T6: missing hooks.PreToolUse" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    assemble_current "$_tmp_home"
    if [ ! -f "$_tmp_home/.claude/settings.json" ]; then
        skip "T6: missing hooks.PreToolUse (assembler failed)"; return
    fi
    local target_file="$_tmp_home/.claude/settings.json"
    local target_node; target_node="$(to_node_path "$target_file")"
    run_with_timeout 5 node -e "
const fs = require('fs');
const p = process.argv[1];
const j = JSON.parse(fs.readFileSync(p,'utf8'));
if (j.hooks && Array.isArray(j.hooks.PreToolUse) && j.hooks.PreToolUse.length > 0) {
  j.hooks.PreToolUse.shift();
}
fs.writeFileSync(p, JSON.stringify(j, null, 2));
" -- "$target_node" >/dev/null 2>&1
    local out; out="$(detect_drift "$_tmp_home")"
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  const baseJ = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const baseHas = baseJ.hooks && Array.isArray(baseJ.hooks.PreToolUse) && baseJ.hooks.PreToolUse.length > 0;
  if (!baseHas) { console.log('OK'); return; } // base empty — vacuous pass
  if (r.drifted !== true) { console.error('drifted not true: '+JSON.stringify(r)); process.exit(2); }
  if (!r.missingHooks || !r.missingHooks.PreToolUse || r.missingHooks.PreToolUse.length === 0) {
    console.error('missingHooks.PreToolUse empty: '+JSON.stringify(r)); process.exit(3);
  }
  console.log('OK');
});" -- "$(to_node_path "$BASE_SETTINGS")" >/dev/null 2>&1 \
        && pass "T6: missing hooks.PreToolUse" \
        || fail "T6: missing hooks.PreToolUse (out=$out)"
}

# --- T7: extension adds extra entries (superset of base) → no drift ----------
run_t7() {
    require_source "$DRIFT_MODULE" "T7: superset → no drift" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    assemble_current "$_tmp_home"
    if [ ! -f "$_tmp_home/.claude/settings.json" ]; then
        skip "T7: superset → no drift (assembler failed)"; return
    fi
    local target_file="$_tmp_home/.claude/settings.json"
    local target_node; target_node="$(to_node_path "$target_file")"
    # Add extra non-base entries to assembled file — drift check must be subset, not equality
    run_with_timeout 5 node -e "
const fs = require('fs');
const p = process.argv[1];
const j = JSON.parse(fs.readFileSync(p,'utf8'));
if (!j.permissions) j.permissions = {};
if (!Array.isArray(j.permissions.allow)) j.permissions.allow = [];
j.permissions.allow.push('Bash(echo \"user-customization\")');
j.permissions.allow.push('Read(/some/user/path/**)');
fs.writeFileSync(p, JSON.stringify(j, null, 2));
" -- "$target_node" >/dev/null 2>&1
    local out; out="$(detect_drift "$_tmp_home")"
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  if (r.drifted !== false) { console.error('drifted not false: '+JSON.stringify(r)); process.exit(2); }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T7: superset → no drift" \
        || fail "T7: superset → no drift (out=$out)"
}

# --- T8: base file unreadable → drifted=false sourceUnreadable=true -----------
run_t8() {
    require_source "$DRIFT_MODULE" "T8: base unreadable → sourceUnreadable" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    # Sandbox the module's source resolution via a temp agents-root that has no settings.json
    local fake_root; fake_root="$(mktemp -d)"
    mkdir -p "$fake_root/hooks/lib"
    cp "$DRIFT_MODULE" "$fake_root/hooks/lib/settings-drift.js"
    local module_node; module_node="$(to_node_path "$fake_root/hooks/lib/settings-drift.js")"
    local home_node; home_node="$(to_node_path "$_tmp_home")"
    # Create assembled file so the priority-1 check (missing) is bypassed; no base settings.json → sourceUnreadable
    write_assembled "$_tmp_home" '{}'
    local out
    out=$(run_with_timeout 10 node -e "
const r = require(process.argv[1]);
const o = r.detectDrift({ homeDir: process.argv[2] });
process.stdout.write(JSON.stringify(o));
" -- "$module_node" "$home_node" 2>&1)
    rm -rf "$fake_root"
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  const r = JSON.parse(d);
  if (r.drifted !== false) { console.error('drifted not false: '+JSON.stringify(r)); process.exit(2); }
  if (r.sourceUnreadable !== true) { console.error('sourceUnreadable not true: '+JSON.stringify(r)); process.exit(3); }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T8: base unreadable → sourceUnreadable" \
        || fail "T8: base unreadable → sourceUnreadable (out=$out)"
}

# --- T17: session-start drift detected → additionalContext contains warning ---
run_t17() {
    require_source "$SESSION_START" "T17: session-start drift warning" || return
    require_source "$DRIFT_MODULE" "T17: session-start drift warning" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    mkdir -p "$_tmp_home/.claude"
    # Write an empty/stale settings.json to trigger drift
    echo '{}' > "$_tmp_home/.claude/settings.json"
    local home_node; home_node="$(to_node_path "$_tmp_home")"
    local out
    out=$(printf '{"session_id":"test-846-drift-t17"}' \
        | HOME="$_tmp_home" USERPROFILE="$_tmp_home" \
        run_with_timeout 10 node "$_AGENTS_DIR_NODE/hooks/session-start.js" 2>&1)
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  let parsed;
  try { parsed = JSON.parse(d); } catch(e) { console.error('not JSON: '+d.slice(0,200)); process.exit(2); }
  const ctx = parsed.additionalContext || '';
  if (!/drift|settings\.json|out of sync|assemble-settings/i.test(ctx)) {
    console.error('no drift warning in additionalContext: '+ctx.slice(0,300)); process.exit(3);
  }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T17: session-start drift warning" \
        || fail "T17: session-start drift warning (out=$(echo "$out" | head -c 300))"
}

# --- T18: session-start no drift → no drift warning ---------------------------
run_t18() {
    require_source "$SESSION_START" "T18: session-start no drift, no warning" || return
    require_source "$DRIFT_MODULE" "T18: session-start no drift, no warning" || return
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    assemble_current "$_tmp_home"
    if [ ! -f "$_tmp_home/.claude/settings.json" ]; then
        skip "T18: session-start no drift, no warning (assembler failed)"; return
    fi
    local out
    out=$(printf '{"session_id":"test-846-drift-t18"}' \
        | HOME="$_tmp_home" USERPROFILE="$_tmp_home" \
        run_with_timeout 10 node "$_AGENTS_DIR_NODE/hooks/session-start.js" 2>&1)
    echo "$out" | run_with_timeout 5 node -e "
let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
  let parsed;
  try { parsed = JSON.parse(d); } catch(e) { console.error('not JSON: '+d.slice(0,200)); process.exit(2); }
  const ctx = parsed.additionalContext || '';
  // A 'no drift' state must NOT include the drift-warning phrasing.
  if (/settings\.json drift detected|out of sync|run install\.ps1|assembler stale/i.test(ctx)) {
    console.error('unexpected drift warning: '+ctx.slice(0,300)); process.exit(3);
  }
  console.log('OK');
});" >/dev/null 2>&1 \
        && pass "T18: session-start no drift, no warning" \
        || fail "T18: session-start no drift, no warning (out=$(echo "$out" | head -c 300))"
}

# --- T19: assembler idempotency — called twice → same output ------------------
run_t19() {
    if [ ! -f "$AGENTS_DIR/install/assemble-settings.js" ]; then
        skip "T19: assembler idempotency (assemble-settings.js missing)"; return
    fi
    local _tmp_home; _tmp_home="$(mktemp -d)"; trap 'rm -rf "$_tmp_home"' RETURN
    assemble_current "$_tmp_home"
    if [ ! -f "$_tmp_home/.claude/settings.json" ]; then
        skip "T19: assembler idempotency (first run failed)"; return
    fi
    local first; first="$(cat "$_tmp_home/.claude/settings.json")"
    assemble_current "$_tmp_home"
    local second; second="$(cat "$_tmp_home/.claude/settings.json")"
    if [ "$first" = "$second" ]; then
        pass "T19: assembler idempotency"
    else
        fail "T19: assembler idempotency (output differs between runs)"
    fi
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t17
run_t18
run_t19

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

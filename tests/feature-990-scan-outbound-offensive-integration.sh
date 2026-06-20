#!/bin/bash
# tests/feature-990-scan-outbound-offensive-integration.sh
# Tests: hooks/scan-outbound.js, bin/scan-offensive
# Tags: scan, offensive, outbound, hook, integration, scope:issue-specific
# RED for issue #990 — scan-outbound.js must call bin/scan-offensive OUTSIDE
# the private-repo skip branch.
#
# L3 gap (what this test does NOT catch):
# - real Claude Code session loading the modified hook from settings.json
# - real `gh issue create` end-to-end against GitHub API (covered by manual smoke)
#
# Strategy: we cannot test the real bin/scan-offensive integration without it
# existing. We use a shim sandbox: copy hooks/scan-outbound.js + its lib deps
# into a temp dir, place a stub bin/scan-offensive that exits with a controlled
# code, then invoke the hook with crafted JSON. This validates the integration
# wiring (hook calls scan-offensive; offensive scan applies regardless of repo
# privacy).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SRC="$AGENTS_DIR/hooks/scan-outbound.js"

if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PASS=0; FAIL=0; SKIP=0
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

require_hook() {
    if [ ! -f "$HOOK_SRC" ]; then
        skip "$1 (hooks/scan-outbound.js not present)"
        return 1
    fi
    return 0
}

build_sandbox_full() {
    local sandbox="$1" ob_exit="$2" sf_exit="$3"
    mkdir -p "$sandbox/hooks/lib" "$sandbox/bin"
    cp "$HOOK_SRC" "$sandbox/hooks/scan-outbound.js"
    cp -r "$AGENTS_DIR/hooks/lib/." "$sandbox/hooks/lib/" 2>/dev/null || true
    cat > "$sandbox/bin/scan-outbound.sh" <<STUBSH
#!/bin/bash
exit ${ob_exit}
STUBSH
    chmod +x "$sandbox/bin/scan-outbound.sh"
    cat > "$sandbox/bin/scan-offensive" <<STUBJS
#!/usr/bin/env node
process.exit(${sf_exit});
STUBJS
    chmod +x "$sandbox/bin/scan-offensive"
}

# Build a sandbox layout: $SANDBOX/{hooks,bin,lib}
build_sandbox() {
    local sandbox="$1" sf_exit="$2"
    mkdir -p "$sandbox/hooks/lib" "$sandbox/bin"
    cp "$HOOK_SRC" "$sandbox/hooks/scan-outbound.js"
    # Copy all hooks/lib files used by scan-outbound.js
    cp -r "$AGENTS_DIR/hooks/lib/." "$sandbox/hooks/lib/" 2>/dev/null || true
    # Provide a stub bin/scan-outbound.sh that always exits 0 (clean).
    cat > "$sandbox/bin/scan-outbound.sh" <<'SH'
#!/bin/bash
# stub scan-outbound.sh — always clean
exit 0
SH
    chmod +x "$sandbox/bin/scan-outbound.sh"
    # Stub bin/scan-offensive that exits with the requested code (Node.js so
    # scan-outbound.js can invoke it via node without a bash-syntax error).
    cat > "$sandbox/bin/scan-offensive" <<SH
#!/usr/bin/env node
process.stderr.write("stub scan-offensive (rc=${sf_exit}) called\\n");
process.exit(${sf_exit});
SH
    chmod +x "$sandbox/bin/scan-offensive"
}

# Run the sandboxed hook with given JSON input.
# stdout is the hook's JSON decision.
run_sandboxed_hook() {
    local sandbox="$1" json="$2"
    local sandbox_node
    if command -v cygpath >/dev/null 2>&1; then
        sandbox_node="$(cygpath -m "$sandbox")"
    else
        sandbox_node="$sandbox"
    fi
    echo "$json" | run_with_timeout 15 node "$sandbox_node/hooks/scan-outbound.js" 2>/dev/null
}

# Check if the current hook source code calls bin/scan-offensive at all.
# If not, the integration hasn't landed — skip the corresponding tests.
hook_integrates_scan_offensive() {
    grep -q 'scan-offensive' "$HOOK_SRC" 2>/dev/null
}

T1_TMP=""
T2_TMP=""
T3_TMP=""
T4_TMP=""
T5_TMP=""
T6_TMP=""
T7_TMP=""
T8_TMP=""
T9_TMP=""
cleanup() {
    rm -rf "$T1_TMP" "$T2_TMP" "$T3_TMP" "$T4_TMP" "$T5_TMP" "$T6_TMP" "$T7_TMP" "$T8_TMP" "$T9_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# All these tests rely on the integration being live in scan-outbound.js.
# Skip uniformly if not yet integrated.

run_t1() {
    require_hook "T1: gh issue create with offensive content → block" || return
    if ! hook_integrates_scan_offensive; then
        skip "T1: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T1_TMP=$(mktemp -d)
    build_sandbox "$T1_TMP" 1
    local json out
    # Bash tool with gh issue create — body contains content the stub will flag (rc=1)
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"some offensive content here\""}}'
    out=$(run_sandboxed_hook "$T1_TMP" "$json")
    if echo "$out" | grep -q '"block"'; then
        pass "T1: gh issue create with offensive content → block"
    else
        fail "T1: expected block decision, got: $out"
    fi
}

run_t2() {
    require_hook "T2: gh issue create with clean content → approve" || return
    if ! hook_integrates_scan_offensive; then
        skip "T2: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T2_TMP=$(mktemp -d)
    build_sandbox "$T2_TMP" 0
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"clean content\""}}'
    out=$(run_sandboxed_hook "$T2_TMP" "$json")
    if echo "$out" | grep -q '"approve"'; then
        pass "T2: gh issue create with clean content → approve"
    else
        fail "T2: expected approve decision, got: $out"
    fi
}

run_t3() {
    require_hook "T3: private-repo skip does NOT exempt offensive scan" || return
    if ! hook_integrates_scan_offensive; then
        skip "T3: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T3_TMP=$(mktemp -d)
    build_sandbox "$T3_TMP" 1
    # Patch is-private-repo.js to always report private = true. This proves the
    # offensive scan runs even when private-repo skip would normally bypass.
    local lib="$T3_TMP/hooks/lib/is-private-repo.js"
    cat > "$lib" <<'JS'
// stub: always-private
module.exports = {
  isPrivateRepo: function () { return true; },
  resolveRepoDir: function () { return null; },
};
JS
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"some flagged content\""}}'
    out=$(run_sandboxed_hook "$T3_TMP" "$json")
    if echo "$out" | grep -q '"block"'; then
        pass "T3: private-repo skip does NOT exempt offensive scan (still blocked)"
    else
        # If the impl placed scan-offensive INSIDE the private-repo skip branch,
        # the decision would be approve — that is the bug we are guarding against.
        fail "T3: offensive scan exempted for private repo (regression) — got: $out"
    fi
}

run_t4() {
    require_hook "T4: scan-outbound.sh=0 + scan-offensive=0 → approve" || return
    if ! hook_integrates_scan_offensive; then
        skip "T4: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T4_TMP=$(mktemp -d)
    build_sandbox "$T4_TMP" 0
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"clean and clean\""}}'
    out=$(run_sandboxed_hook "$T4_TMP" "$json")
    if echo "$out" | grep -q '"approve"'; then
        pass "T4: both scanners clean → approve"
    else
        fail "T4: expected approve, got: $out"
    fi
}

run_t5() {
    require_hook "T5: scan-outbound.sh=0 + scan-offensive=1 → block (offensive found)" || return
    if ! hook_integrates_scan_offensive; then
        skip "T5: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T5_TMP=$(mktemp -d)
    build_sandbox "$T5_TMP" 1
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"offensive content\""}}'
    out=$(run_sandboxed_hook "$T5_TMP" "$json")
    if echo "$out" | grep -q '"block"'; then
        pass "T5: scan-outbound.sh=0 + scan-offensive=1 → block"
    else
        fail "T5: expected block, got: $out"
    fi
}

run_t6() {
    require_hook "T6: scan-outbound.sh=1 + scan-offensive=0 → block (private info)" || return
    if ! hook_integrates_scan_offensive; then
        skip "T6: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T6_TMP=$(mktemp -d)
    build_sandbox_full "$T6_TMP" 1 0
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"content with private info\""}}'
    out=$(run_sandboxed_hook "$T6_TMP" "$json")
    if echo "$out" | grep -q '"block"'; then
        pass "T6: scan-outbound.sh=1 + scan-offensive=0 → block (private info)"
    else
        fail "T6: expected block for outbound=1/offensive=0, got: $out"
    fi
}

build_sandbox_no_offensive() {
    local sandbox="$1"
    mkdir -p "$sandbox/hooks/lib" "$sandbox/bin"
    cp "$HOOK_SRC" "$sandbox/hooks/scan-outbound.js"
    cp -r "$AGENTS_DIR/hooks/lib/." "$sandbox/hooks/lib/" 2>/dev/null || true
    # scan-outbound.sh stub (clean)
    cat > "$sandbox/bin/scan-outbound.sh" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$sandbox/bin/scan-outbound.sh"
    # bin/scan-offensive intentionally NOT created
}

run_t7() {
    require_hook "T7: scan-offensive absent → fail-closed (block)" || return
    if ! hook_integrates_scan_offensive; then
        skip "T7: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T7_TMP=$(mktemp -d)
    build_sandbox_no_offensive "$T7_TMP"
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"some content\""}}'
    out=$(run_sandboxed_hook "$T7_TMP" "$json")
    if echo "$out" | grep -q '"block"'; then
        pass "T7: scan-offensive absent → fail-closed (block)"
    else
        fail "T7: expected block when scan-offensive absent, got: $out"
    fi
}

run_t8() {
    require_hook "T8: scan-offensive=2 (warn) → block" || return
    if ! hook_integrates_scan_offensive; then
        skip "T8: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T8_TMP=$(mktemp -d)
    build_sandbox "$T8_TMP" 2
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"borderline content\""}}'
    out=$(run_sandboxed_hook "$T8_TMP" "$json")
    if echo "$out" | grep -q '"block"'; then
        pass "T8: scan-offensive=2 (warn) → block"
    else
        fail "T8: expected block for offensive warn-tier (rc=2), got: $out"
    fi
}

run_t9() {
    require_hook "T9: scan-offensive=3 (usage error) → block" || return
    if ! hook_integrates_scan_offensive; then
        skip "T9: scan-outbound.js does not yet call bin/scan-offensive (integration not landed)"
        return
    fi
    T9_TMP=$(mktemp -d)
    build_sandbox "$T9_TMP" 3
    local json out
    json='{"tool_name":"Bash","tool_input":{"command":"gh issue create --title t --body \"some content\""}}'
    out=$(run_sandboxed_hook "$T9_TMP" "$json")
    if echo "$out" | grep -q '"block"'; then
        pass "T9: scan-offensive=3 (usage error) → block"
    else
        fail "T9: expected block for offensive usage error (rc=3), got: $out"
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
run_t9

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

#!/bin/bash
# tests/feature-workflow-off-ask-rule.sh
#
# Static + pattern tests for the ENFORCE_WORKFLOW sentinel ask/allow rules and
# sentinel-patterns.js recognition.
#
# Feature contract:
#   - settings.json `ask` array must contain:
#       Bash(echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: *>>")
#   - settings.json `allow` array must contain:
#       Bash(echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: *>>")
#   - Neither bare form (WORKFLOW_ENFORCE_WORKFLOW_OFF>> or _ON>>) may appear
#     in ask/allow — bare forms must be rejected as malformed.
#   - hooks/lib/sentinel-patterns.js isSentinel() must recognise:
#       DQ form:        echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>"
#       LOOKSLIKE form: echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason extra>>"
#                      (and same for _ON)
#   - hooks/lib/sentinel-patterns.js isStrictSentinel() must recognise only
#     the DQ form (used by workflow-gate.js Step 1 chain-guard). LOOKSLIKE
#     forms must NOT pass isStrictSentinel.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
SETTINGS_JSON="${AGENTS_DIR}/settings.json"
SENTINEL_PATTERNS_JS="${_AGENTS_DIR_NODE}/hooks/lib/sentinel-patterns.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Portable timeout: prefers `timeout`, falls back to perl alarm (macOS-safe).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_settings_json() {
    if [ ! -f "$SETTINGS_JSON" ]; then
        fail "$1 (settings.json not present at $SETTINGS_JSON)"
        return 1
    fi
    return 0
}

require_sentinel_patterns_js() {
    if [ ! -f "$SENTINEL_PATTERNS_JS" ]; then
        fail "$1 (hooks/lib/sentinel-patterns.js not present)"
        return 1
    fi
    return 0
}

# Use node to read settings.json, look up `permissions.<bucket>`, and check
# whether <literal> is present. Echoes "true" or "false".
# Args: bucket(ask|allow|deny) literal
settings_bucket_contains() {
    local bucket="$1" literal="$2"
    run_with_timeout 30 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const arr = (s.permissions && s.permissions[process.argv[2]]) || [];
console.log(arr.includes(process.argv[3]) ? 'true' : 'false');
" "$SETTINGS_JSON" "$bucket" "$literal" 2>&1
}

# Args: bucket  pattern  — returns "true" if any element of permissions.<bucket>
# matches the JS regex (used to check that bare forms are absent).
settings_bucket_matches_any() {
    local bucket="$1" pattern="$2"
    run_with_timeout 30 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const arr = (s.permissions && s.permissions[process.argv[2]]) || [];
const re = new RegExp(process.argv[3]);
console.log(arr.some(x => re.test(x)) ? 'true' : 'false');
" "$SETTINGS_JSON" "$bucket" "$pattern" 2>&1
}

# Invoke isSentinel(cmd) and echo "true"/"false"/<error>.
# Args: cmd-as-js-literal (e.g. '"echo \"<<...>>\""')
run_is_sentinel() {
    local cmd_js="$1"
    run_with_timeout 30 node -e "
const sp = require('$SENTINEL_PATTERNS_JS');
try {
  console.log(sp.isSentinel($cmd_js));
} catch(e) {
  console.log('THREW:' + e.message);
}
" 2>&1
}

# Invoke isStrictSentinel(cmd) and echo "true"/"false"/<error>.
run_is_strict_sentinel() {
    local cmd_js="$1"
    run_with_timeout 30 node -e "
const sp = require('$SENTINEL_PATTERNS_JS');
try {
  console.log(sp.isStrictSentinel($cmd_js));
} catch(e) {
  console.log('THREW:' + e.message);
}
" 2>&1
}

# ============================================================================
# S. Static settings.json checks
# ============================================================================

test_S1_ask_has_workflow_off() {
    require_settings_json "S1" || return
    local literal='Bash(echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: *>>")'
    local out; out="$(settings_bucket_contains "ask" "$literal")"
    if echo "$out" | grep -qx "true"; then
        pass "S1: settings.json ask[] contains WORKFLOW_ENFORCE_WORKFLOW_OFF rule"
    else
        fail "S1: ask[] missing WORKFLOW_ENFORCE_WORKFLOW_OFF rule (out: $out)"
    fi
}

test_S2_allow_has_workflow_on() {
    require_settings_json "S2" || return
    local literal='Bash(echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: *>>")'
    local out; out="$(settings_bucket_contains "allow" "$literal")"
    if echo "$out" | grep -qx "true"; then
        pass "S2: settings.json allow[] contains WORKFLOW_ENFORCE_WORKFLOW_ON rule"
    else
        fail "S2: allow[] missing WORKFLOW_ENFORCE_WORKFLOW_ON rule (out: $out)"
    fi
}

test_S3_bare_off_not_in_ask_or_allow() {
    require_settings_json "S3" || return
    # Bare form: literal substring `WORKFLOW_ENFORCE_WORKFLOW_OFF>>` (no colon).
    # If anything in ask[] or allow[] matches this, it would bypass the malformed
    # rejection by granting permission to the bare form too.
    local pattern='WORKFLOW_ENFORCE_WORKFLOW_OFF>>'
    local out_ask; out_ask="$(settings_bucket_matches_any "ask" "$pattern")"
    local out_allow; out_allow="$(settings_bucket_matches_any "allow" "$pattern")"
    if echo "$out_ask" | grep -qx "false" && echo "$out_allow" | grep -qx "false"; then
        pass "S3: bare WORKFLOW_ENFORCE_WORKFLOW_OFF>> absent from ask[] and allow[]"
    else
        fail "S3: bare OFF form found in ask[]=$out_ask allow[]=$out_allow"
    fi
}

test_S4_bare_on_not_in_ask() {
    require_settings_json "S4" || return
    local pattern='WORKFLOW_ENFORCE_WORKFLOW_ON>>'
    local out_ask; out_ask="$(settings_bucket_matches_any "ask" "$pattern")"
    if echo "$out_ask" | grep -qx "false"; then
        pass "S4: bare WORKFLOW_ENFORCE_WORKFLOW_ON>> absent from ask[]"
    else
        fail "S4: bare ON form found in ask[]: $out_ask"
    fi
}

# ============================================================================
# P. sentinel-patterns.js pattern recognition
# ============================================================================

test_P1_isSentinel_recognises_off_dq() {
    require_sentinel_patterns_js "P1" || return
    local cmd_js='"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>\""'
    local out; out="$(run_is_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "true"; then
        pass "P1: isSentinel() recognises WORKFLOW_ENFORCE_WORKFLOW_OFF DQ form"
    else
        fail "P1: isSentinel did NOT recognise OFF DQ form (out: $out)"
    fi
}

test_P2_isSentinel_recognises_off_lookslike() {
    require_sentinel_patterns_js "P2" || return
    # Has extra content after the reason — should still match the LOOKSLIKE
    # fallback so the LOOKSLIKE handler in workflow-mark.js can reject it as
    # malformed (rather than silently passing through).
    local cmd_js='"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason extra>>\""'
    local out; out="$(run_is_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "true"; then
        pass "P2: isSentinel() recognises WORKFLOW_ENFORCE_WORKFLOW_OFF LOOKSLIKE form"
    else
        fail "P2: isSentinel did NOT recognise OFF LOOKSLIKE form (out: $out)"
    fi
}

test_P3_isSentinel_recognises_on_dq() {
    require_sentinel_patterns_js "P3" || return
    local cmd_js='"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: reason>>\""'
    local out; out="$(run_is_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "true"; then
        pass "P3: isSentinel() recognises WORKFLOW_ENFORCE_WORKFLOW_ON DQ form"
    else
        fail "P3: isSentinel did NOT recognise ON DQ form (out: $out)"
    fi
}

test_P4_isSentinel_rejects_bare_off() {
    require_sentinel_patterns_js "P4" || return
    # Bare form (no colon, no reason). The LOOKSLIKE regex requires `([: ].*)?`
    # — i.e. either nothing or a `: ...` / ` ...` continuation — so bare
    # `WORKFLOW_ENFORCE_WORKFLOW_OFF>>` DOES match LOOKSLIKE and is captured
    # for the malformed branch. Therefore isSentinel SHOULD return true on
    # bare form (so workflow-mark.js / workflow-gate.js intercept it).
    #
    # The bare-form REJECTION test is in feature-workflow-off-session-override.sh
    # tests A12/A13 (workflow-mark.js emits "malformed" and does not mutate
    # the marker). Here we instead validate that the entirely malformed
    # `echo` (no quotes) is not accidentally recognised.
    local cmd_js='"echo <<WORKFLOW_ENFORCE_WORKFLOW_OFF>>"'
    local out; out="$(run_is_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "false"; then
        pass "P4: isSentinel() rejects unquoted/malformed echo (no DQ wrapper)"
    else
        fail "P4: isSentinel incorrectly recognised unquoted echo (out: $out)"
    fi
}

test_P5_isStrictSentinel_recognises_off_dq() {
    require_sentinel_patterns_js "P5" || return
    local cmd_js='"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>\""'
    local out; out="$(run_is_strict_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "true"; then
        pass "P5: isStrictSentinel() recognises OFF DQ form"
    else
        fail "P5: isStrictSentinel did NOT recognise OFF DQ (out: $out)"
    fi
}

test_P6_isStrictSentinel_recognises_on_dq() {
    require_sentinel_patterns_js "P6" || return
    local cmd_js='"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: reason>>\""'
    local out; out="$(run_is_strict_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "true"; then
        pass "P6: isStrictSentinel() recognises ON DQ form"
    else
        fail "P6: isStrictSentinel did NOT recognise ON DQ (out: $out)"
    fi
}

test_P7_isStrictSentinel_rejects_lookslike() {
    require_sentinel_patterns_js "P7" || return
    # Bare form `<<WORKFLOW_ENFORCE_WORKFLOW_OFF>>` matches LOOKSLIKE but not DQ.
    # isStrictSentinel must reject it (DQ-only).
    local cmd_js='"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF>>\""'
    local out; out="$(run_is_strict_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "false"; then
        pass "P7: isStrictSentinel() rejects bare LOOKSLIKE form (DQ-only)"
    else
        fail "P7: isStrictSentinel incorrectly accepted bare LOOKSLIKE (out: $out)"
    fi
}

test_P8_isStrictSentinel_rejects_chained() {
    require_sentinel_patterns_js "P8" || return
    # Chain-guard: the strict DQ regex uses `[^>]+` for the reason, which stops
    # at the first `>`. Therefore a chained command does NOT match isStrictSentinel
    # even though it begins with a sentinel-shaped echo.
    local cmd_js='"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: x>>\" && rm -rf /tmp/foo"'
    local out; out="$(run_is_strict_sentinel "$cmd_js")"
    if echo "$out" | grep -qx "false"; then
        pass "P8: isStrictSentinel() rejects chained command (chain-guard via [^>]+)"
    else
        fail "P8: isStrictSentinel incorrectly accepted chained command (out: $out)"
    fi
}

# ============================================================================
# Run all
# ============================================================================

run_all() {
    # S: static settings.json
    test_S1_ask_has_workflow_off
    test_S2_allow_has_workflow_on
    test_S3_bare_off_not_in_ask_or_allow
    test_S4_bare_on_not_in_ask
    # P: sentinel-patterns.js
    test_P1_isSentinel_recognises_off_dq
    test_P2_isSentinel_recognises_off_lookslike
    test_P3_isSentinel_recognises_on_dq
    test_P4_isSentinel_rejects_bare_off
    test_P5_isStrictSentinel_recognises_off_dq
    test_P6_isStrictSentinel_recognises_on_dq
    test_P7_isStrictSentinel_rejects_lookslike
    test_P8_isStrictSentinel_rejects_chained
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WORKFLOW_OFF_ASK_TEST_INNER:-}" ]; then
        _WORKFLOW_OFF_ASK_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL

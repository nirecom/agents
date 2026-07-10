#!/usr/bin/env bash
# tests/feature-supervisor-premerge-block-reason.sh
# Tests: hooks/lib/supervisor-report-format.js, hooks/lib/conv-lang.js
# Tags: supervisor, em-supervisor, premerge, block-reason, conv-lang, scope-drift, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - CONV_LANG env var propagation into the real hook subprocess in a live claude -p session
#   (Anthropic bug #27987) — here CONV_LANG is set directly for the node child.
# - The reason string actually being surfaced by workflow-gate.js blockWithoutError in a real merge gate
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# Step 1 (detail.md): new formatPreMergeBlockReason(cause, sessionId, workflowSessionId,
#   auditAgentPath, stateFilePath, stateSessionId) in supervisor-report-format.js, exported.
#   cause ∈ {"warning-flush","scope-drift:pre-merge"}. CONV_LANG-prefixed. Body guides the
#   user to agents/supervisor-audit.md. Body MUST NOT reference any OFF escape hatch (intent-C2):
#   no WORKFLOW_OFF / ENFORCE_ / "escape hatch" / "workflow-off" substrings.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

FORMAT_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-report-format.js"
CONV_LANG_NODE="$_AGENTS_DIR_NODE/hooks/lib/conv-lang.js"

PASS=0; FAIL=0; SKIP=0
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

FORMAT_FILE="$AGENTS_DIR/hooks/lib/supervisor-report-format.js"
CONV_LANG_FILE="$AGENTS_DIR/hooks/lib/conv-lang.js"
if [ ! -f "$FORMAT_FILE" ] || [ ! -f "$CONV_LANG_FILE" ]; then
    fail "premerge-block-reason: report-format.js or conv-lang.js not present (RED-EXPECTED — Changes 1/3 not yet applied)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# Function-exported guard: FAIL until implementation lands (RED-EXPECTED).
EXPORTED=$(run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
process.stdout.write(typeof fmt.formatPreMergeBlockReason === 'function' ? 'yes' : 'no');
" 2>/dev/null)

if [ "$EXPORTED" != "yes" ]; then
    fail "premerge-block-reason: formatPreMergeBlockReason not yet exported (RED-EXPECTED — Change 3 not yet applied)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# Call the formatter for a given cause and CONV_LANG value; print the reason string.
call_fmt() {
    local conv="$1" cause="$2"
    CONV_LANG="$conv" run_with_timeout 10 node -e "
const fmt = require('$FORMAT_NODE');
const r = fmt.formatPreMergeBlockReason(
    '$cause',
    'test-sid',
    'test-wsid',
    '/agents/agents/supervisor-audit.md',
    '/tmp/state.json',
    'test-sid'
);
process.stdout.write(String(r));
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# CONV_LANG=ja → return STARTS WITH the conv-lang injection prefix.
# ---------------------------------------------------------------------------
run_convlang_ja_prefix() {
    local injection result
    injection=$(CONV_LANG=ja run_with_timeout 10 node -e "
const { getConvLangInjection } = require('$CONV_LANG_NODE');
process.stdout.write(getConvLangInjection() || '');
" 2>/dev/null)

    if [ -z "$injection" ]; then
        skip "convlang-ja: getConvLangInjection returned empty (CONV_LANG may not propagate in env)"
        return
    fi

    result=$(call_fmt ja warning-flush)
    if [[ "$result" != "$injection"* ]]; then
        fail "convlang-ja: formatPreMergeBlockReason must start with CONV_LANG injection prefix"
        return
    fi
    pass "convlang-ja: warning-flush reason starts with injection prefix"
}

# ---------------------------------------------------------------------------
# CONV_LANG=english → NO injection prefix.
# ---------------------------------------------------------------------------
run_convlang_english_noprefix() {
    local injection result
    injection=$(CONV_LANG=ja run_with_timeout 10 node -e "
const { getConvLangInjection } = require('$CONV_LANG_NODE');
process.stdout.write(getConvLangInjection() || '');
" 2>/dev/null)

    result=$(call_fmt english warning-flush)
    # With CONV_LANG=english, getConvLangInjection() returns null → no prefix.
    if [ -n "$injection" ] && [[ "$result" == "$injection"* ]]; then
        fail "convlang-english: reason must NOT carry the ja injection prefix under CONV_LANG=english"
        return
    fi
    # Sanity: reason is still non-empty.
    if [ -z "$result" ]; then
        fail "convlang-english: reason unexpectedly empty"
        return
    fi
    pass "convlang-english: no injection prefix added"
}

# ---------------------------------------------------------------------------
# Table-driven over cause: body references supervisor-audit (next-step guidance),
# and NEVER contains any OFF escape-hatch substring (intent-C2 negative assertion).
# ---------------------------------------------------------------------------
run_body_table() {
    while IFS='|' read -r name cause; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cause="${cause//[[:space:]]/}"

        local result
        result=$(call_fmt english "$cause")

        # (a) next-step guidance: body must reference supervisor-audit
        if echo "$result" | grep -qF "supervisor-audit"; then
            pass "$name: body references supervisor-audit (next-step guidance)"
        else
            fail "$name: body must reference supervisor-audit as the next step"
        fi

        # (b) NEGATIVE (intent-C2 / security): no OFF escape-hatch substrings (case-insensitive).
        if echo "$result" | grep -qiE "WORKFLOW_OFF|ENFORCE_|escape hatch|workflow-off"; then
            fail "$name: reason MUST NOT reference any OFF escape hatch (intent-C2 violated)"
        else
            pass "$name: reason contains no OFF escape-hatch substring"
        fi
    done <<'TABLE'
cause-warning-flush     | warning-flush
cause-scope-drift       | scope-drift:pre-merge
TABLE
}

run_convlang_ja_prefix
run_convlang_english_noprefix
run_body_table

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

#!/usr/bin/env bash
# tests/cc-supervisor-emit-rules-injection.sh
# Tests: hooks/lib/supervisor-emit.js
# Tags: rules-injection, supervisor, supervisor-emit, instructions-loaded, TL2, scope:common
#
# TL2 coverage of the new reportRulesInjection() export (detail plan section 3-5). Unlike tests/feature-831-supervisor-emit.sh, which stubs appendFinding, this file writes through the REAL supervisor-state-writer into a pinned fixture plans dir and reads the persisted finding back — the plan's claim is about what actually lands in the state file, and a stubbed writer cannot fail on a validateFinding rejection. Layer: TL2 (real node subprocess, real state file in a fixture dir).
# TL3 gap: whether the audit hook actually calls reportRulesInjection with a resolvable wsid during a live session (wsid is null for non-workflow sessions by design), and whether the supervisor alert pipeline surfaces a "workflow"/error finding to the user. Mitigated at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMIT="$AGENTS_DIR/hooks/lib/supervisor-emit.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if [ ! -f "$EMIT" ]; then
    echo "FAIL: IMPLEMENTATION MISSING: $EMIT"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

HAS_EXPORT="$(node -e "
try { const m = require(process.argv[1]);
  console.log(typeof m.reportRulesInjection === 'function' ? 'yes' : 'no'); }
catch (e) { console.log('REQUIRE_ERR:' + e.message); }
" "$(node_path "$EMIT")" 2>&1)"
if [ "$HAS_EXPORT" != "yes" ]; then
    echo "FAIL: IMPLEMENTATION MISSING: hooks/lib/supervisor-emit.js does not export reportRulesInjection (got: $HAS_EXPORT)"
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — detail plan S2-3)"
    exit 1
fi

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
WFDIR="$BASE/workflow"; PLANS="$BASE/plans"
mkdir -p "$WFDIR" "$PLANS"

# Fixture isolation: dual-pin the pair (rules/test/fixture-isolation.md), otherwise
# supervisor-emit's isolationContradiction guard refuses every write.
export CLAUDE_WORKFLOW_DIR; CLAUDE_WORKFLOW_DIR="$(node_path "$WFDIR")"
export WORKFLOW_PLANS_DIR; WORKFLOW_PLANS_DIR="$(node_path "$PLANS")"
unset CLAUDE_SESSION_ID || true
unset CLAUDE_CODE_SESSION_ID || true

# emit <sid> <js-call> — runs the facade against the real writer
emit() {
    ( cd "$BASE" && node -e "
const m = require(process.argv[1]);
$2
" "$(node_path "$EMIT")" ) 2>&1
}

# field <sid> <index> <path-expr> — reads a persisted finding back out of the state file
field() {
    node -e "
const fs = require('fs'), path = require('path');
const p = path.join(process.argv[1], process.argv[2] + '-supervisor-state.json');
if (!fs.existsSync(p)) { console.log('NO_STATE_FILE'); process.exit(0); }
const s = JSON.parse(fs.readFileSync(p, 'utf8'));
const findings = (s.layer1 && Array.isArray(s.layer1.findings)) ? s.layer1.findings
  : ((s.alert && Array.isArray(s.alert.findings)) ? s.alert.findings : []);
const f = findings[Number(process.argv[3])];
if (!f) { console.log('NO_FINDING'); process.exit(0); }
const v = eval('f.' + process.argv[4]);
console.log(v === undefined ? 'ABSENT' : (Array.isArray(v) ? JSON.stringify(v) : String(v)));
" "$(node_path "$PLANS")" "$1" "$2" "$3" 2>&1
}

# --- R1/R2: severity is carried through, not hardcoded (table-driven over verdicts) ---
while IFS='|' read -r name verdict severity; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; verdict="${verdict//[[:space:]]/}"; severity="${severity//[[:space:]]/}"
    sid="ri-${name}"
    err="$(emit "$sid" "m.reportRulesInjection('$verdict', 'rules/example.md', '$sid');")"
    got_cats="$(field "$sid" 0 categories)"
    got_sev="$(field "$sid" 0 severity)"
    got_rep="$(field "$sid" 0 reporter)"
    if [ "$got_cats" != '["workflow"]' ]; then
        fail "$name: want categories [\"workflow\"], got $got_cats (emit stderr: $err)"
    elif [ "$got_sev" != "$severity" ]; then
        fail "$name: want severity $severity, got $got_sev"
    elif [ "$got_rep" != "instructions-loaded-audit" ]; then
        fail "$name: want reporter instructions-loaded-audit, got $got_rep"
    else
        pass "$name: $verdict persisted as workflow/$severity/instructions-loaded-audit"
    fi
done <<'TABLE'
S-MISSING   | S-MISSING   | warning
S-MALFORMED | S-MALFORMED | error
S-LEAK      | S-LEAK      | error
TABLE

# --- R3: the detail identifies the offending file (otherwise the finding is unactionable) ---
R3_SID="ri-detail"
emit "$R3_SID" "m.reportRulesInjection('S-LEAK', 'rules/github-issues.md', '$R3_SID');" >/dev/null
r3_detail="$(field "$R3_SID" 0 detail)"
if printf '%s' "$r3_detail" | grep -q 'rules/github-issues.md' && printf '%s' "$r3_detail" | grep -q 'S-LEAK'; then
    pass "R3: detail names both the verdict and the file path"
else
    fail "R3: detail must name the verdict and the file path, got '$r3_detail'"
fi

# --- R4: contrast — reportRetrospective still hardcodes other/notice/session-close ---
R4_SID="ri-retro"
emit "$R4_SID" "m.reportRetrospective('post-session observation', '$R4_SID');" >/dev/null
r4_cats="$(field "$R4_SID" 0 categories)"; r4_sev="$(field "$R4_SID" 0 severity)"; r4_rep="$(field "$R4_SID" 0 reporter)"
if [ "$r4_cats" = '["other"]' ] && [ "$r4_sev" = "notice" ] && [ "$r4_rep" = "session-close" ]; then
    pass "R4: reportRetrospective is unchanged (other/notice/session-close)"
else
    fail "R4: reportRetrospective changed — got $r4_cats / $r4_sev / $r4_rep"
fi

# --- R5-R7: the other three pre-existing exports are unchanged ---
while IFS='|' read -r name call want_cats want_sev want_rep; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; want_cats="${want_cats//[[:space:]]/}"
    want_sev="${want_sev//[[:space:]]/}"; want_rep="${want_rep//[[:space:]]/}"
    sid="ri-$name"
    emit "$sid" "${call//SID/$sid}" >/dev/null
    g_cats="$(field "$sid" 0 categories)"; g_sev="$(field "$sid" 0 severity)"; g_rep="$(field "$sid" 0 reporter)"
    if [ "$g_cats" = "$want_cats" ] && [ "$g_sev" = "$want_sev" ] && [ "$g_rep" = "$want_rep" ]; then
        pass "$name: pre-existing export unchanged ($want_cats/$want_sev/$want_rep)"
    else
        fail "$name: want $want_cats/$want_sev/$want_rep, got $g_cats/$g_sev/$g_rep"
    fi
done <<'TABLE'
reportBlock    | m.reportBlock('enforce-worktree', 'git push origin main', 'SID');   | ["workflow"] | notice  | enforce-worktree
reportFallback | m.reportFallback('issue-create', 'worktree-notes', 'SID');          | ["workflow"] | warning | issue-create
reportSentinel | m.reportSentinel('WORKFLOW_OFF', 'trivial typo', 'SID');            | ["workflow"] | warning | enforce-override-handlers
TABLE

# --- R8: fail-open — a null sessionId neither throws nor writes a state file ---
R8_OUT="$(emit "unused" "
const r = m.reportRulesInjection('S-LEAK', 'rules/test.md', null);
console.log(r === undefined ? 'UNDEFINED_OK' : 'RETURNED:' + String(r));
")"
R8_LEAKED="$(find "$PLANS" -name 'null-supervisor-state.json' -o -name 'undefined-supervisor-state.json' 2>/dev/null | wc -l | tr -d ' ')"
if printf '%s' "$R8_OUT" | grep -q 'UNDEFINED_OK' && [ "$R8_LEAKED" = "0" ]; then
    pass "R8: reportRulesInjection with a null sessionId is fail-open and writes nothing"
else
    fail "R8: want a silent no-op, got output '$R8_OUT' and $R8_LEAKED stray state file(s)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

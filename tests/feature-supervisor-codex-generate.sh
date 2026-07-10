#!/usr/bin/env bash
# tests/feature-supervisor-codex-generate.sh
# Tests: bin/supervisor-review-codex, bin/supervisor-write-alert, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, codex, generate, ingest-jsonl, alert, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - Real Codex CLI invocation (codex present + exit codes 0/3) — test env has no codex, so --generate
#   is exercised only on the unavailable path; live JSONL generation is not verified here.
# - agents/supervisor.md single-shot output protocol wiring in a live claude -p session
#   (bin invocations driven by the real supervisor subagent, not by this harness directly)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# Change 5 (detail.md Step 8):
#  A) bin/supervisor-review-codex --generate: emits findings as raw JSONL to stdout
#     (one {"categories":[...],"severity":"...","detail":"...","reporter":"supervisor"} per line).
#     Codex unavailable (missing / exit 3) → EMPTY stdout, exit 0. No --generate → legacy marker output.
#  B) bin/supervisor-write-alert --ingest-generated-jsonl <path>: line-wise JSON.parse (skip bad lines,
#     fail-open); each object with categories+severity+detail+reporter → writeAlertState append.
#     Zero-record guard: empty / 0 parseable → no-op exit 0. Mutually exclusive with
#     --confirm-finding-ids / --drop-finding-ids.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

REVIEW_CODEX="$AGENTS_DIR/bin/supervisor-review-codex"
WRITE_ALERT="$AGENTS_DIR/bin/supervisor-write-alert"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsrcg'; }

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

if [ ! -f "$REVIEW_CODEX" ]; then
    skip "codex-generate: bin/supervisor-review-codex not present"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi
if [ ! -f "$WRITE_ALERT" ]; then
    skip "codex-generate: bin/supervisor-write-alert not present"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi

# Return the alert.findings length for a session, or "null" if state absent.
alert_findings_len() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
if (!st || !st.alert || !Array.isArray(st.alert.findings)) { process.stdout.write('null'); }
else { process.stdout.write(String(st.alert.findings.length)); }
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# (generate) --generate with Codex unavailable → empty stdout AND exit 0
# ---------------------------------------------------------------------------
run_generate_unavailable() {
    if ! grep -q -- "--generate" "$REVIEW_CODEX" 2>/dev/null; then
        skip "generate-unavailable: --generate flag not yet in supervisor-review-codex (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid state_file out rc
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-gen-$$"

    # Seed a minimal state with a pending alert + a draft finding so the script
    # reaches the codex-invocation stage (rather than short-circuiting earlier).
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.alert_phase = 'pending';
st.alert.findings = [{ categories:['workflow'], severity:'warning', detail:'seed', reporter:'supervisor', status:'draft', idx:0, timestamp:new Date().toISOString() }];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Force codex-unavailable: run with a PATH that has no 'codex'.
    # (test env has no real codex; we make it deterministic by masking PATH.)
    out=$(SID="$sid" WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" PATH="/usr/bin:/bin" \
        run_with_timeout 20 bash "$REVIEW_CODEX" --generate 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "generate-unavailable: exit must be 0 when codex unavailable, got $rc"
        return
    fi
    # --generate emits RAW JSONL (no markers). Codex-unavailable → NO JSONL finding objects.
    if echo "$out" | grep -q '"categories"'; then
        fail "generate-unavailable: expected empty JSONL stdout when codex unavailable, got finding objects"
        return
    fi
    pass "generate-unavailable: codex unavailable → no JSONL findings, exit 0"
}

# ---------------------------------------------------------------------------
# (generate back-compat) invoking WITHOUT --generate preserves prior behavior
#   (does not emit raw JSONL findings; SKIP gracefully if it needs live codex).
# ---------------------------------------------------------------------------
run_generate_backcompat() {
    local tmp tmp_node sid out rc
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-bc-$$"

    # No state file → legacy path SKIPs with "no state file" (deterministic, no codex needed).
    out=$(SID="$sid" WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" PATH="/usr/bin:/bin" \
        run_with_timeout 20 bash "$REVIEW_CODEX" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "generate-backcompat: legacy (no --generate) exit must be 0 on no-state SKIP, got $rc"
        return
    fi
    # Legacy path must NOT dump raw JSONL finding objects to stdout (that is --generate-only).
    if echo "$out" | grep -q '"categories":\['; then
        fail "generate-backcompat: legacy path must not emit raw JSONL finding objects"
        return
    fi
    pass "generate-backcompat: legacy invocation (no --generate) preserves non-JSONL exit behavior"
}

# ---------------------------------------------------------------------------
# (ingest happy-path) 2 valid finding objects → findings length +2, fields round-trip
# ---------------------------------------------------------------------------
run_ingest_happy() {
    if ! grep -q -- "--ingest-generated-jsonl" "$WRITE_ALERT" 2>/dev/null; then
        skip "ingest-happy: --ingest-generated-jsonl flag not yet in supervisor-write-alert (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid before after jsonl d1 d2
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-ing-$$"

    # Fresh state (no findings yet).
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
const fs = require('fs');
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(s.createEmptyState('$sid')));
" >/dev/null 2>&1

    before=$(alert_findings_len "$tmp_node" "$sid")

    d1='ingest finding one'
    d2='ingest finding two'
    jsonl="$tmp/gen.jsonl"
    {
        printf '{"categories":["workflow"],"severity":"warning","detail":"%s","reporter":"supervisor"}\n' "$d1"
        printf '{"categories":["code"],"severity":"error","detail":"%s","reporter":"supervisor"}\n' "$d2"
    } > "$jsonl"
    local jsonl_node; jsonl_node="$(to_node_path "$jsonl")"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$WRITE_ALERT" \
        --ingest-generated-jsonl "$jsonl_node" --session-id "$sid" >/dev/null 2>&1
    local rc=$?

    after=$(alert_findings_len "$tmp_node" "$sid")

    # Field round-trip check for the two appended details.
    local rt
    rt=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const fs = (st && st.alert && st.alert.findings) || [];
const got = fs.map(f => f.detail);
process.stdout.write((got.includes('$d1') && got.includes('$d2')) ? 'both' : 'missing');
" 2>/dev/null)

    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "ingest-happy: exit must be 0 on valid ingest, got $rc"
        return
    fi
    if [ "$before" = "null" ] || [ "$after" = "null" ]; then
        fail "ingest-happy: state unreadable (before=$before after=$after)"
        return
    fi
    if [ "$after" != "$((before + 2))" ]; then
        fail "ingest-happy: findings must grow by exactly 2 (before=$before after=$after)"
        return
    fi
    if [ "$rt" != "both" ]; then
        fail "ingest-happy: appended finding details did not round-trip"
        return
    fi
    pass "ingest-happy: 2 valid findings appended (+2), fields round-trip"
}

# ---------------------------------------------------------------------------
# (ingest zero-record guard) empty file → no-op, exit 0, findings unchanged
# ---------------------------------------------------------------------------
run_ingest_zero_record() {
    if ! grep -q -- "--ingest-generated-jsonl" "$WRITE_ALERT" 2>/dev/null; then
        skip "ingest-zero: --ingest-generated-jsonl flag not yet in supervisor-write-alert (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid before after jsonl rc
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-zero-$$"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.findings = [{ categories:['workflow'], severity:'notice', detail:'pre-existing', reporter:'test', timestamp:new Date().toISOString() }];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    before=$(alert_findings_len "$tmp_node" "$sid")

    jsonl="$tmp/empty.jsonl"
    : > "$jsonl"
    local jsonl_node; jsonl_node="$(to_node_path "$jsonl")"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$WRITE_ALERT" \
        --ingest-generated-jsonl "$jsonl_node" --session-id "$sid" >/dev/null 2>&1
    rc=$?

    after=$(alert_findings_len "$tmp_node" "$sid")
    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "ingest-zero: empty file must be no-op exit 0, got $rc"
        return
    fi
    if [ "$after" != "$before" ]; then
        fail "ingest-zero: findings must be unchanged (before=$before after=$after)"
        return
    fi
    pass "ingest-zero: empty file → no-op, exit 0, findings unchanged"
}

# ---------------------------------------------------------------------------
# (ingest malformed) 1 invalid-JSON line + 1 valid → valid appended, bad skipped, exit 0
# ---------------------------------------------------------------------------
run_ingest_malformed() {
    if ! grep -q -- "--ingest-generated-jsonl" "$WRITE_ALERT" 2>/dev/null; then
        skip "ingest-malformed: --ingest-generated-jsonl flag not yet in supervisor-write-alert (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid before after jsonl rc
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-mal-$$"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
const fs = require('fs');
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(s.createEmptyState('$sid')));
" >/dev/null 2>&1

    before=$(alert_findings_len "$tmp_node" "$sid")

    jsonl="$tmp/mal.jsonl"
    {
        printf '%s\n' 'this-is-not-json{{{'
        printf '{"categories":["security"],"severity":"error","detail":"valid after bad","reporter":"supervisor"}\n'
    } > "$jsonl"
    local jsonl_node; jsonl_node="$(to_node_path "$jsonl")"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$WRITE_ALERT" \
        --ingest-generated-jsonl "$jsonl_node" --session-id "$sid" >/dev/null 2>&1
    rc=$?

    after=$(alert_findings_len "$tmp_node" "$sid")
    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "ingest-malformed: fail-open must exit 0, got $rc"
        return
    fi
    if [ "$before" = "null" ] || [ "$after" = "null" ]; then
        fail "ingest-malformed: state unreadable (before=$before after=$after)"
        return
    fi
    # exactly one valid finding appended; bad line skipped.
    if [ "$after" != "$((before + 1))" ]; then
        fail "ingest-malformed: exactly 1 valid finding must be appended (before=$before after=$after)"
        return
    fi
    pass "ingest-malformed: bad line skipped, valid appended (+1), exit 0 (fail-open)"
}

# ---------------------------------------------------------------------------
# (ingest mutual-exclusion) --ingest-generated-jsonl <f> --drop-finding-ids x
#   → rejected (non-zero / error), no state mutation
# ---------------------------------------------------------------------------
run_ingest_mutual_exclusion() {
    if ! grep -q -- "--ingest-generated-jsonl" "$WRITE_ALERT" 2>/dev/null; then
        skip "ingest-mutex: --ingest-generated-jsonl flag not yet in supervisor-write-alert (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid before after jsonl rc
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-mutex-$$"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.findings = [{ categories:['workflow'], severity:'warning', detail:'pre', reporter:'test', status:'draft', idx:0, timestamp:new Date().toISOString() }];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    before=$(alert_findings_len "$tmp_node" "$sid")

    jsonl="$tmp/mx.jsonl"
    printf '{"categories":["code"],"severity":"error","detail":"should-not-append","reporter":"supervisor"}\n' > "$jsonl"
    local jsonl_node; jsonl_node="$(to_node_path "$jsonl")"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$WRITE_ALERT" \
        --ingest-generated-jsonl "$jsonl_node" --drop-finding-ids 0 --session-id "$sid" >/dev/null 2>&1
    rc=$?

    after=$(alert_findings_len "$tmp_node" "$sid")
    rm -rf "$tmp"

    if [ "$rc" -eq 0 ]; then
        fail "ingest-mutex: combining --ingest-generated-jsonl with --drop-finding-ids must be rejected (non-zero)"
        return
    fi
    # Negative assertion: protected resource (findings) unchanged.
    if [ "$after" != "$before" ]; then
        fail "ingest-mutex: rejected invocation must not mutate state (before=$before after=$after)"
        return
    fi
    pass "ingest-mutex: --ingest-generated-jsonl + --drop-finding-ids rejected, no state mutation"
}

run_generate_unavailable
run_generate_backcompat
run_ingest_happy
run_ingest_zero_record
run_ingest_malformed
run_ingest_mutual_exclusion

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

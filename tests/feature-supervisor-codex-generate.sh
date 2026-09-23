#!/usr/bin/env bash
# tests/feature-supervisor-codex-generate.sh
# Tests: bin/supervisor-findings-codex, bin/supervisor-write-alert, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, codex, findings-codex, status-skipped, ingest-jsonl, alert, scope:issue-specific, pwsh-not-required, hook-registration
# NOTE: RED until write-code adds bin/supervisor-findings-codex and the
#   supervisor-write-alert --ingest-generated-jsonl flag (#929). Guarded cases SKIP as
#   RED-EXPECTED until then. Detail: detail.md Step 8 (SSOT for the STATUS/OUTFILE protocol).

set -u

# supervisor-review-codex --generate is retired; the shared alert/audit engine
# bin/supervisor-findings-codex emits a STATUS line first (SKIPPED/SUCCESS/FAILED) and
# prints OUTFILE (validated JSONL, os.tmpdir) ONLY on STATUS: SUCCESS. write-alert
# --ingest-generated-jsonl <OUTFILE> then JSON.parse-appends each finding (fail-open,
# zero-record no-op, mutually exclusive with --confirm/--drop-finding-ids). Ingest is
# gated on OUTFILE presence, so STATUS != SUCCESS reaches no ingest.

# TL3 gap (NOT caught here — test env has no codex): real Codex CLI SUCCESS + os.tmpdir
#   OUTFILE generation and end-to-end ingest; agents/supervisor.md single-shot protocol in
#   a live claude -p session. Mitigation: WORKFLOW_USER_VERIFIED preflight (hook-registration).

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

FINDINGS_CODEX="$AGENTS_DIR/bin/supervisor-findings-codex"
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
# (B: STATUS protocol) --mode alert with Codex unavailable →
#   first line STATUS: SKIPPED, NO OUTFILE line, NO finding JSONL, exit 0.
# ---------------------------------------------------------------------------
run_alert_status_skipped() {
    if [ ! -f "$FINDINGS_CODEX" ]; then
        skip "alert-status-skipped: bin/supervisor-findings-codex not present (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid out rc first
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-alert-$$"

    # Force codex-unavailable via a PATH that has no 'codex'.
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" PATH="/usr/bin:/bin" \
        run_with_timeout 20 bash "$FINDINGS_CODEX" --mode alert --sid "$sid" --wsid UNAVAILABLE 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "alert-status-skipped: exit must be 0 when codex unavailable, got $rc"
        return
    fi
    first=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -n 1)
    if [ "$first" != "STATUS: SKIPPED" ]; then
        fail "alert-status-skipped: first non-blank line must be 'STATUS: SKIPPED', got: $first"
        return
    fi
    if printf '%s\n' "$out" | grep -q '^OUTFILE:'; then
        fail "alert-status-skipped: no OUTFILE line may be emitted on SKIPPED (OUTFILE is SUCCESS-only)"
        return
    fi
    if printf '%s\n' "$out" | grep -q '"categories"'; then
        fail "alert-status-skipped: no finding JSONL may be emitted on SKIPPED"
        return
    fi
    pass "alert-status-skipped: codex unavailable → STATUS: SKIPPED, no OUTFILE, no findings, exit 0"
}

# ---------------------------------------------------------------------------
# (B: audit STATUS protocol) --mode audit with Codex unavailable →
#   first line STATUS: SKIPPED, NO OUTFILE line, exit 0 (CPR-ORTH sibling of alert).
# ---------------------------------------------------------------------------
run_audit_status_skipped() {
    if [ ! -f "$FINDINGS_CODEX" ]; then
        skip "audit-status-skipped: bin/supervisor-findings-codex not present (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid out rc first
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-audit-$$"

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" PATH="/usr/bin:/bin" \
        run_with_timeout 20 bash "$FINDINGS_CODEX" --mode audit --sid "$sid" --wsid UNAVAILABLE 2>/dev/null)
    rc=$?
    rm -rf "$tmp"

    if [ "$rc" -ne 0 ]; then
        fail "audit-status-skipped: exit must be 0 when codex unavailable, got $rc"
        return
    fi
    first=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -n 1)
    if [ "$first" != "STATUS: SKIPPED" ]; then
        fail "audit-status-skipped: first non-blank line must be 'STATUS: SKIPPED', got: $first"
        return
    fi
    if printf '%s\n' "$out" | grep -q '^OUTFILE:'; then
        fail "audit-status-skipped: no OUTFILE line may be emitted on SKIPPED"
        return
    fi
    pass "audit-status-skipped: codex unavailable → STATUS: SKIPPED, no OUTFILE, exit 0"
}

# ---------------------------------------------------------------------------
# (B: integration C4) STATUS≠SUCCESS ⇒ no OUTFILE ⇒ ingest is not reached.
# Drives the real orchestrator linkage: parse STATUS/OUTFILE from findings-codex,
# ingest ONLY when an OUTFILE was printed. On codex-absent (SKIPPED) the findings
# must stay unchanged because there is nothing validated to ingest.
# ---------------------------------------------------------------------------
run_integration_no_outfile_no_ingest() {
    if [ ! -f "$FINDINGS_CODEX" ]; then
        skip "integration-no-outfile: bin/supervisor-findings-codex not present (RED-EXPECTED)"
        return
    fi
    if ! grep -q -- "--ingest-generated-jsonl" "$WRITE_ALERT" 2>/dev/null; then
        skip "integration-no-outfile: --ingest-generated-jsonl not yet in supervisor-write-alert (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid before after out outfile
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-int-$$"

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.findings = [{ categories:['workflow'], severity:'notice', detail:'pre-existing', reporter:'test', timestamp:new Date().toISOString() }];
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    before=$(alert_findings_len "$tmp_node" "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" PATH="/usr/bin:/bin" \
        run_with_timeout 20 bash "$FINDINGS_CODEX" --mode alert --sid "$sid" --wsid UNAVAILABLE 2>/dev/null)

    # Orchestrator linkage: ingest ONLY when an OUTFILE line was printed.
    outfile=$(printf '%s\n' "$out" | grep '^OUTFILE:' | head -n 1 | sed 's/^OUTFILE:[[:space:]]*//')
    if [ -n "$outfile" ]; then
        WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 node "$WRITE_ALERT" \
            --ingest-generated-jsonl "$outfile" --session-id "$sid" >/dev/null 2>&1
    fi

    after=$(alert_findings_len "$tmp_node" "$sid")
    rm -rf "$tmp"

    if [ -n "$outfile" ]; then
        fail "integration-no-outfile: SKIPPED status must not print an OUTFILE (got: $outfile)"
        return
    fi
    if [ "$after" != "$before" ]; then
        fail "integration-no-outfile: no OUTFILE means ingest must not run — findings changed (before=$before after=$after)"
        return
    fi
    pass "integration-no-outfile: STATUS≠SUCCESS ⇒ no OUTFILE ⇒ ingest not reached, findings unchanged"
}

# ---------------------------------------------------------------------------
# (ingest happy-path) 2 valid finding objects → findings length +2, fields round-trip
# ---------------------------------------------------------------------------
run_ingest_happy() {
    if ! grep -q -- "--ingest-generated-jsonl" "$WRITE_ALERT" 2>/dev/null; then
        skip "ingest-happy: --ingest-generated-jsonl flag not yet in supervisor-write-alert (RED-EXPECTED)"
        return
    fi

    local tmp tmp_node sid before after jsonl d1 d2 rc rt
    tmp=$(make_tmp); tmp_node="$(to_node_path "$tmp")"
    sid="cg-ing-$$"

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
    rc=$?

    after=$(alert_findings_len "$tmp_node" "$sid")

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
    if [ "$after" != "$before" ]; then
        fail "ingest-mutex: rejected invocation must not mutate state (before=$before after=$after)"
        return
    fi
    pass "ingest-mutex: --ingest-generated-jsonl + --drop-finding-ids rejected, no state mutation"
}

run_alert_status_skipped
run_audit_status_skipped
run_integration_no_outfile_no_ingest
run_ingest_happy
run_ingest_zero_record
run_ingest_malformed
run_ingest_mutual_exclusion

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

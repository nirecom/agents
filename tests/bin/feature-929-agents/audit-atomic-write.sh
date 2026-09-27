# audit-atomic-write.sh — fragment of tests/bin/feature-929-agents.sh (no frontmatter).
# Source: bin/supervisor-write-audit-verdict, hooks/lib/supervisor-state-writer/audit-run.js (R3-C2/C5).
# NOTE: RED until write-code adds --findings-jsonl + CAS-success findings merge (#929);
#   the flag is unknown now, so the CLI exits 1 (usage) and no findings are written.

SSW_JS="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

_aaw_arm() {
    # Arms a fresh audit run (no cwd -> no git); echoes the minted run id.
    run_with_timeout 30 node -e '
const w = require(process.argv[1]);
const r = w.armAuditRun(process.argv[2], {});
process.stdout.write(String(r && r.audit_run_id));
' "$SSW_JS" "$1" 2>/dev/null
}

_aaw_read() {
    # Prints: verdict / audit-finding details / layer1-finding details.
    run_with_timeout 30 node -e '
const w = require(process.argv[1]);
const s = w.readState(process.argv[2]) || {};
const au = s.audit || {};
const af = Array.isArray(au.findings) ? au.findings : [];
const l1 = (s.layer1 && Array.isArray(s.layer1.findings)) ? s.layer1.findings : [];
console.log("verdict=" + (au.audit_verdict || "NULL"));
console.log("auditfind=" + JSON.stringify(af.map((f) => f && f.detail)));
console.log("layer1find=" + JSON.stringify(l1.map((f) => f && f.detail)));
' "$SSW_JS" "$3" 2>/dev/null
}

_aaw_run() {
    echo ""
    echo "--- audit-atomic-write (R3-C2/C5) ---"

    # Case 1: matching run id + --findings-jsonl -> verdict AND findings written.
    local sid1="sid-aaw1-$RANDOM$RANDOM"
    local run1; run1="$(_aaw_arm "$sid1")"
    local fj1="$TMPDIR_BASE/aaw-findings-1.jsonl"
    printf '{"categories":["workflow"],"severity":"warning","detail":"atomic-write finding sentinel alpha-6291"}\n' > "$fj1"
    WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" run_with_timeout 30 node "$WRITE_AUDIT_CLI" \
        --session-id "$sid1" --audit-run-id "$run1" --verdict WARN \
        --verdict-summary "atomic path" --findings-jsonl "$fj1" >/dev/null 2>&1
    local st1; st1="$(_aaw_read "$sid1" "$run1" "$sid1")"
    assert_contains "aaw(1): verdict WARN written on CAS success" "$st1" "verdict=WARN"
    assert_contains "aaw(1): --findings-jsonl finding merged in same commit" "$st1" "alpha-6291"

    # Case 2 (R3-C5): stale run id -> exit 3, no verdict, no finding leak.
    local sid2="sid-aaw2-$RANDOM$RANDOM"
    local run2; run2="$(_aaw_arm "$sid2")"
    local fj2="$TMPDIR_BASE/aaw-findings-2.jsonl"
    printf '{"categories":["workflow"],"severity":"error","detail":"stale superseded finding sentinel beta-7734"}\n' > "$fj2"
    WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" run_with_timeout 30 node "$WRITE_AUDIT_CLI" \
        --session-id "$sid2" --audit-run-id "run-9999" --verdict BLOCK \
        --verdict-summary "stale" --findings-jsonl "$fj2" >/dev/null 2>&1
    local rc_stale=$?
    assert_eq "aaw(2): stale run id exits 3 (EXIT_STALE_IDENTITY)" "3" "$rc_stale"
    local st2; st2="$(_aaw_read "$sid2" "$run2" "$sid2")"
    assert_contains "aaw(2): stale run leaves audit_verdict null" "$st2" "verdict=NULL"
    assert_not_contains "aaw(2): stale finding must not leak into audit findings" "$st2" "beta-7734"

    # Case 3: fallback path (no --findings-jsonl) still writes verdict under CAS.
    local sid3="sid-aaw3-$RANDOM$RANDOM"
    local run3; run3="$(_aaw_arm "$sid3")"
    WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR" run_with_timeout 30 node "$WRITE_AUDIT_CLI" \
        --session-id "$sid3" --audit-run-id "$run3" --verdict CONTINUE \
        --verdict-summary "manual fallback verdict" >/dev/null 2>&1
    local st3; st3="$(_aaw_read "$sid3" "$run3" "$sid3")"
    assert_contains "aaw(3): manual (no findings-jsonl) verdict still accepted" "$st3" "verdict=CONTINUE"
}

_aaw_run

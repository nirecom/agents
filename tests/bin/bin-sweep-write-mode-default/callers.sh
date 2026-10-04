# ─────────────────────────────────────────────────────────────────────────────
# C1. Nightly cron must pin the non-destructive intent explicitly.
# ─────────────────────────────────────────────────────────────────────────────

C1_cron_flags_updated() {
    if [ ! -f "$SWEEP_YML" ]; then
        fail "C1 cron: $SWEEP_YML not found"
        return
    fi
    local wt at atc
    wt="$(grep -n 'sweep-worktrees\.sh' "$SWEEP_YML" | head -1)"
    at="$(grep -n 'audit-tests\.sh' "$SWEEP_YML" | head -1)"
    atc="$(grep -n 'audit-tests-common\.sh' "$SWEEP_YML" | head -1)"

    if [ -n "$wt" ] && ! echo "$wt" | grep -q -- '--apply'; then
        pass "C1a sweep.yml sweep-worktrees step no longer passes --apply"
    else
        fail "C1a sweep.yml sweep-worktrees step still passes --apply: $wt"
    fi
    if echo "$at" | grep -q -- '--dry-run'; then
        pass "C1b sweep.yml audit-tests step passes --dry-run"
    else
        fail "C1b sweep.yml audit-tests step missing --dry-run: $at"
    fi
    if echo "$atc" | grep -q -- '--dry-run'; then
        pass "C1c sweep.yml audit-tests-common step passes --dry-run"
    else
        fail "C1c sweep.yml audit-tests-common step missing --dry-run: $atc"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# C2. No stale "dry-run is the default" prose left in any sweep SKILL.md.
#     Pattern set deliberately broad so a missed rewrite cannot slip through.
# ─────────────────────────────────────────────────────────────────────────────

C2_no_stale_dry_run_prose() {
    local hits
    hits="$(grep -rniE 'Default is dry-run|Dry-run by default|Default is report-only|no --apply = dry-run' \
        "$AGENTS_DIR"/skills/sweep*/SKILL.md 2>/dev/null || true)"
    if [ -z "$hits" ]; then
        pass "C2 no stale dry-run-default prose in skills/sweep*/SKILL.md"
    else
        fail "C2 stale dry-run-default prose remains:"$'\n'"$hits"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

D1_sweep_supervisor_state_is_dry_run_by_default() {
    local sweep="$AGENTS_DIR/bin/sweep-supervisor-state.sh"
    if [ ! -f "$sweep" ]; then
        fail "D1 exception member: $sweep does not exist"
        return
    fi

    local plans="$TMPDIR_BASE/d1-plans"
    local plans_node
    mkdir -p "$plans"
    if command -v cygpath >/dev/null 2>&1; then plans_node="$(cygpath -m "$plans")"; else plans_node="$plans"; fi
    node -e '
const fs = require("fs"), path = require("path");
const now = "2024-01-02T03:04:05.000Z";
const rec = {
  categories: ["workflow"], severity: "warning",
  detail: "escape-hatch sentinel: WORKFLOW_OFF (A1 marker test)",
  reporter: "enforce-override-handlers", record_type: "escape_hatch_event", timestamp: now,
};
const state = {
  version: 1, session_id: "d1sess", created_at: now, last_updated: now,
  layer1: { findings: [rec] },
  alert: { alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [],
           alert_phase: null, alert_cause: null, alert_retry_count: 0,
           findings_surfaced_at: null, alert_eligible_phase: null },
  audit: { audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null,
           audit_cause: null, audit_retry_count: 0, findings: [] },
};
const ctrlDir = path.join(process.argv[1], "d1sess.control");
fs.mkdirSync(ctrlDir, {recursive: true});
fs.writeFileSync(path.join(ctrlDir, "supervisor-state.json"), JSON.stringify(state, null, 2));
' "$plans_node"

    local f="$plans/d1sess.control/supervisor-state.json"
    local before after
    before="$(md5sum "$f" 2>/dev/null | awk '{print $1}')"
    env -u AGENTS_CONFIG_DIR "WORKFLOW_PLANS_DIR=$plans_node" "CLAUDE_WORKFLOW_DIR=$plans_node" \
        run_with_timeout bash "$sweep" >/dev/null 2>&1
    after="$(md5sum "$f" 2>/dev/null | awk '{print $1}')"

    if [ -n "$before" ] && [ "$before" = "$after" ]; then
        pass "D1a sweep-supervisor-state flagless run writes nothing (dry-run default exception)"
    else
        fail "D1a sweep-supervisor-state flagless run modified state: before=$before after=$after"
    fi
    if [ ! -d "$plans/.sweep-supervisor-state-backup" ]; then
        pass "D1b sweep-supervisor-state flagless run creates no backup directory"
    else
        fail "D1b sweep-supervisor-state flagless run created a backup dir — it wrote something"
    fi
}

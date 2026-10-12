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
        "$SCRIPT_CHECKOUT_ROOT"/skills/sweep*/SKILL.md 2>/dev/null || true)"
    if [ -z "$hits" ]; then
        pass "C2 no stale dry-run-default prose in skills/sweep*/SKILL.md"
    else
        fail "C2 stale dry-run-default prose remains:"$'\n'"$hits"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

D1_sweep_supervisor_state_is_dry_run_by_default() {
    local sweep="$SCRIPT_CHECKOUT_ROOT/bin/sweep-supervisor-state.sh"
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
    run_with_timeout env "WORKFLOW_PLANS_DIR=$plans_node" "WORKFLOW_STATE_DIR=$plans_node" \
        bash "$sweep" >/dev/null 2>&1
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

# ─────────────────────────────────────────────────────────────────────────────
# D2. sweep-plans: the flagless (and --apply) write scope is non-plan files only;
#     plan and user-requested files of a stale group are kept.
# ─────────────────────────────────────────────────────────────────────────────

_d2_make_group() {
    local plans="$1" sid="$2" f
    mkdir -p "$plans"
    for f in "$sid-intent.md" "$sid-user-requested-x.md" "$sid-outline-codex-round-1-raw.md"; do
        printf 'd2 fixture\n' > "$plans/$f"
        touch -d "60 days ago" "$plans/$f" 2>/dev/null || touch -t 202401010000 "$plans/$f"
    done
}

_d2_run() {
    local plans="$1"; shift
    local plans_node="$plans"
    if command -v cygpath >/dev/null 2>&1; then plans_node="$(cygpath -m "$plans")"; fi
    run_with_timeout env "WORKFLOW_PLANS_DIR=$plans_node" "WORKFLOW_STATE_DIR=$plans_node.state" \
        bash "$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans.sh" "$@" >/dev/null 2>&1
}

D2_sweep_plans_flagless_keeps_plan_and_user_requested() {
    local sweep="$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans.sh"
    if [ ! -f "$sweep" ]; then
        fail "D2 exception member: $sweep does not exist"
        return
    fi
    local sid="d2000000-0000-4000-8000-000000000d02"

    local plans="$TMPDIR_BASE/d2-plans"
    _d2_make_group "$plans" "$sid"
    _d2_run "$plans"
    if [ -f "$plans/$sid-intent.md" ]; then
        pass "D2a flagless sweep-plans keeps the stale group's plan file (intent)"
    else
        fail "D2a flagless sweep-plans deleted the stale group's plan file (intent)"
    fi
    if [ -f "$plans/$sid-user-requested-x.md" ]; then
        pass "D2b flagless sweep-plans keeps the stale group's user-requested file"
    else
        fail "D2b flagless sweep-plans deleted the stale group's user-requested file"
    fi
    if [ ! -f "$plans/$sid-outline-codex-round-1-raw.md" ]; then
        pass "D2c flagless sweep-plans removes the stale group's non-plan file (codex raw)"
    else
        fail "D2c flagless sweep-plans kept the stale group's non-plan file (codex raw) — the default still writes nothing"
    fi

    local plans_apply="$TMPDIR_BASE/d2-plans-apply"
    _d2_make_group "$plans_apply" "$sid"
    _d2_run "$plans_apply" --apply
    if [ -f "$plans_apply/$sid-intent.md" ] && [ -f "$plans_apply/$sid-user-requested-x.md" ]; then
        pass "D2d --apply does not widen the scope: intent and user-requested are kept"
    else
        fail "D2d --apply widened the scope: intent=$([ -f "$plans_apply/$sid-intent.md" ] && echo kept || echo DELETED) user-requested=$([ -f "$plans_apply/$sid-user-requested-x.md" ] && echo kept || echo DELETED)"
    fi
}

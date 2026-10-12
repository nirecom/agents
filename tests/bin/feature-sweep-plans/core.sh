#!/bin/bash
# tests/bin/feature-sweep-plans/core.sh
# Tests: bin/sweep-plans.sh, skills/sweep-plans/SKILL.md
# Tags: sweep, plans, workflow-plans, maintenance, bin, scope:common
#
# Core sweep-plans tests: candidate grouping, apply/dry-run, subdir
# preservation, JSON shape. SWEEP_AGE_DAYS validation lives in validation.sh.
# Sourced helpers come from _lib.sh. Runnable standalone:
#   bash tests/bin/feature-sweep-plans/core.sh

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T1 — empty plans dir → groups_candidates=0, exit 0
# ─────────────────────────────────────────────────────────────────────────────

T1_empty_plans_dir() {
    local plans_dir="$TMPDIR_BASE/t1-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T1 empty_plans_dir: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T1 empty_plans_dir: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" groups_candidates)"
    if [ "${n:-0}" = "0" ]; then
        pass "T1 empty_plans_dir (groups_candidates=0)"
    else
        fail "T1 empty_plans_dir: groups_candidates=${n:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T2 — YYYYMMDD-HHMMSS session group, backdated, dry-run → candidate listed,
#      files still present, groups_candidates>=1
# ─────────────────────────────────────────────────────────────────────────────

T2_yyyymmdd_group_dry_run_candidate() {
    local plans_dir="$TMPDIR_BASE/t2-plans"
    mkdir -p "$plans_dir"
    local sid="20260101-120000"
    local f1="$plans_dir/${sid}-intent.md"
    local f2="$plans_dir/${sid}-outline.md"
    local f3="$plans_dir/${sid}-detail.md"
    printf 'intent\n' > "$f1"
    printf 'outline\n' > "$f2"
    printf 'detail\n' > "$f3"
    backdate "$f1"
    backdate "$f2"
    backdate "$f3"

    if [ ! -f "$SWEEP" ]; then
        fail "T2 yyyymmdd_group_dry_run_candidate: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T2 yyyymmdd_group_dry_run_candidate: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" groups_candidates)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null && [ -f "$f1" ] && [ -f "$f2" ] && [ -f "$f3" ]; then
        pass "T2 yyyymmdd_group_dry_run_candidate (groups_candidates>=1, files preserved)"
    else
        fail "T2 yyyymmdd_group_dry_run_candidate: groups_candidates=${n:-?}, f1_present=$([ -f "$f1" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T3 — same group with --apply → the non-plan file is removed (groups_removed=1)
#      while the plan files (intent/outline/detail) are kept.
# ─────────────────────────────────────────────────────────────────────────────

T3_yyyymmdd_group_apply_removes_non_plan_keeps_plan() {
    local plans_dir="$TMPDIR_BASE/t3-plans"
    mkdir -p "$plans_dir"
    local sid="20260101-130000"
    local f1="$plans_dir/${sid}-intent.md"
    local f2="$plans_dir/${sid}-outline.md"
    local f3="$plans_dir/${sid}-detail.md"
    local f4="$plans_dir/${sid}-detail-codex-round-1-raw.md"
    printf 'intent\n' > "$f1"
    printf 'outline\n' > "$f2"
    printf 'detail\n' > "$f3"
    printf 'raw\n' > "$f4"
    backdate "$f1"
    backdate "$f2"
    backdate "$f3"
    backdate "$f4"

    local label="T3 yyyymmdd_group_apply_removes_non_plan_keeps_plan"
    if [ ! -f "$SWEEP" ]; then
        fail "$label: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "$label: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" groups_removed)"
    if [ "${n:-0}" = "1" ] && [ ! -f "$f4" ] && [ -f "$f1" ] && [ -f "$f2" ] && [ -f "$f3" ]; then
        pass "$label (groups_removed=1, raw gone, intent/outline/detail kept)"
    else
        fail "$label: groups_removed=${n:-?}, raw_present=$([ -f "$f4" ] && echo y || echo n), intent/outline/detail_present=$([ -f "$f1" ] && echo y || echo n)/$([ -f "$f2" ] && echo y || echo n)/$([ -f "$f3" ] && echo y || echo n), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T4 — UUID-format group → dry-run: groups_candidates>=1
# ─────────────────────────────────────────────────────────────────────────────

T4_uuid_group_dry_run_candidate() {
    local plans_dir="$TMPDIR_BASE/t4-plans"
    mkdir -p "$plans_dir"
    local sid="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    local f1="$plans_dir/${sid}-intent.md"
    local f2="$plans_dir/${sid}-outline.md"
    local f3="$plans_dir/${sid}-detail.md"
    printf 'intent\n' > "$f1"
    printf 'outline\n' > "$f2"
    printf 'detail\n' > "$f3"
    backdate "$f1"
    backdate "$f2"
    backdate "$f3"

    if [ ! -f "$SWEEP" ]; then
        fail "T4 uuid_group_dry_run_candidate: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T4 uuid_group_dry_run_candidate: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" groups_candidates)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        pass "T4 uuid_group_dry_run_candidate (groups_candidates>=1)"
    else
        fail "T4 uuid_group_dry_run_candidate: groups_candidates=${n:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T5 — mixed group (newest fresh, oldest backdated) → entire group skipped;
#      groups_skipped_young>=1
# ─────────────────────────────────────────────────────────────────────────────

T5_mixed_group_skipped_young() {
    local plans_dir="$TMPDIR_BASE/t5-plans"
    mkdir -p "$plans_dir"
    local sid="20260102-120000"
    local f1="$plans_dir/${sid}-intent.md"
    local f2="$plans_dir/${sid}-outline.md"
    local f3="$plans_dir/${sid}-detail.md"
    printf 'intent\n' > "$f1"
    printf 'outline\n' > "$f2"
    printf 'detail\n' > "$f3"
    backdate "$f1"
    backdate "$f2"
    # Newest member: leave mtime as now (no backdate).
    touch "$f3" 2>/dev/null || true

    if [ ! -f "$SWEEP" ]; then
        fail "T5 mixed_group_skipped_young: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T5 mixed_group_skipped_young: exit=$exit_code, out=$out"
        return
    fi

    local young
    young="$(ci_field "$out" groups_skipped_young)"
    if [ "${young:-0}" -ge 1 ] 2>/dev/null; then
        pass "T5 mixed_group_skipped_young (groups_skipped_young>=1)"
    else
        fail "T5 mixed_group_skipped_young: groups_skipped_young=${young:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T6 — cache/ and markers/ subdirectories with old mtime → NOT touched
#      after --apply (dirs and the files inside them still exist)
# ─────────────────────────────────────────────────────────────────────────────

T6_subdirs_not_touched() {
    local plans_dir="$TMPDIR_BASE/t6-plans"
    mkdir -p "$plans_dir/cache" "$plans_dir/markers"
    # Session-prefixed non-plan names too: deletable at depth 1, so only the depth guard keeps them.
    local -a t6_files=(cache/something.json markers/something.marker
        cache/20260101-150000-survey-code.md markers/a1b2c3d4-e5f6-7890-abcd-ef1234567890-detail-codex-round-1-raw.md)
    local nf
    for nf in "${t6_files[@]}"; do
        printf 'x\n' > "$plans_dir/$nf"
        backdate "$plans_dir/$nf"
    done
    backdate "$plans_dir/cache"
    backdate "$plans_dir/markers"

    if [ ! -f "$SWEEP" ]; then
        fail "T6 subdirs_not_touched: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T6 subdirs_not_touched: exit=$exit_code, out=$out"
        return
    fi

    if [ -d "$plans_dir/cache" ] && [ -d "$plans_dir/markers" ]; then
        pass "T6 subdirs_not_touched (cache/ and markers/ preserved)"
    else
        fail "T6 subdirs_not_touched: cache_present=$([ -d "$plans_dir/cache" ] && echo y || echo n), markers_present=$([ -d "$plans_dir/markers" ] && echo y || echo n), out=$out"
    fi

    local f
    for f in "${t6_files[@]}"; do
        if [[ -f "$plans_dir/$f" ]]; then
            pass "T6 subdirs_not_touched: $f still exists after --apply"
        else
            fail "T6 subdirs_not_touched: $f removed by --apply, out=$out"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# T7 — --ci-mode JSON shape: required keys present
# ─────────────────────────────────────────────────────────────────────────────

T7_ci_mode_json_shape() {
    local plans_dir="$TMPDIR_BASE/t7-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T7 ci_mode_json_shape: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>/dev/null)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T7 ci_mode_json_shape: exit=$exit_code, out=$out"
        return
    fi

    local check
    check="$(printf '%s' "$out" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const lines = b.split(/\r?\n/);
            let parsed = null;
            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed.startsWith('{')) continue;
                try { parsed = JSON.parse(trimmed); break; } catch (e) { /* skip */ }
            }
            if (!parsed) { console.log('PARSE_ERROR'); return; }
            const required = ['scanned','groups_candidates','groups_removed','groups_skipped_young','groups_skipped_revived','files_removed','errors',
                'files_non_plan_candidates','files_plan_candidates','files_user_requested_candidates','files_unknown_kept',
                'groups_approval_candidates','approval_candidates','gate_id','approval_skipped',
                'files_plan_removed','files_user_requested_removed','classifier_failed'];
            const missing = required.filter(k => !(k in parsed));
            if (missing.length) { console.log('MISSING:' + missing.join(',')); return; }
            if (!Array.isArray(parsed.approval_candidates) || !Array.isArray(parsed.approval_skipped)) { console.log('NOT_ARRAY'); return; }
            if (parsed.gate_id !== null) { console.log('GATE_ID_NOT_NULL'); return; }
            console.log('OK');
        });
    " 2>/dev/null)"

    case "$check" in
        OK) pass "T7 ci_mode_json_shape" ;;
        *)  fail "T7 ci_mode_json_shape: $check; raw=$out" ;;
    esac

    # --ci-mode stdout is exactly one line (the JSON); text lines go to stderr.
    local n_lines
    n_lines="$(printf '%s\n' "$out" | tr -d '\r' | grep -c .)"
    if [ "$n_lines" = "1" ]; then
        pass "T7 ci_mode_stdout_is_exactly_one_line"
    else
        fail "T7 ci_mode_stdout_is_exactly_one_line: $n_lines non-empty lines; raw=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T8 — SESSION_PREFIX_RE accept/reject table (bin/sweep-plans/discover.sh).
#      Each row: an old <prefix>-intent.md + <prefix>-survey-code.md pair run
#      through --apply. Accepted → grouped under <want> and the non-plan removed;
#      rejected → never grouped, both files kept.
# ─────────────────────────────────────────────────────────────────────────────

T8_session_prefix_table() {
    local name prefix want n=0
    while IFS='|' read -r name prefix want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; prefix="${prefix//[[:space:]]/}"; want="${want//[[:space:]]/}"
        n=$((n + 1))
        t8_row "$name" "$prefix" "$want" "$TMPDIR_BASE/t8-$n-plans"
    done <<'TABLE'
# name                 | prefix                                  | grouped key, or none
yyyymmdd-hhmmss        | 20260101-120000                         | 20260101-120000
uuid-v4                | a1b2c3d4-e5f6-4890-abcd-ef1234567890    | a1b2c3d4-e5f6-4890-abcd-ef1234567890
uuid-all-digits        | 12345678-1234-1234-1234-123456789012    | 12345678-1234-1234-1234-123456789012
epoch-pid              | 1700000000-4242                         | 1700000000-4242
epoch-pid-one-digit    | 1700000000-7                            | 1700000000-7
uuid-uppercase         | A1B2C3D4-E5F6-4890-ABCD-EF1234567890    | none
uuid-non-hex           | g1b2c3d4-e5f6-4890-abcd-ef1234567890    | none
uuid-short-last        | a1b2c3d4-e5f6-4890-abcd-ef123456789     | none
uuid-missing-segment   | a1b2c3d4-e5f6-4890-ef1234567890         | none
date-short             | 2026010-120000                          | none
time-short             | 20260101-12000                          | none
epoch-9-digits         | 170000000-4242                          | none
epoch-11-digits        | 17000000000-4242                        | none
epoch-pid-non-digit    | 1700000000-ab                           | none
word-prefix            | session                                 | none
TABLE
}

# t8_row <name> <prefix> <want> <plans_dir>
t8_row() {
    local name="$1" prefix="$2" want="$3" plans_dir="$4" label out err rc
    label="T8 [$name] prefix=$prefix"
    mkdir -p "$plans_dir"
    printf 'i\n' > "$plans_dir/$prefix-intent.md"
    printf 's\n' > "$plans_dir/$prefix-survey-code.md"
    backdate "$plans_dir/$prefix-intent.md"
    backdate "$plans_dir/$prefix-survey-code.md"

    # The include flag (no --gate-session: deletion scope unchanged) keeps the PLAN-CANDIDATE line naming the key.
    rc=0
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode --include-plan-and-user-requested 2>"$plans_dir.err")" || rc=$?
    err="$(tr -d '\r' < "$plans_dir.err")"
    if [[ "$rc" -ne 0 ]]; then
        fail "$label: exit=$rc, out=$out"
        return
    fi

    local cands intent_kept survey_kept
    cands="$(ci_field "$out" groups_candidates)"
    intent_kept="$([[ -f "$plans_dir/$prefix-intent.md" ]] && echo y || echo n)"
    survey_kept="$([[ -f "$plans_dir/$prefix-survey-code.md" ]] && echo y || echo n)"
    if [[ "$want" == "none" ]]; then
        if [[ "$cands" == "0" && "$intent_kept" == "y" && "$survey_kept" == "y" ]]; then
            pass "$label rejected (not grouped, both files kept)"
        else
            fail "$label rejected: groups_candidates=${cands:-?} intent_kept=$intent_kept survey_kept=$survey_kept, out=$out"
        fi
    elif [[ "$cands" == "1" && "$intent_kept" == "y" && "$survey_kept" == "n" ]] \
        && printf '%s\n' "$err" | grep -qF -- "PLAN-CANDIDATE: session=$want files=1 "; then
        pass "$label grouped as $want (non-plan removed, plan kept)"
    else
        fail "$label grouped: groups_candidates=${cands:-?} intent_kept=$intent_kept survey_kept=$survey_kept, err=$err"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

T1_empty_plans_dir
T2_yyyymmdd_group_dry_run_candidate
T3_yyyymmdd_group_apply_removes_non_plan_keeps_plan
T4_uuid_group_dry_run_candidate
T5_mixed_group_skipped_young
T6_subdirs_not_touched
T7_ci_mode_json_shape
T8_session_prefix_table

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

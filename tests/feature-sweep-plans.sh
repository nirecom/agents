#!/bin/bash
# tests/feature-sweep-plans.sh
# Tests: bin/sweep-plans.sh, skills/sweep-plans/SKILL.md
# Tags: sweep, plans, workflow-plans, maintenance, bin
#
# Tests for bin/sweep-plans.sh — the workflow-plans sweep mechanism that
# cleans up old session artifacts under $WORKFLOW_PLANS_DIR (~/.workflow-plans
# by default).
#
# Contract under test:
#   bin/sweep-plans.sh [--dry-run|--apply] [--ci-mode]
#
# A "candidate" for sweep is a group of files in WORKFLOW_PLANS_DIR sharing a
# common session-id stem (YYYYMMDD-HHMMSS or UUID) whose:
#   - oldest member's mtime is older than SWEEP_AGE_DAYS (default 30)
#   - newest member's mtime is also older than SWEEP_AGE_DAYS (mixed groups
#     with a freshly-touched member are skipped as "young")
#
# Outputs:
#   --dry-run    → human-readable list (per-group + summary)
#   --ci-mode    → JSON with keys: scanned, groups_candidates, groups_removed,
#                  groups_skipped_young, files_removed, errors
#
# Validation: SWEEP_AGE_DAYS=0 or non-numeric → exit 2 with stderr message.
#
# Source bin/sweep-plans.sh does NOT exist yet — all tests RED until impl lands.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-plans.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Backdate file mtime to look "stale" (60 days ago). Portable across GNU/BSD.
backdate() {
    local f="$1"
    touch -d "60 days ago" "$f" 2>/dev/null || touch -t 202401010000 "$f" 2>/dev/null || true
}

# Extract a field from --ci-mode JSON output (may contain non-JSON noise lines).
ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            const lines = b.split(/\r?\n/);
            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed.startsWith('{')) continue;
                try {
                    const d = JSON.parse(trimmed);
                    if (key in d) { console.log(d[key]); return; }
                } catch (e) { /* skip non-JSON */ }
            }
        });
    " -- "$2" 2>/dev/null
}

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
# T3 — same group with --apply → group files removed, groups_removed=1
# ─────────────────────────────────────────────────────────────────────────────

T3_yyyymmdd_group_apply_removes() {
    local plans_dir="$TMPDIR_BASE/t3-plans"
    mkdir -p "$plans_dir"
    local sid="20260101-130000"
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
        fail "T3 yyyymmdd_group_apply_removes: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T3 yyyymmdd_group_apply_removes: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" groups_removed)"
    if [ "${n:-0}" = "1" ] && [ ! -f "$f1" ] && [ ! -f "$f2" ] && [ ! -f "$f3" ]; then
        pass "T3 yyyymmdd_group_apply_removes (groups_removed=1, files gone)"
    else
        fail "T3 yyyymmdd_group_apply_removes: groups_removed=${n:-?}, f1_present=$([ -f "$f1" ] && echo y || echo n), out=$out"
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
#      after --apply (dirs still exist)
# ─────────────────────────────────────────────────────────────────────────────

T6_subdirs_not_touched() {
    local plans_dir="$TMPDIR_BASE/t6-plans"
    mkdir -p "$plans_dir/cache" "$plans_dir/markers"
    printf 'c\n' > "$plans_dir/cache/something.json"
    printf 'm\n' > "$plans_dir/markers/something.marker"
    backdate "$plans_dir/cache/something.json"
    backdate "$plans_dir/markers/something.marker"
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
            const required = ['scanned','groups_candidates','groups_removed','groups_skipped_young','groups_skipped_revived','files_removed','errors'];
            const missing = required.filter(k => !(k in parsed));
            console.log(missing.length === 0 ? 'OK' : 'MISSING:' + missing.join(','));
        });
    " 2>/dev/null)"

    case "$check" in
        OK) pass "T7 ci_mode_json_shape" ;;
        *)  fail "T7 ci_mode_json_shape: $check; raw=$out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T9 — SWEEP_AGE_DAYS=0 → exit non-zero (exit 2), error on stderr
# ─────────────────────────────────────────────────────────────────────────────

T9_sweep_age_days_zero_rejected() {
    local plans_dir="$TMPDIR_BASE/t9-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T9 sweep_age_days_zero_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t9.out"
    local stderr_file="$TMPDIR_BASE/t9.err"
    WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=0 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T9 sweep_age_days_zero_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T9 sweep_age_days_zero_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T10 — SWEEP_AGE_DAYS=abc → exit non-zero, error on stderr
# ─────────────────────────────────────────────────────────────────────────────

T10_sweep_age_days_non_numeric_rejected() {
    local plans_dir="$TMPDIR_BASE/t10-plans"
    mkdir -p "$plans_dir"

    if [ ! -f "$SWEEP" ]; then
        fail "T10 sweep_age_days_non_numeric_rejected: $SWEEP not found"
        return
    fi

    local stdout_file="$TMPDIR_BASE/t10.out"
    local stderr_file="$TMPDIR_BASE/t10.err"
    WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=abc \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode \
        >"$stdout_file" 2>"$stderr_file"
    local exit_code=$?
    local err
    err="$(cat "$stderr_file" 2>/dev/null || true)"

    if [ "$exit_code" -ne 0 ] && [ -n "$err" ]; then
        pass "T10 sweep_age_days_non_numeric_rejected (exit=$exit_code, stderr non-empty)"
    else
        fail "T10 sweep_age_days_non_numeric_rejected: exit=$exit_code, stderr=[$err]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

T1_empty_plans_dir
T2_yyyymmdd_group_dry_run_candidate
T3_yyyymmdd_group_apply_removes
T4_uuid_group_dry_run_candidate
T5_mixed_group_skipped_young
T6_subdirs_not_touched
T7_ci_mode_json_shape
T9_sweep_age_days_zero_rejected
T10_sweep_age_days_non_numeric_rejected

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

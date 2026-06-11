#!/bin/bash
# tests/fix-829-sweep-plans.sh
# Tests: bin/sweep-plans.sh
# Tags: sweep, plans, orphan-prefix, epoch-pid, empty-sid, fix
#
# Tests for issue #829: sweep-plans regex skips orphan staging files with
# unix-epoch-PID or empty session-id prefix.
#
# T8  — epoch-PID prefix (1780226527-4457-...) is grouped as candidate
# T11a — empty-SID prefix (-foo.log) dry-run → groups_candidates=1
# T11b — empty-SID prefix --apply removes file
# T12  — epoch-PID prefix --apply removes file

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
# T8 — epoch-PID files (unix-timestamp-PID prefix) → grouped as candidates;
#      groups_candidates == 1
# ─────────────────────────────────────────────────────────────────────────────

T8_epoch_pid_files_swept() {
    local plans_dir="$TMPDIR_BASE/t8-plans"
    mkdir -p "$plans_dir"
    local f="$plans_dir/1780226527-4457-history-staging.md"
    printf 'not a session artifact\n' > "$f"
    backdate "$f"

    if [ ! -f "$SWEEP" ]; then
        fail "T8 epoch_pid_files_swept: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T8 epoch_pid_files_swept: exit=$exit_code, out=$out"
        return
    fi

    local n
    n="$(ci_field "$out" groups_candidates)"
    if [ "${n:-0}" = "1" ]; then
        pass "T8 epoch_pid_files_swept (groups_candidates=1)"
    else
        fail "T8 epoch_pid_files_swept: groups_candidates=${n:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T11a — empty-SID staging file ("-commit-push-worker.log") dry-run →
#        groups_candidates == 1, groups_skipped_young == 0
# ─────────────────────────────────────────────────────────────────────────────

T11a_empty_sid_dry_run() {
    local plans_dir="$TMPDIR_BASE/t11a-plans"
    mkdir -p "$plans_dir"
    local f="$plans_dir/-commit-push-worker.log"
    printf 'empty-sid staging file\n' > "$f"
    backdate "$f"

    if [ ! -f "$SWEEP" ]; then
        fail "T11a empty_sid_dry_run: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --dry-run --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T11a empty_sid_dry_run: exit=$exit_code, out=$out"
        return
    fi

    local n sk
    n="$(ci_field "$out" groups_candidates)"
    sk="$(ci_field "$out" groups_skipped_young)"
    if [ "${n:-0}" = "1" ] && [ "${sk:-0}" = "0" ]; then
        pass "T11a empty_sid_dry_run (groups_candidates=1, groups_skipped_young=0)"
    else
        fail "T11a empty_sid_dry_run: groups_candidates=${n:-?}, groups_skipped_young=${sk:-?}, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T11b — empty-SID --apply end-to-end: groups_removed=1, files_removed=1,
#        file deleted. Exercises bin/sweep-plans.sh:194 with prefix="" →
#        find -name "-*" path.
# ─────────────────────────────────────────────────────────────────────────────

T11b_empty_sid_apply() {
    local plans_dir="$TMPDIR_BASE/t11b-plans"
    mkdir -p "$plans_dir"
    local f="$plans_dir/-commit-push-worker.log"
    printf 'empty-sid staging file\n' > "$f"
    backdate "$f"

    if [ ! -f "$SWEEP" ]; then
        fail "T11b empty_sid_apply: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T11b empty_sid_apply: exit=$exit_code, out=$out"
        return
    fi

    local nr nf
    nr="$(ci_field "$out" groups_removed)"
    nf="$(ci_field "$out" files_removed)"
    if [ "${nr:-0}" = "1" ] && [ "${nf:-0}" = "1" ] && [ ! -e "$f" ]; then
        pass "T11b empty_sid_apply (groups_removed=1, files_removed=1, file deleted)"
    else
        fail "T11b empty_sid_apply: groups_removed=${nr:-?}, files_removed=${nf:-?}, file_exists=$([ -e "$f" ] && echo yes || echo no), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T12 — epoch-PID --apply end-to-end: groups_removed=1, files_removed=1,
#        file deleted
# ─────────────────────────────────────────────────────────────────────────────

T12_epoch_pid_apply() {
    local plans_dir="$TMPDIR_BASE/t12-plans"
    mkdir -p "$plans_dir"
    local f="$plans_dir/1700000000-12345-intent.md"
    printf 'epoch-pid staging file\n' > "$f"
    backdate "$f"

    if [ ! -f "$SWEEP" ]; then
        fail "T12 epoch_pid_apply: $SWEEP not found"
        return
    fi

    local out exit_code
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" --apply --ci-mode 2>&1)"
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        fail "T12 epoch_pid_apply: exit=$exit_code, out=$out"
        return
    fi

    local nr nf
    nr="$(ci_field "$out" groups_removed)"
    nf="$(ci_field "$out" files_removed)"
    if [ "${nr:-0}" = "1" ] && [ "${nf:-0}" = "1" ] && [ ! -e "$f" ]; then
        pass "T12 epoch_pid_apply (groups_removed=1, files_removed=1, file deleted)"
    else
        fail "T12 epoch_pid_apply: groups_removed=${nr:-?}, files_removed=${nf:-?}, file_exists=$([ -e "$f" ] && echo yes || echo no), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

T8_epoch_pid_files_swept
T11a_empty_sid_dry_run
T11b_empty_sid_apply
T12_epoch_pid_apply

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

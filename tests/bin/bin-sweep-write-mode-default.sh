#!/bin/bash
# tests/bin/bin-sweep-write-mode-default.sh
# Tests: bin/lib/sweep-write-mode.sh, bin/sweep-branches.sh, bin/sweep-plans.sh, bin/sweep-worktrees.sh, bin/sweep-supervisor-state.sh, bin/sweep-shell-snapshots.sh, bin/audit-tests.sh, bin/audit-tests-common.sh, .github/workflows/sweep.yml
# Tags: sweep, write-mode, defaults, cron, scope:common, TL2
# Pins the apply-by-default write-mode inversion across the whole /sweep series:
# no flag = production run, --dry-run = report only, --apply = its synonym. The
# ONE named exception (D1) is bin/sweep-supervisor-state.sh, dry-run by default
# because it deletes governance audit records, not regenerable derivatives; the
# exception lives in this table (CPR-SSOT) so a bulk edit cannot flip it back.
# Three surfaces must stay in lock-step (CPR-ORTH / CPR-E2E): A the semantics
# SSOT, B each member's flag face and side effects, C the unattended callers.

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - The nightly GitHub Actions run itself: sweep.yml is grepped, not executed,
#   so a runner-only failure (missing GH_TOKEN, checkout depth) is invisible here.
# - A real /sweep hub dispatch forwarding user flags verbatim through the skill
#   layer — only the bin/ scripts are exercised.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRITE_MODE_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/sweep-write-mode.sh"
SWEEP_YML="$SCRIPT_CHECKOUT_ROOT/.github/workflows/sweep.yml"

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
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

ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            for (const line of b.split(/\r?\n/)) {
                const t = line.trim();
                if (!t.startsWith('{')) continue;
                try { const d = JSON.parse(t); if (key in d) { console.log(d[key]); return; } }
                catch (e) { /* skip */ }
            }
        });
    " -- "$2" 2>/dev/null
}

# shellcheck source=../lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

# Fake script checkout: a copy of bin/ whose is-github-dotcom-remote always succeeds.
# sweep-branches.sh finds that helper beside itself, so the copy is what gets launched.
make_fake_script_checkout() {
    local fake_script_checkout_root="$1"
    script_checkout_fixture_copy "$fake_script_checkout_root" bin || return 1
    printf '#!/bin/bash\nexit 0\n' > "$fake_script_checkout_root/bin/is-github-dotcom-remote"
    chmod +x "$fake_script_checkout_root/bin/is-github-dotcom-remote"
}

SCRIPT_DIR="$(dirname "$0")/bin-sweep-write-mode-default"

# shellcheck source=./bin-sweep-write-mode-default/write-mode-lib.sh
. "$SCRIPT_DIR/write-mode-lib.sh"
# shellcheck source=./bin-sweep-write-mode-default/members.sh
. "$SCRIPT_DIR/members.sh"
# shellcheck source=./bin-sweep-write-mode-default/callers.sh
. "$SCRIPT_DIR/callers.sh"

# ─────────────────────────────────────────────────────────────────────────────

case_begin "write-mode-lib" "bin/lib/sweep-write-mode.sh"
A1_lib_exists_and_defaults_to_apply
A2_lib_footer_and_usage_helpers
case_end

case_begin "dry-run-class" "bin/sweep-shell-snapshots.sh"
B1_all_scripts_accept_dry_run
case_end

case_begin "audit-tests-common-apply" "bin/audit-tests-common.sh"
B1b_audit_tests_common_accepts_apply
case_end

case_begin "sweep-plans-footer" "bin/sweep-plans.sh"
B2_sweep_plans_footer_follows_mode
case_end

case_begin "audit-tests-dry-run" "bin/audit-tests.sh"
B3_audit_tests_dry_run_writes_nothing
case_end

case_begin "sweep-branches-no-pr" "bin/sweep-branches.sh"
B4_delete_no_pr_alone_is_destructive
case_end

case_begin "sweep-worktrees-mode" "bin/sweep-worktrees.sh"
B5_sweep_worktrees_write_mode_asymmetry
case_end

case_begin "cron-flags" ".github/workflows/sweep.yml"
C1_cron_flags_updated
C2_no_stale_dry_run_prose
case_end

case_begin "supervisor-state-exception" "bin/sweep-supervisor-state.sh"
D1_sweep_supervisor_state_is_dry_run_by_default
case_end

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

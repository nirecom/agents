#!/usr/bin/env bash
# tests/bin/feature-2544-worker-outcome-write.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/outcome-record.js, hooks/lib/worker-dispatch-registry.js, hooks/workflow-state/dispatch-settlement.js, hooks/workflow-run-tests.js
# Tags: worker-dispatch, outcome, fsguard, claim-order, security, TL1, TL2, scope:issue-specific
#
# Issue #2544 — the dispatcher records each claimed test-runner dispatch as one outcome
# file in the session control dir, on every exit after the claim and on none before it.
# Entrypoint only pins, sources the fragments and brackets the cases; cases live in the sibling dir.
set -u

# TL3 gap: the suite is a canned spawn result, so what a real run-all.sh prints into
# the outcome is not measured here.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD2544_INNER:-}" ]; then
    _WD2544_INNER=1 timeout 600 bash "$0" "$@"
    exit $?
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
for tool in git node; do
    if ! command -v "$tool" >/dev/null 2>&1; then echo "SKIP: $tool is not on PATH"; exit 77; fi
done

TMPD="$(make_tmp)"
readonly TMPD
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/workflow-state" "$TMPD/plans" "$TMPD/transcripts"
export WORKFLOW_STATE_DIR="$(np "$TMPD/workflow-state")"
export WORKFLOW_PLANS_DIR="$(np "$TMPD/plans")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMPD/transcripts")"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2544-worker-outcome-write"
. "$CASE_DIR/setup.sh"
. "$CASE_DIR/outcome.sh"
. "$CASE_DIR/guard.sh"
. "$CASE_DIR/registry.sh"
. "$CASE_DIR/sequence.sh"
. "$CASE_DIR/interleave.sh"
. "$CASE_DIR/refusal.sh"

if ! build_repo; then echo "FAIL: fixture — could not build the git fixture"; exit 1; fi

case_begin "outcome-one-per-normal-exit" "bin/worker-dispatch.js"
group_outcome_normal
group_outcome_suite_fail
case_end

case_begin "outcome-one-per-worker-exception" "bin/worker-dispatch.js"
group_outcome_worker_error
case_end

case_begin "outcome-one-per-capability-failure" "bin/worker-dispatch.js"
group_outcome_capability
case_end

case_begin "outcome-planted-file-never-overwritten" "bin/worker-dispatch.js"
group_outcome_preexisting
case_end

case_begin "outcome-not-written-off-the-recorded-paths" "bin/worker-dispatch.js"
group_outcome_not_written
case_end

case_begin "outcome-write-failure-reports-runner-error" "bin/worker-dispatch/outcome-record.js"
group_outcome_write_failure
case_end

case_begin "fsguard-outcome-file-scope-own-name-only" "bin/worker-dispatch/fsguard.js"
group_fsguard_scope
case_end

case_begin "fsguard-file-scope-refuses-rename-and-mkdir" "bin/worker-dispatch/fsguard.js"
group_fsguard_rename_mkdir
case_end

case_begin "fsguard-create-exclusive" "bin/worker-dispatch/fsguard.js"
group_fsguard_exclusive
case_end

case_begin "registry-outcome-scope-and-records-outcome" "hooks/lib/worker-dispatch-registry.js"
group_registry
case_end

case_begin "claim-order-no-outcome-before-the-claim" "bin/worker-dispatch.js"
group_seq_no_write_before_claim
case_end

case_begin "claim-order-one-outcome-on-each-post-claim-exit" "bin/worker-dispatch.js"
group_seq_writes_after_claim
case_end

case_begin "two-dispatches-each-write-their-own-outcome" "hooks/workflow-state/dispatch-settlement.js"
group_interleave_two_dispatches
case_end

case_begin "refusal-outcome-identity-from-the-claim" "bin/worker-dispatch.js"
group_refusal_capability_raw_cwd
group_refusal_capability_nonstring_cwd
case_end

case_begin "refusal-null-worker-module-writes-runner-error" "bin/worker-dispatch.js"
group_refusal_null_module
case_end

# Writer-to-reader cases bracket themselves: this fragment names two sources.
. "$CASE_DIR/roundtrip.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))

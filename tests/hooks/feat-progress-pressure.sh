#!/usr/bin/env bash
# tests/hooks/feat-progress-pressure.sh
# Tests: hooks/progress-nudge.js, hooks/lib/progress-pressure.js, settings.json
# Tags: progress-file, progress-pressure, progress-nudge, hook, compaction, cap, scope:issue-specific, pwsh-not-required, TL1, baseline-increment, transcript, fixture-isolation, regression-2430, regression-2594, context-pressure, user-prompt-submit, crisis-detection, fail-open, regression-2218, nudge-trigger, risk-signal, time-injection
# Issue #2594 stage 2 — progress-nudge asks the main session to update <rootSid>-session-progress.md:
# 4a a step completed, 4c the transcript grew (2MiB / 60 min, halved after a risk), 4d a
# compaction happened; at most two 4c/4d requests an hour, nothing outside the workflow.
# TDD (write_code has not run): every case is expected to FAIL with the hook absent.
set -u

# TL3 gap (what this test does NOT catch):
# - the hook as Claude Code delivers it (the envelope is built by hand; the clock is moved by
#   ageing the session's files, not by real waiting)
# - whether the model actually updates session-progress.md after a request
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

PP_TMP="$(make_tmp)"
readonly PP_TMP
trap 'rm -rf "$PP_TMP" 2>/dev/null || true' EXIT
mkdir -p "$PP_TMP/home" "$PP_TMP/transcripts" "$PP_TMP/neutral" "$PP_TMP/plans"
export WORKFLOW_STATE_DIR="$(np "$PP_TMP/wf")" WORKFLOW_PLANS_DIR="$(np "$PP_TMP/plans")"
PP_REAL_HOME="${HOME:?}"
export HOME="$(np "$PP_TMP/home")" USERPROFILE="$(np "$PP_TMP/home")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$PP_TMP/transcripts")"
unset CLAUDE_CODE_SESSION_ID
cd "$PP_TMP/neutral" || exit 1

PP_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feat-progress-pressure"
# shellcheck source=feat-progress-pressure/_lib.sh
. "$PP_DIR/_lib.sh"

case_begin "step-complete-requests" "hooks/progress-nudge.js"
. "$PP_DIR/step-complete.sh"
case_end
case_begin "volume-requests" "hooks/progress-nudge.js"
. "$PP_DIR/volume.sh"
case_end
case_begin "compaction-requests" "hooks/progress-nudge.js"
. "$PP_DIR/compaction.sh"
case_end
case_begin "cap-and-inactive-gating" "hooks/progress-nudge.js"
. "$PP_DIR/gating.sh"
case_end
case_begin "race-overlapping-writers" "hooks/progress-nudge.js"
. "$PP_DIR/concurrency.sh"
case_end

# shellcheck source=feat-progress-pressure/baseline.sh
. "$PP_DIR/baseline.sh"
case_begin "update-advances-baseline-to-measured-transcript" "hooks/lib/progress-pressure.js"
bl_case_b1
case_end
case_begin "growth-after-update-reaches-next-request" "hooks/progress-nudge.js"
bl_case_b2
case_end
case_begin "no-update-fires-on-the-same-series" "hooks/progress-nudge.js"
bl_case_b3
case_end
case_begin "stale-progress-does-not-advance" "hooks/lib/progress-pressure.js"
bl_case_b4
case_end
case_begin "update-is-per-session" "hooks/lib/progress-pressure.js"
bl_case_b5
case_end
case_begin "fixture-writes-stay-isolated" "hooks/progress-nudge.js"
bl_case_b6
case_end

# The #2218 / #2430 detection-layer cases (was tests/hooks/feat-2218-progress-pressure.sh).
# shellcheck source=feat-progress-pressure/legacy-2218-lib.sh
. "$PP_DIR/legacy-2218-lib.sh"
# shellcheck source=feat-progress-pressure/legacy-2218-hook.sh
. "$PP_DIR/legacy-2218-hook.sh"
# shellcheck source=feat-progress-pressure/legacy-2218-triggers.sh
. "$PP_DIR/legacy-2218-triggers.sh"
case_begin "increment-threshold" "hooks/lib/progress-pressure.js"
run_P1
case_end
case_begin "baseline-lifecycle" "hooks/lib/progress-pressure.js"
run_P2
case_end
case_begin "request-wording" "hooks/progress-nudge.js"
run_P3
case_end
case_begin "fail-open" "hooks/progress-nudge.js"
run_P4
case_end
case_begin "registration" "settings.json"
run_P5
case_end
case_begin "inactive-is-silent" "hooks/progress-nudge.js"
run_P6
case_end
case_begin "ored-triggers" "hooks/lib/progress-pressure.js"
run_T3
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

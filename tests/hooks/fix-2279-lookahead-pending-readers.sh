#!/usr/bin/env bash
# fix-2279-lookahead-pending-readers.sh — L1-L8.
# Tests: hooks/workflow-state/inheritance/adopt.js, bin/resume-session-detect, hooks/workflow-state/lifecycle.js
# Tags: resume-session, adoption, wi-10-lookahead, step-in-flight, regression-2279, scope:issue-specific, pwsh-not-required, TL1

# The WI-10 lookahead writes `research=in_progress` with origin
# `postuse-in-flight` to keep the C4 Stop guard quiet during a dispatch. It is a
# statement about a TOOL CALL, not about work the user performed. Two readers
# nonetheless treat it as progress: adopt.js's isAllPending (an heir with
# "progress" may not adopt) and resume-session-detect's detect (a session with
# an in_progress step is mid-step, so there is nothing to resume). Both must
# discount a lookahead-only mark; both must keep honouring a real one.

set -u

# TL3 gap (what this test does NOT catch):
# - Whether hooks/postuse-step-in-flight-mark.js is still registered for the
#   Skill matcher in the real Claude Code host, i.e. whether the lookahead mark
#   these cases construct is ever written at all in production.
# - Whether the real PostToolUse stdin payload still yields the origin and step
#   the seed_mark fixtures below assume (payload/origin contract drift).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    N="$(cygpath -m "$AGENTS_DIR")"
else
    N="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
SIO="$N/hooks/workflow-state/state-io.js"
LIFECYCLE="$N/hooks/workflow-state/lifecycle.js"
ADOPT="$N/hooks/workflow-state/inheritance/adopt.js"
COMPLETION_APPROVAL="$N/hooks/workflow-state/completion-approval.js"
DETECT_CLI="$N/bin/resume-session-detect"

# Fixture isolation (rules/test/fixture-isolation.md).
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
export CLAUDE_TRANSCRIPT_BASE_DIR=""

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'fix2279readers'; }
np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# seed_mark <tn> <sid> <step> <origin> — one markStep through the real store,
# with the origin the caller names. `postuse-in-flight` is exactly what
# hooks/postuse-step-in-flight-mark.js passes, so the lookahead fixture is the
# hook's own write without spawning the hook (this file is TL1).
seed_mark() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" ST="$3" ORIGIN="$4" \
        "$RWT" 20 node -e "
require('$SIO').markStep(process.env.SID, process.env.ST, 'in_progress', {},
  { provenance: 'observed', origin: process.env.ORIGIN });" >/dev/null 2>&1
}

# seed_complete <tn> <sid> <step> — a finished step, so a later in_progress mark
# sits mid-workflow rather than at the very front of VALID_STEPS.
seed_complete() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" ST="$3" \
        "$RWT" 20 node -e "
require('$SIO').markStep(process.env.SID, process.env.ST, 'complete');" >/dev/null 2>&1
}

# seed_untouched <tn> <sid> — a state file that exists and records nothing.
seed_untouched() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" "$RWT" 20 node -e "
const io = require('$SIO');
io.writeState(process.env.SID, io.readState(process.env.SID) || undefined);" >/dev/null 2>&1
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" "$RWT" 20 node -e "
require('$SIO').markStep(process.env.SID, 'research', 'pending');" >/dev/null 2>&1
}

# lookahead_only <tn> <sid> <step> — the lifecycle predicate that already knows
# the answer. Asserted as a fixture anchor: when it disagrees with the fixture,
# L1/L4's verdicts are about a state that is not the one under test.
lookahead_only() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" "$RWT" 20 node -e "
process.stdout.write(String(require('$LIFECYCLE').isLookaheadOnlyInFlight('$2', '$3')));" 2>/dev/null
}

# all_pending <tn> <sid> — adopt.js's own gate, over the real projected state.
all_pending() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" SID="$2" "$RWT" 20 node -e "
const { readState } = require('$SIO');
const { isAllPending } = require('$ADOPT');
process.stdout.write(String(isAllPending(readState(process.env.SID))));" 2>/dev/null
}

# detect_type <tn> <sid> — bin/resume-session-detect's detect(), in-process.
detect_type() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" CLAUDE_SESSION_ID="$2" "$RWT" 20 node -e "
const r = require('$DETECT_CLI').detect();
process.stdout.write(String(r && r.type) + ':' + String((r && r.step) || '-'));" 2>/dev/null
}

# ---------------------------------------------------------------------------
# L1: the adoption gate. A fresh session whose ONLY record is the lookahead's
#     research mark is still an empty shell — /resume-session --from must be
#     allowed to adopt into it. This is the #2279 refusal itself.
# ---------------------------------------------------------------------------
run_L1() {
    local tmp tn got anchor
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    seed_mark "$tn" l1 research "postuse-in-flight"
    anchor="$(lookahead_only "$tn" l1 research)"
    got="$(all_pending "$tn" l1)"
    if [ "$anchor" != "true" ]; then
        fail "L1: fixture anchor — isLookaheadOnlyInFlight said '$anchor', so the state under test is not a lookahead-only one"
    elif [ "$got" = "true" ]; then
        pass "L1: isAllPending treats a lookahead-only in_progress mark as no progress at all (the heir may still adopt)"
    else
        fail "L1: isAllPending returned '$got' — the WI-10 lookahead's own mark is being read as the heir's work, which is what makes /resume-session --from a no-op (#2279)"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# L2: the counterweight. A REAL in_progress research (origin mark-step) is
#     progress, and adopting over it would bulldoze it. A fix that simply
#     ignores in_progress passes L1 and destroys the gate; it fails here.
# ---------------------------------------------------------------------------
run_L2() {
    local tmp tn got anchor
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    seed_mark "$tn" l2 research "mark-step"
    anchor="$(lookahead_only "$tn" l2 research)"
    got="$(all_pending "$tn" l2)"
    if [ "$anchor" != "false" ]; then
        fail "L2: fixture anchor — isLookaheadOnlyInFlight said '$anchor' for a mark-step origin"
    elif [ "$got" = "false" ]; then
        pass "L2: isAllPending still refuses an heir carrying a genuine in_progress step"
    else
        fail "L2: isAllPending returned '$got' — real recorded work would be overwritten by an adoption"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# L3: the untouched baseline — a state file with nothing but pending steps is
#     adoptable. If this ever broke, L1's failure could not be attributed to
#     the lookahead.
# ---------------------------------------------------------------------------
run_L3() {
    local tmp tn got
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    seed_untouched "$tn" l3
    got="$(all_pending "$tn" l3)"
    if [ "$got" = "true" ]; then
        pass "L3: isAllPending is true for a state file that records nothing (the adoptable baseline)"
    else
        fail "L3: isAllPending returned '$got' for an all-pending state — the baseline is broken"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# L4: the other reader. detect() answers "where was this session?"; a lookahead
#     mark says nothing about where the session was, so the honest answer is
#     `none`. Today research is not even in STEP_TO_SKILL, so the session is
#     told to wait on a sentinel that will never arrive.
# ---------------------------------------------------------------------------
run_L4() {
    local tmp tn got
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    seed_mark "$tn" l4 research "postuse-in-flight"
    got="$(detect_type "$tn" l4)"
    if [ "${got%%:*}" = "none" ]; then
        pass "L4: detect() reports type=none for a lookahead-only mark (nothing to resume)"
    else
        fail "L4: detect() reported '$got' — a dispatch's own bookkeeping is being replayed as the session's current step (#2279)"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# L5: detect()'s counterweight — a real in_progress step still routes to its
#     skill. The same over-reach L2 guards, on the second reader (CPR-ORTH).
# ---------------------------------------------------------------------------
run_L5() {
    local tmp tn got
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    seed_mark "$tn" l5 detail "mark-step"
    got="$(detect_type "$tn" l5)"
    if [ "$got" = "skill:detail" ]; then
        pass "L5: detect() still routes a genuine in_progress 'detail' to its skill"
    else
        fail "L5: detect() reported '$got', expected 'skill:detail' — the fix has silenced real resumes too"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# L6: CPR-SSOT. "Is this mark only the lookahead's?" is already answered once,
#     by lifecycle.isLookaheadOnlyInFlight. Each reader re-deriving it from the
#     event stream is how the two drifted apart in the first place, so each must
#     reach the shared predicate (or at minimum the LOOKAHEAD_ORIGIN constant it
#     is keyed on) rather than inventing its own rule.
# ---------------------------------------------------------------------------
run_L6() {
    local f problems="" label
    for f in "$AGENTS_DIR/hooks/workflow-state/inheritance/adopt.js" \
             "$AGENTS_DIR/bin/resume-session-detect"; do
        label="$(basename "$f")"
        if [ ! -f "$f" ]; then
            problems="$problems [$label: not found]"
        elif ! grep -qE 'isLookaheadOnlyInFlight|LOOKAHEAD_ORIGIN' "$f"; then
            problems="$problems [$label: never reaches the shared lookahead predicate]"
        fi
    done
    if [ -z "$problems" ]; then
        pass "L6: both adoption readers consult the single lookahead predicate rather than re-deriving it (CPR-SSOT)"
    else
        fail "L6: the lookahead rule is not sourced from one place;$problems"
    fi
}

# ---------------------------------------------------------------------------
# L7: the over-reach fence on detect(), paired with L4 (CPR-ORTH). #2013's
#     auto-mark stamps the SAME `postuse-in-flight` origin on a REAL delegated
#     step dispatch, so the origin alone cannot mean "nothing happened here".
#     An interrupted STEP_TO_SKILL step must still route to its skill —
#     resuming one is /resume-session's whole reason to exist. A fix that reads
#     "lookahead origin => type none" satisfies L4 and silently deletes that.
#     L5 cannot catch it: its mark carries the mark-step origin.
# ---------------------------------------------------------------------------
run_L7() {
    local tmp tn got anchor
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    seed_mark "$tn" l7 detail "postuse-in-flight"
    anchor="$(lookahead_only "$tn" l7 detail)"
    got="$(detect_type "$tn" l7)"
    if [ "$anchor" != "true" ]; then
        fail "L7: fixture anchor — isLookaheadOnlyInFlight said '$anchor', so the mark under test does not carry the lookahead origin"
    elif [ "$got" = "skill:detail" ]; then
        pass "L7: detect() still routes an interrupted STEP_TO_SKILL step marked by the auto-mark to its skill (a lookahead ORIGIN is not by itself a reason to resume nothing)"
    else
        fail "L7: detect() reported '$got', expected 'skill:detail' — a lookahead-origin mark on a mapped step is being discounted, so a genuinely interrupted session has nothing to resume"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# L8: L7's real-world sibling (CPR-ORTH). d-skill-dispatch.sh B18 shows the
#     auto-mark stamping `postuse-in-flight` on `review_tests` during an actual
#     Skill(review-tests) dispatch — the common mid-workflow shape, where L7's
#     `detail` is illustrative. `review_tests` is in VALID_STEPS but NOT in
#     resume-session-detect's STEP_TO_SKILL, so its honest routing today is
#     `sentinel-wait`, not `skill`. Either verdict is a resume; `none` is not.
#     The fence: an origin-blind fix must not turn this into "nothing to resume".
# ---------------------------------------------------------------------------
run_L8() {
    local tmp tn got anchor type step
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    seed_complete "$tn" l8 workflow_init
    seed_complete "$tn" l8 write_tests
    seed_mark "$tn" l8 review_tests "postuse-in-flight"
    anchor="$(lookahead_only "$tn" l8 review_tests)"
    got="$(detect_type "$tn" l8)"
    type="${got%%:*}"; step="${got#*:}"
    if [ "$anchor" != "true" ]; then
        fail "L8: fixture anchor — isLookaheadOnlyInFlight said '$anchor' for the review_tests mark"
    elif [ "$step" = "review_tests" ] && { [ "$type" = "sentinel-wait" ] || [ "$type" = "skill" ]; }; then
        pass "L8: detect() still resumes an interrupted review_tests marked by the real Skill(review-tests) auto-mark (got '$got')"
    else
        fail "L8: detect() reported '$got' — the B18 dispatch shape is being discounted to nothing-to-resume, so a session interrupted during /review-tests cannot be resumed"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# L9/L10 live in a sibling fragment (rules/coding/file-split.md Pattern A); they need
# make_tmp/np, the module path variables and the pass/fail counters, so it is
# sourced here rather than at the top of the file.
# shellcheck source=/dev/null
. "$AGENTS_DIR/tests/fix-2279-lookahead-pending-readers/allowlist-matrix.sh"

run_L1
run_L2
run_L3
run_L4
run_L5
run_L6
run_L7
run_L8
run_L9
run_L10

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

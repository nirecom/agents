# shellcheck shell=bash
# tests/bin/feature-resume-session-468/lookahead-origin.sh — T22: research under the WI-10 lookahead origin, before vs after workflow start (#2279). Sourced by tests/bin/feature-resume-session-468.sh; not standalone.
# Tests: bin/resume-session-detect
# Tags: session, resume, wi-10-lookahead, regression-2279, scope:common, pwsh-not-required, TL2

if ! declare -F run_cli >/dev/null 2>&1; then
    echo "lookahead-origin.sh: sourced fragment — run tests/bin/feature-resume-session-468.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

echo ""
echo "=== T22: research carrying the lookahead origin, before vs after workflow start (#2279) ==="

# build_state_json writes a v1 projection with no event stream, so no step there
# can carry an ORIGIN — and origin is the whole discrimination detect() makes on
# `research`. These two rows need a real store written through markStep.

# seed_lookahead_research <subdir> <sid> [settled-step...] — research in_progress
# under the WI-10 lookahead origin, on top of whichever steps the caller settles.
seed_lookahead_research() {
    local root="$TMPDIR_BASE/$1" sid="$2"
    shift 2
    mkdir -p "$root/state" "$root/plans/worktree-end"
    WORKFLOW_STATE_DIR="$root/state" WORKFLOW_PLANS_DIR="$root/plans" \
        SID="$sid" SETTLED="$*" run_with_timeout node -e "
const io = require('$SIO_NODE');
for (const s of String(process.env.SETTLED).split(' ').filter(Boolean)) {
  io.markStep(process.env.SID, s, 'complete');
}
io.markStep(process.env.SID, 'research', 'in_progress', {}, { provenance: 'observed', origin: 'postuse-in-flight' });
" >/dev/null 2>&1
}

# "<origin>/<isLookaheadOnlyInFlight>" — the attribution detect() consults.
lookahead_attribution() {
    local root="$TMPDIR_BASE/$1"
    WORKFLOW_STATE_DIR="$root/state" WORKFLOW_PLANS_DIR="$root/plans" SID="$2" \
        run_with_timeout node -e "
const L = require('$LIFECYCLE_NODE');
const { readState } = require('$SIO_NODE');
const s = readState(process.env.SID);
const evs = ((s && s.events) || []).filter((e) => e && e.kind === 'step_status' && e.step === 'research');
const last = evs.length ? evs[evs.length - 1] : null;
process.stdout.write((last ? String(last.origin) : '<no-event>') + '/' + String(L.isLookaheadOnlyInFlight(process.env.SID, 'research')));" 2>/dev/null
}

# T22a — the counterpart of the pre-init artifact case. Once workflow_init is
# settled, isPreInitLookaheadArtifact() no longer holds, so the SAME origin on
# the SAME step is #2013's mark on a genuinely interrupted dispatch and the
# session still resumes. A guard keyed on the origin alone answers `none` here
# and silently strands every interrupted research dispatch.
seed_lookahead_research t22a sid-t22a workflow_init clarify_intent
T22A_ATTR="$(lookahead_attribution t22a sid-t22a)"
if [ "$T22A_ATTR" = "postuse-in-flight/true" ]; then
    pass "T22a. fixture: research is in flight under the lookahead origin, and the readers agree it is lookahead-only"
else
    fail "T22a. fixture: origin/lookahead-only is '$T22A_ATTR', want 'postuse-in-flight/true' — the rows below would prove nothing"
fi
run_cli "t22a" "sid-t22a" "" ""
assert_type "T22b. type=sentinel-wait when a post-workflow-start research carries the lookahead origin" "sentinel-wait"
assert_field "T22b. step=research" "step" "research"
assert_exit "T22c. exit 0 for the post-workflow-start lookahead" "0"

# T22d — the discriminating pair (CPR-ORTH). Same origin, same step, but nothing
# else recorded: that IS the pre-init artifact, and it must be skipped. Without
# this row a detect() that ignored the origin entirely would pass T22b.
seed_lookahead_research t22d sid-t22d
T22D_ATTR="$(lookahead_attribution t22d sid-t22d)"
if [ "$T22D_ATTR" = "postuse-in-flight/true" ]; then
    pass "T22d. fixture: the pre-init shell records the same lookahead origin on the same step"
else
    fail "T22d. fixture: origin/lookahead-only is '$T22D_ATTR', want 'postuse-in-flight/true'"
fi
run_cli "t22d" "sid-t22d" "" ""
assert_type "T22e. type=none when the lookahead origin is the session's ONLY record (the pre-init artifact)" "none"

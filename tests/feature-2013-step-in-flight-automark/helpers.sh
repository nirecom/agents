# helpers.sh
# Tests: hooks/lib/step-in-flight-policy.js, hooks/workflow-state/lifecycle.js, hooks/postuse-step-in-flight-mark.js
# Tags: stop-hook, step-in-flight, posttooluse, regression-2013, scope:issue-specific, pwsh-not-required, TL2
#
# State seeding and hook drivers for the #2013 step-in-flight auto-mark suite.
# Sourced by tests/feature-2013-step-in-flight-automark.sh; expects AGENTS_DIR,
# _AGENTS_DIR_NODE, RWT and the pass/fail/skip counters.

STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"
LIFECYCLE_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/lifecycle.js"
POLICY_NODE="$_AGENTS_DIR_NODE/hooks/lib/step-in-flight-policy.js"
COMPLETION_APPROVAL_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/completion-approval.js"
AUTOMARK_HOOK="$AGENTS_DIR/hooks/postuse-step-in-flight-mark.js"
GUARD_C4="$AGENTS_DIR/hooks/stop-premature-stop-guard.js"

# The TTL the suite backdates against. Pinned independently of the module so a
# module that silently widens its own TTL cannot make A8 pass by moving the
# goalposts; case A15 asserts the module agrees with this number.
TTL_MS=$((4 * 60 * 60 * 1000))

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'stepinflight2013'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# seed_step <tn> <sid> <step> <status> — real markStep against the real store.
#
# outline/detail ->complete transitions are approval-gated (#1133): markStep
# would throw UnapprovedCompletionError and silently no-op behind the
# redirected stderr below. Record a sanctioned "reset-sentinel" approval first
# (same pattern as APPROVE_GATED_JS in tests/feature-1733-state-event-stream)
# so seeding succeeds regardless of the host's CONFIRM_OUTLINE/CONFIRM_DETAIL
# setting.
seed_step() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" ST="$3" STATUS="$4" SID="$2" "$RWT" 15 node -e "
const CA = require('$COMPLETION_APPROVAL_NODE');
if (process.env.STATUS === 'complete' && CA.isApprovalGatedStep(process.env.ST)) {
  CA.recordPlanApproval(process.env.SID, process.env.ST, { source: 'reset-sentinel', reason: '2013 fixture' });
}
require('$STATEIO_NODE').markStep(process.env.SID, process.env.ST, process.env.STATUS);" >/dev/null 2>&1
}

# seed_started <tn> <sid> — workflow_init + clarify_intent complete, so the
# session's current step is `research` (the same fixture shape the #1794 suite
# uses, so C4 would normally block).
seed_started() {
    seed_step "$1" "$2" workflow_init complete
    seed_step "$1" "$2" clarify_intent complete
}

# backdate_step <tmp> <sid> <step> <ms-ago> — age the step. `steps` is a
# PROJECTION recomputed from the event stream (v3 state), so the timestamp is
# moved on the step's own events; readState folds it back into updated_at.
backdate_step() {
    P="$(node_path "$1/$2.json")" ST="$3" MS="$4" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
const at = new Date(Date.now() - Number(process.env.MS)).toISOString();
for (const e of s.events || []) { if (e.step === process.env.ST) e.at = at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
}

# strip_updated_at <tmp> <sid> <step> — remove the timestamp entirely from the
# step's events, so the projection can carry no updated_at. The fail-CLOSED
# input class (A9): a record that cannot prove its age is not in flight.
strip_updated_at() {
    P="$(node_path "$1/$2.json")" ST="$3" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
for (const e of s.events || []) { if (e.step === process.env.ST) delete e.at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
}

# in_flight_fixture <tmp> <tn> <sid> <step> <ms-ago> — the standard "step is
# in_progress and was touched <ms-ago> ago" fixture.
in_flight_fixture() {
    seed_started "$2" "$3"
    seed_step "$2" "$3" "$4" in_progress
    backdate_step "$1" "$3" "$4" "$5"
}

# pred_eval <tn> <js-expression> — evaluate an expression with `L` bound to
# lifecycle.js and `P` to step-in-flight-policy.js. Prints String(result), or
# nothing at all when the module cannot even be loaded (which every case
# distinguishes from a legitimate `false`).
pred_eval() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" "$RWT" 20 node -e "
let P = null;
try { P = require('$POLICY_NODE'); } catch (e) {}
const L = require('$LIFECYCLE_NODE');
process.stdout.write(String($2));" 2>/dev/null
}

# assert_pred <case-id> <description> <expected> <tn> <js-expression>
assert_pred() {
    local id="$1" desc="$2" want="$3" tn="$4" expr="$5" got
    got="$(pred_eval "$tn" "$expr")"
    if [ "$got" = "$want" ]; then
        pass "$id: $desc"
    else
        fail "$id: $desc — expected '$want', got '${got:-<module-load-or-eval-error>}'"
    fi
}

# run_automark <tn> <sid> <tool_name> [agent_id] — drives the real PostToolUse
# auto-mark hook the way Claude Code does: a JSON payload on stdin. Sets
# AM_OUT / AM_RC.
run_automark() {
    AM_OUT=$(TOOL="$3" SID="$2" AGENT="${4:-}" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: process.env.TOOL, session_id: process.env.SID,
  agent_id: process.env.AGENT, transcript_path: '', tool_input: { description: 'x' } }));" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 20 node "$(node_path "$AUTOMARK_HOOK")" 2>/dev/null)
    AM_RC=$?
}

# run_automark_raw <tn> <raw-stdin> — the same hook driven with an ARBITRARY
# stdin payload instead of a well-formed one. Claude Code owns that payload, so
# the hook cannot assume its shape; every malformed class has to be survivable.
# Sets AM_OUT / AM_RC.
run_automark_raw() {
    AM_OUT=$(printf '%s' "$2" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 20 node "$(node_path "$AUTOMARK_HOOK")" 2>/dev/null)
    AM_RC=$?
}

# make_repo_fixture <dir> — a throwaway git repo for CLAUDE_PROJECT_DIR.
#
# Several steps auto-resolve to complete on git EVIDENCE (write_tests looks for
# staged or committed changes under tests/, docs looks for staged doc changes).
# Left unpinned, the resolver walks up from the CWD and finds THIS worktree —
# whose branch is, by construction, full of staged test changes. The guard rows
# would then be judging the developer's working copy rather than the fixture.
make_repo_fixture() {
    mkdir -p "$1"
    git -C "$1" init -q >/dev/null 2>&1
    git -C "$1" config core.hooksPath /dev/null >/dev/null 2>&1
}

# run_c4 <tn> <sid> — the REAL C4 premature-stop guard as a child process: the
# consumer the whole in-flight record exists to influence. Sets C4_OUT / C4_RC,
# where rc 0 = silent (the dispatch is honoured) and rc 2 = blocked (nudged).
# Honours FIXTURE_REPO when the caller has pinned one.
run_c4() {
    C4_OUT=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$2\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          CLAUDE_PROJECT_DIR="${FIXTURE_REPO:-}" \
          "$RWT" 25 node "$(node_path "$GUARD_C4")" 2>/dev/null)
    C4_RC=$?
}

# trim <text> — strip surrounding spaces, so the case tables below can be
# aligned for reading without the padding leaking into the values under test.
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# step_status <tmp> <sid> <step> — the on-disk status, or `<no-state>` /
# `<absent>` so a missing file is never mistaken for a status value.
step_status() {
    P="$(node_path "$1/$2.json")" ST="$3" "$RWT" 15 node -e "
const fs = require('fs');
let s;
try { s = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('<no-state>'); process.exit(0); }
const e = ((s.current && s.current.steps) || s.steps || {})[process.env.ST];
process.stdout.write(e && e.status ? e.status : '<absent>');" 2>/dev/null
}

# event_count <tmp> <sid> — length of the event stream (0 when unreadable), the
# idempotency observable for B10.
event_count() {
    P="$(node_path "$1/$2.json")" "$RWT" 15 node -e "
const fs = require('fs');
let s;
try { s = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('0'); process.exit(0); }
process.stdout.write(String(Array.isArray(s.events) ? s.events.length : 0));" 2>/dev/null
}

# state_digest <tmp> <sid> — every step's status, joined. The "state unchanged"
# observable: comparing the whole map catches a hook that marked the WRONG step
# as well as one that marked the right step it should not have touched.
state_digest() {
    P="$(node_path "$1/$2.json")" "$RWT" 15 node -e "
const fs = require('fs');
let s;
try { s = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('<no-state>'); process.exit(0); }
const steps = (s.current && s.current.steps) || s.steps || {};
process.stdout.write(Object.keys(steps).sort().map((k) => k + '=' + steps[k].status).join(','));" 2>/dev/null
}

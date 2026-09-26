#!/usr/bin/env bash
# fix-2279-resume-from-skill-dispatch.sh — S1-S12.
# Tests: bin/resume-session-detect, bin/lib/resume-session/upstream-view.js, hooks/workflow-state/inheritance/adopt.js, hooks/postuse-step-in-flight-mark.js
# Tags: resume-session, adoption, skill-dispatch, wi-10-lookahead, regression-2279, scope:issue-specific, pwsh-not-required, TL2

# The whole #2279 sentence, with the real hook and the real CLI over real files:
# a fresh session runs `/resume-session --from <sid>`; Claude Code fires
# PostToolUse for the Skill call that started it; the lookahead marks `research`
# in_progress; and the adoption the user asked for is then refused because the
# heir "has already recorded workflow steps". The heir's only recorded step is
# the one the resume itself caused. S3 runs the same adoption WITHOUT the
# dispatch, so S6/S7's refusal cannot be blamed on the fixture.

set -u

# TL3 gap (what this test does NOT catch):
# - Whether the stdin payload a real `claude -p` Skill dispatch delivers matches
#   the synthetic one dispatch_skill() composes (host-contract drift).
# - Whether PostToolUse actually registers and fires for the Skill matcher in
#   the real settings.json-driven host, rather than only when invoked directly.
# Both are closed by tests/TL3-hook-skill-dispatch-payload.sh (RUN_TL3-gated).
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
CLI="$AGENTS_DIR/bin/resume-session-detect"
AUTOMARK="$AGENTS_DIR/hooks/postuse-step-in-flight-mark.js"

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
export CLAUDE_TRANSCRIPT_BASE_DIR=""

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

DONOR=donor2279
HEIR=heir2279

# build_fixture — a throwaway repo plus a fresh store, and the two sessions the
# scenario needs. Both sessions' state files are written from INSIDE the repo so
# their recorded cwd/branch match; the context gate is not what is under test.
build_fixture() {
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t 'fix2279from')"
    STORE="$TMP/store"; REPO="$TMP/repo"
    mkdir -p "$STORE" "$REPO"
    STORE_N="$(np "$STORE")"
    git -C "$REPO" init -q >/dev/null 2>&1
    git -C "$REPO" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$REPO" config user.email t@example.com >/dev/null 2>&1
    git -C "$REPO" config user.name t >/dev/null 2>&1
    seed_donor
    seed_heir_shell
    : > "$STORE/$DONOR-intent.md"
}

# in_repo <sid> <node-body> — a node one-liner run from the repo with the
# fixture store pinned, so every write lands in the fixture (fixture-isolation).
in_repo() {
    ( cd "$REPO" && CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" \
        AGENTS_CONFIG_DIR="$N" SID="$1" "$RWT" 25 node -e "$2" ) 2>/dev/null
}

# The donor: a session that genuinely got as far as `research`. Not all-pending
# (adoption refuses that donor outright) and not user-verified (a closed
# session is not resumable either).
seed_donor() {
    in_repo "$DONOR" "
const io = require('$SIO');
io.markStep(process.env.SID, 'workflow_init', 'complete');
io.markStep(process.env.SID, 'clarify_intent', 'complete');
io.markStep(process.env.SID, 'research', 'in_progress');" >/dev/null
}

# The heir: the untouched shell a crash-resume lands in. Written explicitly so
# the scenario holds whichever way the fix goes — if the fix stops the Skill
# dispatch from creating the state file, there must still be a heir to adopt
# INTO, and that is this file, not the lookahead's side effect.
seed_heir_shell() {
    in_repo "$HEIR" "require('$SIO').markStep(process.env.SID, 'research', 'pending');" >/dev/null
}

# dispatch_skill <sid> <skill> — the REAL PostToolUse hook with the payload
# Claude Code sends for a Skill call.
dispatch_skill() {
    HOOK_OUT=$( ( cd "$REPO" && SID="$1" SK="$2" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Skill', session_id: process.env.SID,
  agent_id: '', transcript_path: '', tool_input: { skill: process.env.SK, description: 'x' } }));" \
        | CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" AGENTS_CONFIG_DIR="$N" \
          "$RWT" 25 node "$(np "$AUTOMARK")" ) 2>/dev/null )
    HOOK_RC=$?
}

# run_from <donor> — the user-facing command, exactly as /resume-session runs it.
run_from() {
    FROM_OUT=$( ( cd "$REPO" && CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" \
        CLAUDE_SESSION_ID="$HEIR" "$RWT" 30 node "$CLI" --from "$1" ) 2>/dev/null )
    FROM_RC=$?
}

# from_field <json-path-expression> — one field out of the view above.
from_field() {
    printf '%s' "$FROM_OUT" | "$RWT" 15 node -e "
let b = '';
process.stdin.on('data', (c) => { b += c; });
process.stdin.on('end', () => {
  let d = null;
  try { d = JSON.parse(b); } catch (e) { process.stdout.write('<unparseable>'); return; }
  const r = (d && d.inherit_result) || {};
  process.stdout.write(String($1));
});" 2>/dev/null
}

steps_of() {
    CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" SID="$1" "$RWT" 15 node -e "
const s = require('$SIO').readState(process.env.SID) || {};
const steps = s.steps || {};
process.stdout.write(Object.keys(steps).sort().map((k) => k + '=' + steps[k].status).join(','));" 2>/dev/null
}

cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP" 2>/dev/null; return 0; }

# ---------------------------------------------------------------------------
# S1-S3 — the fixture and the no-dispatch baseline.
# ---------------------------------------------------------------------------
build_fixture

DONOR_STEPS="$(steps_of "$DONOR")"
case "$DONOR_STEPS" in
    *research=in_progress*workflow_init=complete*|*workflow_init=complete*)
        pass "S1: the donor session records real progress (workflow_init complete, research in flight)" ;;
    *)
        fail "S1: fixture — the donor recorded '$DONOR_STEPS'" ;;
esac

HEIR_STEPS="$(steps_of "$HEIR")"
case "$HEIR_STEPS" in
    *=complete*|*=in_progress*) fail "S2: fixture — the heir shell is not untouched: '$HEIR_STEPS'" ;;
    "") fail "S2: fixture — the heir has no readable state file" ;;
    *) pass "S2: the heir is an untouched shell before anything is dispatched" ;;
esac

run_from "$DONOR"
if [ "$(from_field 'r.ok')" = "true" ] && [ "$FROM_RC" -eq 0 ]; then
    pass "S3: baseline — --from adopts into the untouched heir (the path works when no dispatch intervenes)"
else
    fail "S3: baseline adoption already fails without any dispatch (rc=$FROM_RC, ok=$(from_field 'r.ok'), error=$(from_field 'r.error')) — S6/S7 below cannot be attributed to #2279"
fi
cleanup

# ---------------------------------------------------------------------------
# S4-S8 — the same adoption, with the resume's own Skill dispatch in front of
# it. Only that one call differs from S3.
# ---------------------------------------------------------------------------
build_fixture
dispatch_skill "$HEIR" resume-session

if [ "$HOOK_RC" -eq 0 ]; then
    pass "S4: the PostToolUse hook survives the Skill(resume-session) payload and exits 0"
else
    fail "S4: the PostToolUse hook exited $HOOK_RC on a Skill(resume-session) payload; out='$HOOK_OUT'"
fi

AFTER_DISPATCH="$(steps_of "$HEIR")"
LOOKAHEAD_ONLY=$(CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" "$RWT" 15 node -e "
process.stdout.write(String(require('$LIFECYCLE').isLookaheadOnlyInFlight('$HEIR', 'research')));" 2>/dev/null)
case "$AFTER_DISPATCH" in
    *research=in_progress*)
        if [ "$LOOKAHEAD_ONLY" = "true" ]; then
            pass "S5: whatever the dispatch recorded is attributable to the lookahead alone, not to work the user did"
        else
            fail "S5: the dispatch left research in_progress but isLookaheadOnlyInFlight says '$LOOKAHEAD_ONLY' — the mark is indistinguishable from real work"
        fi ;;
    *)
        pass "S5: the dispatch recorded no in-flight step at all (the strongest form of the fix)" ;;
esac

run_from "$DONOR"
if [ "$(from_field 'r.ok')" = "true" ]; then
    pass "S6: --from still adopts after /resume-session's own Skill dispatch (the #2279 report)"
else
    fail "S6: --from refused after the resume's own Skill dispatch — attempted=$(from_field 'r.attempted') error='$(from_field 'r.error')'; the heir's only recorded step is the one the resume itself caused (#2279)"
fi

if [ "$FROM_RC" -eq 0 ]; then
    pass "S7a: --from exits 0 after the dispatch"
else
    fail "S7a: --from exited $FROM_RC after the dispatch"
fi

ADOPTED="$(steps_of "$HEIR")"
case "$ADOPTED" in
    *workflow_init=complete*)
        pass "S7b: the heir's own state file carries the donor's completed steps after the resume" ;;
    *)
        fail "S7b: the heir recorded '$ADOPTED' — the donor's progress never arrived, so the resume was a no-op for the user" ;;
esac

FROM_LIST=$( ( cd "$REPO" && CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" \
    CLAUDE_SESSION_ID="$HEIR" "$RWT" 30 node "$CLI" --list ) 2>/dev/null )
case "$FROM_LIST" in
    *"$DONOR"*)
        pass "S8: --list still offers the donor to a session that has dispatched the resume skill" ;;
    *)
        fail "S8: --list no longer offers '$DONOR' after the dispatch; got: $FROM_LIST" ;;
esac
cleanup

# ---------------------------------------------------------------------------
# S9-S10 — the SPELLING axis of the same ordering, measured where a dispatch
# CAN mark: a session settled through write_tests, whose current step is the
# allowlisted `review_tests`. The heir of S4-S8 is a pre-init shell, where the
# D-3 tool narrowing already stops every Skill dispatch — so no spelling could
# fail there. Here the `control` row proves the pipeline still marks, and the
# resume-session spellings must be the only ones that do not.
# ---------------------------------------------------------------------------

# seed_mid_workflow <sid> — settle every step up to write_tests. outline/detail
# ->complete is approval-gated (#1133), so record the sanctioned approval first.
seed_mid_workflow() {
    in_repo "$1" "
const io = require('$SIO');
const CA = require('$N/hooks/workflow-state/completion-approval.js');
for (const s of ['workflow_init','clarify_intent','research','outline','detail','branching_complete','write_tests']) {
  if (CA.isApprovalGatedStep(s)) {
    CA.recordPlanApproval(process.env.SID, s, { source: 'reset-sentinel', reason: '2279 S9 fixture' });
  }
  io.markStep(process.env.SID, s, 'complete');
}" >/dev/null
}

rt_status() {
    CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" SID="$1" "$RWT" 15 node -e "
const s = require('$SIO').readState(process.env.SID) || {};
const e = (s.steps || {}).review_tests;
process.stdout.write((e && e.status) || '<absent>');" 2>/dev/null
}

build_fixture
S9_PROBLEMS=""
while IFS='|' read -r S9_LABEL S9_SKILL S9_WANT; do
    S9_LABEL="$(printf '%s' "$S9_LABEL" | sed 's/[[:space:]]*$//')"
    S9_SKILL="$(printf '%s' "$S9_SKILL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    S9_WANT="$(printf '%s' "$S9_WANT" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$S9_LABEL" in ''|'#'*) continue ;; esac
    S9_SID="spell-$S9_LABEL"
    seed_mid_workflow "$S9_SID"
    if [ "$(rt_status "$S9_SID")" = "in_progress" ]; then
        S9_PROBLEMS="$S9_PROBLEMS [$S9_LABEL: fixture already had review_tests in_progress]"
        continue
    fi
    dispatch_skill "$S9_SID" "$S9_SKILL"
    S9_AFTER="$(rt_status "$S9_SID")"
    [ "$HOOK_RC" -eq 0 ] ||
        S9_PROBLEMS="$S9_PROBLEMS [$S9_LABEL: hook exited $HOOK_RC, want 0]"
    if [ "$S9_WANT" = "marked" ]; then
        [ "$S9_AFTER" = "in_progress" ] ||
            S9_PROBLEMS="$S9_PROBLEMS [$S9_LABEL: review_tests is '$S9_AFTER' — the pipeline no longer marks at all, so the rows above prove nothing]"
    else
        [ "$S9_AFTER" != "in_progress" ] ||
            S9_PROBLEMS="$S9_PROBLEMS [$S9_LABEL: the resume-session dispatch claimed review_tests, which is the #2279 fault under a different spelling]"
    fi
done <<'EOF'
# label       | tool_input.skill        | review_tests after the dispatch
bare          | resume-session          | unchanged
namespaced    | personal:resume-session | unchanged
path          | skills/resume-session   | unchanged
path-and-ns   | a/b:resume-session      | unchanged
mixed-case    | Resume-Session          | unchanged
control       | review-tests            | marked
EOF

if [ -z "$S9_PROBLEMS" ]; then
    pass "S9: every spelling of resume-session leaves review_tests alone while a real skill dispatch on the same fixture still claims it (Skill payload -> hook -> state file, in that order)"
else
    fail "S9: the skill-dispatch pipeline disagrees with the meta-op exclusion;$S9_PROBLEMS"
fi

dispatch_skill "$HEIR" personal:resume-session
run_from "$DONOR"
if [ "$(from_field 'r.ok')" = "true" ] && [ "$FROM_RC" -eq 0 ]; then
    pass "S10: --from still adopts after a NAMESPACED resume-session dispatch (S6's ordering is not specific to the bare spelling)"
else
    fail "S10: --from refused after a namespaced resume-session dispatch — rc=$FROM_RC, attempted=$(from_field 'r.attempted'), error='$(from_field 'r.error')'"
fi
cleanup

# ---------------------------------------------------------------------------
# S11 — the REGISTERED hook, not a hard-coded path. S4-S10 spawn the hook by the
# path this file chose, so unregistering it (or narrowing the PostToolUse matcher
# off Skill) keeps them green while the host stops firing it. Matcher and command
# come OUT of settings.json here, and the #2279 sentence is replayed through them.
# Needs no claude -p, so unlike the RUN_TL3 sibling TL3-hook-skill-dispatch-
# payload.sh it can never SKIP into a false green.
# ---------------------------------------------------------------------------

# "MATCH"/"NOMATCH"/"NONE" on line 1, the registered command string on line 2.
read_registration() {
    "$RWT" 15 node -e "
const s = require('$N/settings.json');
const hits = [];
for (const g of ((s.hooks && s.hooks.PostToolUse) || [])) {
  for (const h of (g.hooks || [])) {
    if (typeof h.command === 'string' && h.command.indexOf('postuse-step-in-flight-mark.js') !== -1) {
      hits.push([String(g.matcher || ''), h.command]);
    }
  }
}
const NL = String.fromCharCode(10);
if (hits.length === 0) { process.stdout.write('NONE' + NL); } else {
  const matcher = hits[0][0];
  let verdict = 'NOMATCH';
  try { verdict = new RegExp('^(?:' + matcher + ')\$').test('Skill') ? 'MATCH' : 'NOMATCH'; } catch (e) { verdict = 'NOMATCH'; }
  process.stdout.write(verdict + NL + hits[0][1] + NL);
}" 2>/dev/null
}

# dispatch_via_registration <sid> <skill> — the same Skill payload S4 uses, fed
# to whatever settings.json says Claude Code runs for a Skill dispatch.
dispatch_via_registration() {
    printf '{"tool_name":"Skill","session_id":"%s","agent_id":"","transcript_path":"","tool_input":{"skill":"%s","description":"x"}}' \
        "$1" "$2" > "$TMP/s11-payload.json"
    REG_OUT=$( ( cd "$REPO" && CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" \
        AGENTS_CONFIG_DIR="$N" "$RWT" 25 bash -c "$REG_CMD" < "$TMP/s11-payload.json" ) 2>/dev/null )
    REG_RC=$?
}

build_fixture
REGISTRATION="$(read_registration)"
REG_VERDICT="$(printf '%s' "$REGISTRATION" | head -1)"
REG_CMD="$(printf '%s' "$REGISTRATION" | sed -n '2p')"

if [ "$REG_VERDICT" = "MATCH" ] && [ -n "$REG_CMD" ]; then
    pass "S11a: settings.json still registers the step-in-flight hook on a PostToolUse matcher that a Skill dispatch reaches"
else
    fail "S11a: no PostToolUse registration of postuse-step-in-flight-mark.js matches tool_name 'Skill' (verdict='$REG_VERDICT', command='$REG_CMD') — the real host would never fire the hook #2279 is about"
fi

if [ -n "$REG_CMD" ]; then
    dispatch_via_registration "$HEIR" resume-session
    if [ "$REG_RC" -eq 0 ]; then
        pass "S11b: the registered hook command survives the Skill(resume-session) payload and exits 0"
    else
        fail "S11b: the registered hook command exited $REG_RC on a Skill(resume-session) payload; out='$REG_OUT'"
    fi

    run_from "$DONOR"
    S11_STEPS="$(steps_of "$HEIR")"
    S11_PROBLEMS=""
    [ "$(from_field 'r.ok')" = "true" ] ||
        S11_PROBLEMS="$S11_PROBLEMS [--from refused: attempted=$(from_field 'r.attempted') error='$(from_field 'r.error')']"
    [ "$FROM_RC" -eq 0 ] || S11_PROBLEMS="$S11_PROBLEMS [--from exited $FROM_RC]"
    case "$S11_STEPS" in
        *workflow_init=complete*) ;;
        *) S11_PROBLEMS="$S11_PROBLEMS [the heir recorded '$S11_STEPS' — the donor's progress never arrived]" ;;
    esac
    if [ -z "$S11_PROBLEMS" ]; then
        pass "S11c: after the REGISTERED hook fires for the resume's own Skill dispatch, the real --from CLI still adopts the donor into the fresh heir"
    else
        fail "S11c: the registered-hook path breaks the adoption /resume-session --from was invoked for;$S11_PROBLEMS"
    fi
else
    fail "S11b/S11c: not run — no registered hook command to drive (see S11a)"
fi
cleanup

# ---------------------------------------------------------------------------
# S12 — idempotency. /resume-session is re-invocable, and a user who does not see
# the first run land types it again. The second `--from` must be a refusal, not a
# second adoption: the heir is no longer untouched once its own adoption
# succeeded, and re-adopting would append the donor's event stream twice.
# ---------------------------------------------------------------------------
build_fixture

state_bytes() { cat "$STORE/$1.json" 2>/dev/null; }

event_count() {
    CLAUDE_WORKFLOW_DIR="$STORE_N" WORKFLOW_PLANS_DIR="$STORE_N" SID="$1" "$RWT" 15 node -e "
const s = require('$SIO').readState(process.env.SID) || {};
process.stdout.write(String(((s.events) || []).length));" 2>/dev/null
}

run_from "$DONOR"
if [ "$(from_field 'r.ok')" = "true" ] && [ "$FROM_RC" -eq 0 ]; then
    pass "S12a: the first --from adoption succeeds (the precondition the re-run is measured against)"
else
    fail "S12a: the first --from adoption failed (rc=$FROM_RC, error='$(from_field 'r.error')') — S12b/S12c would prove nothing"
fi

S12_BYTES_BEFORE="$(state_bytes "$HEIR")"
S12_EVENTS_BEFORE="$(event_count "$HEIR")"
S12_STEPS_BEFORE="$(steps_of "$HEIR")"

run_from "$DONOR"
S12_ERROR="$(from_field 'r.error')"
S12_PROBLEMS=""
[ "$(from_field 'r.attempted')" = "true" ] ||
    S12_PROBLEMS="$S12_PROBLEMS [the re-run never reached the adoption gate: attempted=$(from_field 'r.attempted')]"
[ "$(from_field 'r.ok')" = "false" ] ||
    S12_PROBLEMS="$S12_PROBLEMS [the re-run adopted a SECOND time: ok=$(from_field 'r.ok')]"
case "$S12_ERROR" in
    *"has already recorded workflow steps"*) ;;
    *) S12_PROBLEMS="$S12_PROBLEMS [refusal message is '$S12_ERROR', not the documented already-touched refusal from adopt.js]" ;;
esac
if [ -z "$S12_PROBLEMS" ]; then
    pass "S12b: re-running the same --from against an heir that already adopted returns the documented already-recorded-steps refusal"
else
    fail "S12b: the --from re-run is not the documented refusal;$S12_PROBLEMS"
fi

S12_STATE_PROBLEMS=""
[ "$(state_bytes "$HEIR")" = "$S12_BYTES_BEFORE" ] ||
    S12_STATE_PROBLEMS="$S12_STATE_PROBLEMS [the heir's state file changed under a refused re-run]"
[ "$(event_count "$HEIR")" = "$S12_EVENTS_BEFORE" ] ||
    S12_STATE_PROBLEMS="$S12_STATE_PROBLEMS [event count moved $S12_EVENTS_BEFORE -> $(event_count "$HEIR"): the inheritance was appended twice]"
[ "$(steps_of "$HEIR")" = "$S12_STEPS_BEFORE" ] ||
    S12_STATE_PROBLEMS="$S12_STATE_PROBLEMS [steps moved '$S12_STEPS_BEFORE' -> '$(steps_of "$HEIR")']"
[ "$FROM_RC" -eq 0 ] ||
    S12_STATE_PROBLEMS="$S12_STATE_PROBLEMS [the re-run exited $FROM_RC; a refused adoption on a KNOWN donor is not the exit-3 unknown-session verdict]"
if [ -z "$S12_STATE_PROBLEMS" ]; then
    pass "S12c: the refused re-run leaves the heir byte-identical — no duplicate inheritance events, no re-stamped steps"
else
    fail "S12c: the refused re-run still mutated the heir;$S12_STATE_PROBLEMS"
fi
cleanup

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

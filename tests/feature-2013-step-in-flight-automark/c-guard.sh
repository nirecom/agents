# c-guard.sh — C1-C3: the REAL C4 premature-stop guard, driven as a child
# process over every allowlisted step (#2013).
# Sourced by tests/feature-2013-step-in-flight-automark.sh.
# Tests: hooks/stop-premature-stop-guard.js, hooks/lib/stop-exemption-policy.js, hooks/lib/step-in-flight-policy.js
# Tags: step-in-flight, stop-hook, c4, allowlist, matrix, regression-2013, scope:issue-specific, pwsh-not-required, TL2

# A-cases assert the predicate and B-cases assert the write, but #2013 is a
# complaint about the GUARD: the user was nudged mid-dispatch. Between the
# predicate and that experience sit the exemption policy and the guard's own
# ordering, and neither is exercised by calling isStepInFlight directly.

# The matrix is deliberately full — 4 allowlisted steps x 4 record states — for
# CPR-ORTH: the four steps are symmetric members of one class, so an exemption
# wired up for `research` alone (the step in the original report) would satisfy
# a single-step test while leaving the other three reproducing the bug.

# _seed_row <tmp> <sid> <prereqs> <step> <state> — write the state file directly,
# the way tests/feature-1498-stop-premature-stop-guard/state-seeds.sh does.
#
# markStep is NOT usable here: the approval-gated steps (outline in particular)
# refuse a plain complete, so a markStep-built fixture leaves outline pending
# behind a complete detail. next-step then reports that compaction gap and emits
# ACTION=abort — and the guard is silent for a reason that has nothing to do with
# the record under test. Writing the state directly keeps the matrix honest.
_seed_row() {
    local tmp="$1" sid="$2" prereqs="$3" step="$4" state="$5" age=0
    case "$state" in
        fresh)   age=$((TTL_MS - 60000)) ;;
        expired) age=$((TTL_MS + 60000)) ;;
    esac
    P="$(node_path "$tmp/$sid.json")" SID="$sid" DONE="$prereqs" ST="$step" \
    STATE="$state" AGE="$age" "$RWT" 15 node -e "
const fs = require('fs');
const now = new Date().toISOString();
const ALL = ['workflow_init','clarify_intent','research','outline','detail','branching_complete',
  'write_tests','review_tests','run_tests','review_security','docs','user_verification',
  'cleanup','pre_final_report_gate'];
const done = new Set(process.env.DONE.trim().split(/\s+/).filter(Boolean));
const steps = {};
for (const s of ALL) steps[s] = done.has(s) ? { status: 'complete', updated_at: now } : { status: 'pending', updated_at: null };
const state = process.env.STATE;
const at = new Date(Date.now() - Number(process.env.AGE)).toISOString();
if (state === 'complete') steps[process.env.ST] = { status: 'complete', updated_at: now };
else if (state !== 'pending') steps[process.env.ST] = { status: 'in_progress', updated_at: at };
fs.writeFileSync(process.env.P, JSON.stringify({ version: 1, session_id: process.env.SID,
  created_at: now, steps, workflow_type: 'wf-code' }, null, 2));" >/dev/null 2>&1
    # The `detail` step refuses to be recommended when neither the intent nor the
    # outline artifact exists — next-step calls that `detail-input-missing` and
    # emits `blocked`, which the guard passes over in silence. Supplying the
    # upstream artifact keeps the detail rows measuring the in-flight record.
    : > "$tmp/$sid-intent.md"
}

# _row_env <tmp> — a per-row throwaway repo, so the git-evidence resolver cannot
# reach the developer's worktree. Sets FIXTURE_REPO.
_row_env() {
    FIXTURE_REPO="$1/repo"
    make_repo_fixture "$FIXTURE_REPO"
}

# ---------------------------------------------------------------------------
# C1: the matrix. rc 0 = the guard stayed silent (the dispatch is honoured);
#     rc 2 = the guard blocked and the user got nudged. Only ONE of the four
#     record states buys silence, and it buys it for all four steps alike.
# ---------------------------------------------------------------------------
run_C1() {
    local step prereqs state want tmp tn sid anchor problems=""
    while IFS='|' read -r step prereqs; do
        step="$(trim "$step")"; prereqs="$(trim "$prereqs")"
        case "$step" in ''|'#'*) continue ;; esac
        for state in fresh expired pending complete; do
            [ "$state" = "fresh" ] && want=0 || want=2
            tmp="$(make_tmp)"; tn="$(node_path "$tmp")"; sid="c1-$step-$state"
            _seed_row "$tmp" "$sid" "$prereqs" "$step" "$state"
            _row_env "$tmp"
            # Anchor: if the fixture never landed, an observed rc proves nothing
            # about the record it was supposed to be reacting to.
            anchor="$(step_status "$tmp" "$sid" "$step")"
            case "$state:$anchor" in
                fresh:in_progress|expired:in_progress|pending:pending|complete:complete) : ;;
                *) problems="$problems [$step/$state: fixture left the record at '$anchor']" ;;
            esac
            run_c4 "$tn" "$sid"
            [ "$C4_RC" = "$want" ] ||
                problems="$problems [$step/$state: C4 rc=$C4_RC, expected $want]"
            if [ "$want" = "0" ] && [ "$C4_RC" = "0" ] && [ -n "$C4_OUT" ]; then
                problems="$problems [$step/$state: C4 exited 0 but still printed '$C4_OUT']"
            fi
            rm -rf "$tmp" 2>/dev/null || true
        done
    done <<'EOF'
# step         | prerequisite steps to settle first
research       | workflow_init clarify_intent
detail         | workflow_init clarify_intent research outline
write_tests    | workflow_init clarify_intent research outline detail branching_complete
review_tests   | workflow_init clarify_intent research outline detail branching_complete write_tests
EOF
    if [ -z "$problems" ]; then
        pass "C1: the real C4 guard is silent for a fresh in-flight record and blocks on expired/pending/complete — identically for all 4 allowlisted steps (16 rows)"
    else
        fail "C1: C4 disagrees with the step-in-flight record;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C2: the non-allowlisted counterpart, so C1's silences cannot come from a
#     blanket "any in_progress step is in flight" rule. `docs` in_progress and
#     well inside the TTL must still be nudgeable — the exemption is scoped by
#     allowlist, not by status (the same boundary A5/A6 assert on the predicate).
# ---------------------------------------------------------------------------
run_C2() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    _seed_row "$tmp" c2 \
        "workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security" \
        docs fresh
    _row_env "$tmp"
    [ "$(step_status "$tmp" c2 docs)" = "in_progress" ] ||
        problems="$problems [fixture: docs is not in_progress on disk]"
    run_c4 "$tn" c2
    [ "$C4_RC" = "2" ] ||
        problems="$problems [C4 rc=$C4_RC, expected 2 — a fresh in_progress 'docs' must not silence the guard]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C2: a fresh in_progress record on the non-allowlisted step 'docs' does NOT silence C4"
    else
        fail "C2: the step-in-flight exemption over-reaches beyond the allowlist;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C3: the end-to-end sentence #2013 actually reports — no hand-seeded record at
#     all. A session at research dispatches an Agent, the PostToolUse hook marks
#     it, and the Stop guard that fires moments later is silent. C1 proves the
#     guard honours a record; this proves the hook produces one the guard honours,
#     which is the seam a fix applied to only one side would leave broken.
# ---------------------------------------------------------------------------
run_C3() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" c3
    _row_env "$tmp"
    run_c4 "$tn" c3
    [ "$C4_RC" = "2" ] ||
        problems="$problems [before the dispatch C4 rc=$C4_RC, expected 2 — the baseline nudge is missing, so the silence below proves nothing]"
    run_automark "$tn" c3 Agent
    [ "$AM_RC" -eq 0 ] || problems="$problems [the auto-mark hook exited $AM_RC]"
    [ "$(step_status "$tmp" c3 research)" = "in_progress" ] ||
        problems="$problems [the dispatch did not leave research in_progress]"
    run_c4 "$tn" c3
    [ "$C4_RC" = "0" ] ||
        problems="$problems [after the dispatch C4 rc=$C4_RC, expected 0 — this is the #2013 nudge itself]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C3: an Agent dispatch flips C4 from blocking to silent through the real hook and the real guard (the #2013 report, end to end)"
    else
        fail "C3: the dispatch does not reach the guard;$problems"
    fi
}

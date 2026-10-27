#!/usr/bin/env bash
# tests/hooks/feature-1733-state-event-stream/session-inherit.sh
# Tests: hooks/session-start.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/effective-state.js
# Tags: workflow-state, event-stream, session-inherit, provenance, backfilled, regression-772, regression-1133, scope:issue-specific, pwsh-not-required, TL2, regression-2304

# Since #2304 session-start.js copies the donor's stream verbatim (seq/at/origin/provenance kept) up to upstream_copy_seq and appends
# only the revert events (#772 cleanup triple) after it; session facts travel with the copy. Every annotation the gates decide on
# must still travel, the cleanup notes must still be dropped, and the copied events must not count as this session's own action.
# TL3 gap: a real SessionStart firing inside Claude Code (the hook is fed stdin JSON from a real cwd/branch; settings.json registration is not exercised).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CASE_TAG="si"
# shellcheck source=tests/hooks/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# isolation (#2512): pin state and plans dirs file-wide to common.sh's fixture dirs; the per-call pins below still override them.
export WORKFLOW_STATE_DIR="$WF_NATIVE" WORKFLOW_PLANS_DIR="$PLANS_NATIVE"

# ── donor discovery fixture ──────────────────────────────────────────────────
# Since #1305 a donor is reached through the HEIR's OWN lineage, not the cwd's latest transcript: resolveInheritanceDonor
# (hooks/workflow-state/inheritance.js) collects the ancestors named by `forkedFrom` rows (and copied SessionStart/PostCompact
# announce lines) and takes the nearest one holding state. The donor's announce line is only the ancestor-id → state-file
# breadcrumb. session-start.js is driven via stdin here, so both the announce line and the heir's lineage row are manufactured.
TRANSCRIPTS_BASE="$TMPROOT/transcripts"; mkdir -p "$TRANSCRIPTS_BASE"
TRANSCRIPTS_BASE_NATIVE="$(native_path "$TRANSCRIPTS_BASE")"

# The directory name the transcript lookup derives from ctx.cwd is
# ctx.cwd.toLowerCase().replace(/[^a-zA-Z0-9]/g, "-") — computed by asking node
# itself, in the same cwd ($SCRIPT_CHECKOUT_ROOT, no CLAUDE_PROJECT_DIR override) that
# session-start.js runs from below, rather than reimplemented in bash, so it can
# never drift from the source's own algorithm across platforms.
ENCODED_CWD="$(cd "$SCRIPT_CHECKOUT_ROOT" && node -e 'console.log(require("path").resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g, "-"))')"
TRANSCRIPT_DIR="$TRANSCRIPTS_BASE/$ENCODED_CWD"; mkdir -p "$TRANSCRIPT_DIR"

# announce_donor <donor-sid> — makes <donor-sid> resolvable once the heir names it:
#   1. Writes a synthetic transcript line, shaped exactly like a real Claude Code
#      SessionStart hook attachment, announcing the donor's session_id. This is the
#      ancestor-id → state-file breadcrumb, not an inheritance trigger.
#   2. Ensures the clarify_intent plan artifact exists (evaluateResumability's S3 rule
#      refuses a genuinely-complete clarify_intent with no intent.md). SEED_DONOR's
#      approvals already wrote it; it is never overwritten, because the approval
#      recorded its hash and the copy would revert on artifact-hash-mismatch (#2633).
announce_donor() {
    local donor="$1"
    printf '{"type":"attachment","attachment":{"hookEvent":"SessionStart","exitCode":0,"stdout":"Current workflow session_id: %s"}}\n' \
        "$donor" > "$TRANSCRIPT_DIR/$donor.jsonl"
    if [ ! -e "$PLANS/$donor-intent.md" ]; then
        printf '# fixture intent\n' > "$PLANS/$donor-intent.md"
    fi
}

# seed_heir_lineage <heir-sid> <donor-sid> — the heir's own transcript, carrying
# the `forkedFrom` row that makes the donor its ancestor (#1305).
seed_heir_lineage() {
    printf '{"type":"user","uuid":"u1-%s","sessionId":"%s","forkedFrom":{"sessionId":"%s","messageUuid":"m1"}}\n' \
        "$1" "$1" "$2" > "$TRANSCRIPT_DIR/$1.jsonl"
}

# start_session <sid> — drives the real SessionStart hook, as Claude Code does.
# `source` and `transcript_path` are part of the real SessionStart payload and are
# what lineage resolution needs: only a continuation (resume/compact) may inherit,
# and the transcript is where its ancestry is read from.
start_session() {
    local sid="$1" src="${2:-resume}"
    HOOK_RC=0
    HOOK_OUT="$(cd "$SCRIPT_CHECKOUT_ROOT" && printf '{"session_id":"%s","source":"%s","transcript_path":"%s"}' \
        "$sid" "$src" "$TRANSCRIPTS_BASE_NATIVE/$ENCODED_CWD/$sid.jsonl" | env \
        WORKFLOW_STATE_DIR="$WF_NATIVE" AGENTS_MAIN_ROOT="$CFG_NATIVE" \
        WORKFLOW_PLANS_DIR="$PLANS_NATIVE" CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_BASE_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 node hooks/session-start.js 2>&1)" || HOOK_RC=$?
}

# Seeds the DONOR session: created with the current cwd+branch so
# findLatestStateForContext matches it, and carrying one annotation of every kind the
# inheritance table names.
#
# ORDER MATTERS: createInitialState() must be written BEFORE the approvals are recorded.
# recordPlanApproval persists plan_approvals into the state file, so seeding it first and
# then writing a fresh initial state over the top wipes the very records the outline/detail
# completions below are gated on — the donor would die on UnapprovedCompletionError and
# every case in this file would be red for a fixture reason rather than a feature one.
SEED_DONOR="$PRE"'
S.writeState(sid, S.createInitialState(sid, S.getCurrentContext()));
'"$APPROVE_GATED_JS"'
S.markStep(sid, "workflow_init", "complete");
S.markStep(sid, "clarify_intent", "complete");
S.markStep(sid, "research", "skipped", { skip_reason: "nothing to survey" });
S.markStep(sid, "outline", "complete");
S.markStep(sid, "detail", "complete");
S.markStep(sid, "review_tests", "complete", { token: "tok-donor", wsid: "wsid-donor", warnings_summary: "2 advisory findings" });
S.markStep(sid, "branching_complete", "pending", { reset_reason: "post-merge" });
S.markStep(sid, "cleanup", "complete", { skip_reason: "donor-cleanup-note" });
require("./hooks/workflow-state/state-io/skip-verdict").recordSkipVerdict(sid, "detail", "confirm", "skip-verifier");
require("./hooks/workflow-state/skip-signal-resolver").recordSkipJudgment(sid, "outline", { c1: true }, "test-source");
S.recordSessionModel(sid, { id: "claude-opus-5", source: "transcript" });
S.recordComplexityEvaluation(sid, ["S1-multi-file", "S2-architecture"]);
S.setLastPushedSha(sid, "0".repeat(40));
{ const st = S.readState(sid); st.closes_issues = [1733]; S.writeState(sid, st); }
console.log("DONOR-READY");
'

# Every case needs the same donor+heir pair; build it once per case for isolation.
seed_pair() { # sets DONOR and HEIR
    next_sid; DONOR="$SID"
    nodejs "$DONOR" "$SEED_DONOR"
    announce_donor "$DONOR"
    next_sid; HEIR="$SID"
    seed_heir_lineage "$HEIR" "$DONOR"
    start_session "$HEIR"
}

echo "== SI1: the heir's stream opens with a verbatim copy of the donor's, bounded by upstream_copy_seq =="
if run_case "SI1/verbatim-copy"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const heir = rd();
const donorEvents = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, process.env.DONOR + ".json"), "utf8")).events;
const pre = heir.events.filter((e) => e.seq <= heir.upstream_copy_seq);
console.log("boundary_is_donor_count=" + (heir.upstream_copy_seq === donorEvents.length) +
            " pre_equals_donor=" + (JSON.stringify(pre) === JSON.stringify(donorEvents)) +
            " seq_contiguous=" + heir.events.every((e, i) => e.seq === i + 1));
'
    assert_eq "SI1/verbatim-copy" "boundary_is_donor_count=true pre_equals_donor=true seq_contiguous=true" "$NODE_OUT"
fi

echo "== SI2: only the events after the boundary are session-inherit/backfilled; none names a donor =="
if run_case "SI2/boundary-provenance"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const st = rd();
const b = st.upstream_copy_seq;
const post = st.events.filter((e) => e.seq > b && e.step !== undefined);
const badPost = post.filter((e) => e.origin !== "session-inherit" || e.provenance !== "backfilled").map((e) => e.kind + ":" + e.step);
const preInherit = st.events.filter((e) => e.seq <= b && e.origin === "session-inherit").length;
const named = st.events.filter((e) => Object.prototype.hasOwnProperty.call(e, "inherited_from")).length;
console.log("post=" + (post.length > 0) +
            " post_not_backfilled_inherit=" + (badPost.join(",") || "0") +
            " pre_session_inherit=" + preInherit +
            " inherited_from=" + named +
            " upstream=" + (st.upstream_session_id === process.env.DONOR));
'
    assert_eq "SI2/boundary-provenance" \
        "post=true post_not_backfilled_inherit=0 pre_session_inherit=0 inherited_from=0 upstream=true" "$NODE_OUT"
fi

echo "== SI3: statuses project as in the donor; a pending step keeps exactly the donor's events =="
if run_case "SI3/statuses-as-donor"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const s = st.steps;
const count = (raw) => raw.events.filter((e) => e.kind === "step_status" && e.step === "branching_complete").length;
const donorRaw = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, process.env.DONOR + ".json"), "utf8"));
console.log([
  "workflow_init=" + s.workflow_init.status,
  "research=" + s.research.status,
  "review_tests=" + s.review_tests.status,
  "branching_complete=" + s.branching_complete.status,
  "branching_status_events_as_donor=" + (count(rd()) === count(donorRaw) && count(donorRaw) > 0),
].join(" "));
'
    assert_eq "SI3/statuses-as-donor" \
        "workflow_init=complete research=skipped review_tests=complete branching_complete=pending branching_status_events_as_donor=true" \
        "$NODE_OUT"
fi

echo "== SI4: annotations travel — including those on a PENDING step =="
if run_case "SI4/annotations-inherited"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const s = S.readState(sid).steps;
console.log([
  "skip_reason=" + s.research.skip_reason,
  "token=" + s.review_tests.token,
  "wsid=" + s.review_tests.wsid,
  "warnings=" + s.review_tests.warnings_summary,
  "skip_verdict=" + (s.detail.skip_verdict && s.detail.skip_verdict.verdict),
  "skip_judgment=" + (s.outline.skip_judgment && s.outline.skip_judgment.all_conditions_met),
  // reset_reason lives on a pending step; dropping it would lose the reason a step
  // was rewound.
  "reset_reason=" + s.branching_complete.reset_reason,
].join(" "));
'
    assert_eq "SI4/annotations-inherited" \
        "skip_reason=nothing to survey token=tok-donor wsid=wsid-donor warnings=2 advisory findings skip_verdict=confirm skip_judgment=true reset_reason=post-merge" \
        "$NODE_OUT"
fi

echo "== SI4b: an inner recorded_at inside an inherited object value is preserved =="
if run_case "SI4b/inner-recorded-at-preserved"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const donor = S.readState(process.env.DONOR);
const heir = S.readState(sid);
const a = donor.steps.detail.skip_verdict;
const b = heir.steps.detail.skip_verdict;
console.log(JSON.stringify(a) === JSON.stringify(b) ? "VERBATIM" : "ALTERED\ndonor=" + JSON.stringify(a) + "\nheir =" + JSON.stringify(b));
'
    assert_eq "SI4b/inner-recorded-at-preserved" "VERBATIM" "$NODE_OUT"
fi

echo "== SI5: #772 — cleanup becomes skipped and the donor's cleanup notes are dropped =="
if run_case "SI5/cleanup-reset-772"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const s = S.readState(sid).steps;
const ev = rd().events.filter((e) => e.step === "cleanup");
console.log([
  "status=" + s.cleanup.status,
  "skip_reason=" + s.cleanup.skip_reason,
  "cleared_event=" + ev.some((e) => e.kind === "step_annotations_cleared"),
  // The donor note must be GONE, not merely shadowed.
  "donor_note_in_projection=" + /donor-cleanup-note/.test(JSON.stringify(s.cleanup)),
].join(" "));
'
    assert_eq "SI5/cleanup-reset-772" \
        "status=skipped skip_reason=inherited-from-prior-session cleared_event=true donor_note_in_projection=false" \
        "$NODE_OUT"
fi

echo "== SI6: #1133 — plan approvals travel and keep artifact_session_id =="
if run_case "SI6/plan-approvals-1133"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const pa = st.plan_approvals || {};
const steps = Object.keys(pa).sort();
const bad = steps.filter((s) => pa[s].artifact_session_id !== process.env.DONOR);
console.log("steps=" + steps.join(",") +
            " wrong_artifact_sid=" + (bad.join(",") || "0") +
            " events=" + rd().events.filter((e) => e.kind === "plan_approval").length);
'
    # An empty approvals map here would mean writeState threw no-approval-record and the
    # heir got no state file at all — the exact #1133 symptom. #2277 adds clarify_intent to the gated class.
    assert_eq "SI6/plan-approvals-1133" "steps=clarify_intent,detail,outline wrong_artifact_sid=0 events=3" "$NODE_OUT"
fi

echo "== SI7: session facts (session_model, complexity, closes_issues, last_pushed_sha) are copied =="
if run_case "SI7/session-facts-copied"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const donor = S.readState(process.env.DONOR);
const ev = rd().events;
const donorEv = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, process.env.DONOR + ".json"), "utf8")).events;
const n = (list, kind) => list.filter((e) => e.kind === kind).length;
console.log([
  "session_model=" + (JSON.stringify(st.session_model) === JSON.stringify(donor.session_model) && !!st.session_model),
  "complexity=" + (JSON.stringify(st.complexity_evaluation) === JSON.stringify(donor.complexity_evaluation) && !!st.complexity_evaluation),
  "model_events=" + (n(ev, "session_model") === n(donorEv, "session_model")),
  "complexity_events=" + (n(ev, "complexity_evaluation") === n(donorEv, "complexity_evaluation")),
  "closes_issues=" + JSON.stringify(st.closes_issues || null),
  "last_pushed_sha=" + JSON.stringify(st.last_pushed_sha || null),
].join(" "));
'
    assert_eq "SI7/session-facts-copied" \
        "session_model=true complexity=true model_events=true complexity_events=true closes_issues=[1733] last_pushed_sha=\"0000000000000000000000000000000000000000\"" \
        "$NODE_OUT"
fi

echo "== SI8: the heir's context is its own, not the donor's =="
if run_case "SI8/own-context"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const ctx = S.getCurrentContext();
console.log("branch_matches_cwd=" + (st.git_branch === ctx.git_branch) +
            " cwd_matches=" + (st.cwd === ctx.cwd) +
            " session_id=" + (st.session_id === sid));
'
    assert_eq "SI8/own-context" "branch_matches_cwd=true cwd_matches=true session_id=true" "$NODE_OUT"
fi

echo "== SI9: copied completes keep the donor's provenance yet do not count as this session's start =="
if run_case "SI9/copied-not-started"; then
    seed_pair
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE"'
const L = require("./hooks/workflow-state/lifecycle");
const st0 = rd();
// Guard: the subject must have been copied as the donor recorded it, or "not started" is vacuous.
const seeded = st0.events.some((e) => e.kind === "step_status" && e.step === "clarify_intent" && e.status === "complete" &&
                                      e.origin === "mark-step" && e.provenance === "observed" && e.seq <= st0.upstream_copy_seq);
const before = L.isWorkflowStarted(sid);
S.markStep(sid, "outline", "skipped", { skip_reason: "fixture" });
const after = L.isWorkflowStarted(sid);
console.log("subject_copied=" + seeded + " started_after_copy=" + before + " after_real_mark=" + after +
            " still_projects_complete=" + (S.readState(sid).steps.clarify_intent.status === "complete"));
'
    assert_eq "SI9/copied-not-started" \
        "subject_copied=true started_after_copy=false after_real_mark=true still_projects_complete=true" "$NODE_OUT"
fi

echo "== SI10: inheritance is one batch — a second SessionStart is a no-op =="
if run_case "SI10/idempotent-session-start"; then
    seed_pair
    BEFORE_BYTES="$(cksum < "$WF/$HEIR.json" | awk '{print $1}')"
    start_session "$HEIR"
    AFTER_BYTES="$(cksum < "$WF/$HEIR.json" | awk '{print $1}')"
    assert_eq "SI10/idempotent-session-start" "same" \
        "$([ "$BEFORE_BYTES" = "$AFTER_BYTES" ] && echo same || echo changed)"
fi

echo "== SI11: with no donor in range, the heir is a plain initial state =="
if run_case "SI11/no-donor-plain-init"; then
    # Needs a workflow dir with no donor in it. Every other case in this file shares
    # $WF, which by now holds several matching-context donors, so this case runs against
    # its own empty dir.
    next_sid
    EMPTY_WF="$TMPROOT/wf-empty"; mkdir -p "$EMPTY_WF"
    EMPTY_WF_NATIVE="$(native_path "$EMPTY_WF")"
    # Same realistic SessionStart payload as start_session; the heir simply has no
    # ancestor to name, which is what "no donor in range" means after #1305.
    (cd "$SCRIPT_CHECKOUT_ROOT" && printf '{"session_id":"%s","source":"resume","transcript_path":"%s"}' \
        "$SID" "$TRANSCRIPTS_BASE_NATIVE/$ENCODED_CWD/$SID.jsonl" | env \
        WORKFLOW_STATE_DIR="$EMPTY_WF_NATIVE" AGENTS_MAIN_ROOT="$CFG_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 node hooks/session-start.js >/dev/null 2>&1) || true
    NODE_OUT="$(cd "$SCRIPT_CHECKOUT_ROOT" && env \
        WORKFLOW_STATE_DIR="$EMPTY_WF_NATIVE" AGENTS_MAIN_ROOT="$CFG_NATIVE" \
        HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" SID="$SID" \
        "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 node -e "$PRE"'
const st = S.readState(sid);
const nonPending = S.VALID_STEPS.filter((s) => st.steps[s].status !== "pending");
console.log("inherit_events=" + rd().events.filter((e) => e.origin === "session-inherit").length +
            " non_pending=" + (nonPending.join(",") || "0") +
            " version=" + rd().version);
' 2>&1)" || true
    assert_eq "SI11/no-donor-plain-init" "inherit_events=0 non_pending=0 version=$EXPECT_STATE_VERSION" "$NODE_OUT"
fi

echo "== SI12: inheriting leaves the DONOR's own state file byte-identical =="
if run_case "SI12/donor-immutable"; then
    # Inheritance reads the donor and writes the heir. A donor that gets touched at all —
    # a "last_inherited_by" stamp, a re-serialisation that reorders keys, a lock left
    # behind — corrupts a session that may still be RUNNING (SI1..SI11 all assert on the
    # heir, so none of them would notice). Compared as raw bytes on purpose: any rewrite,
    # semantically neutral or not, is a write to someone else's live file.
    next_sid; DONOR="$SID"
    nodejs "$DONOR" "$SEED_DONOR"
    assert_eq "SI12/donor-seeded" "DONOR-READY" "$NODE_OUT"
    announce_donor "$DONOR"

    DONOR_BEFORE="$(cksum < "$WF/$DONOR.json" 2>/dev/null | awk '{print $1}')"
    next_sid; HEIR="$SID"
    seed_heir_lineage "$HEIR" "$DONOR"
    start_session "$HEIR"
    DONOR_AFTER="$(cksum < "$WF/$DONOR.json" 2>/dev/null | awk '{print $1}')"

    # -n guards the vacuous pass: with no donor file at all both checksums are empty.
    if [ -n "$DONOR_BEFORE" ] && [ "$DONOR_BEFORE" = "$DONOR_AFTER" ]; then
        DONOR_VERDICT="same"
    else
        DONOR_VERDICT="changed"
    fi
    assert_eq "SI12/donor-bytes-unchanged" "same" "$DONOR_VERDICT"

    # A .lock or .tmp beside the donor means the inheritance took the donor's WRITE path.
    DONOR_DEBRIS="$(find "$WF" -maxdepth 1 -name "$DONOR.json.*" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "SI12/no-donor-debris" "0" "$DONOR_DEBRIS"

    # And the heir must actually have inherited — otherwise "donor untouched" is trivially
    # true because nothing happened.
    nodejs_env "DONOR=$DONOR" "$HEIR" "$PRE"'
console.log("inherit_events=" + (rd().events.filter((e) => e.origin === "session-inherit").length > 0) +
            " upstream=" + (rd().upstream_session_id === process.env.DONOR));
'
    assert_eq "SI12/heir-did-inherit" "inherit_events=true upstream=true" "$NODE_OUT"
fi

finish "session-inherit"

#!/usr/bin/env bash
# tests/hooks/feature-1733-state-event-stream/session-inherit.sh
# Tests: hooks/session-start.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/effective-state.js
# Tags: workflow-state, event-stream, session-inherit, provenance, backfilled, regression-772, regression-1133, scope:issue-specific, pwsh-not-required, TL2, regression-2304

# Since #2304 session-start.js copies the upstream's stream verbatim (seq/at/origin/provenance kept) up to upstream_copy_seq and appends
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

# ── upstream discovery fixture ──────────────────────────────────────────────────
# Since #1305 a upstream is reached through the DOWNSTREAM's OWN lineage, not the cwd's latest transcript: resolveInheritanceUpstream
# (hooks/workflow-state/inheritance.js) collects the ancestors named by `forkedFrom` rows (and copied SessionStart/PostCompact
# announce lines) and takes the nearest one holding state. The upstream's announce line is only the ancestor-id → state-file
# breadcrumb. session-start.js is driven via stdin here, so both the announce line and the downstream's lineage row are manufactured.
TRANSCRIPTS_BASE="$TMPROOT/transcripts"; mkdir -p "$TRANSCRIPTS_BASE"
TRANSCRIPTS_BASE_NATIVE="$(native_path "$TRANSCRIPTS_BASE")"

# The directory name the transcript lookup derives from ctx.cwd is
# ctx.cwd.toLowerCase().replace(/[^a-zA-Z0-9]/g, "-") — computed by asking node
# itself, in the same cwd ($SCRIPT_CHECKOUT_ROOT, no CLAUDE_PROJECT_DIR override) that
# session-start.js runs from below, rather than reimplemented in bash, so it can
# never drift from the source's own algorithm across platforms.
ENCODED_CWD="$(cd "$SCRIPT_CHECKOUT_ROOT" && node -e 'console.log(require("path").resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g, "-"))')"
TRANSCRIPT_DIR="$TRANSCRIPTS_BASE/$ENCODED_CWD"; mkdir -p "$TRANSCRIPT_DIR"

# announce_upstream <upstream-sid> — makes <upstream-sid> resolvable once the downstream names it:
#   1. Writes a synthetic transcript line, shaped exactly like a real Claude Code
#      SessionStart hook attachment, announcing the upstream's session_id. This is the
#      ancestor-id → state-file breadcrumb, not an inheritance trigger.
#   2. Ensures the clarify_intent plan artifact exists (evaluateResumability's S3 rule
#      refuses a genuinely-complete clarify_intent with no intent.md). SEED_UPSTREAM's
#      approvals already wrote it; it is never overwritten, because the approval
#      recorded its hash and the copy would revert on artifact-hash-mismatch (#2633).
announce_upstream() {
    local upstream="$1"
    printf '{"type":"attachment","attachment":{"hookEvent":"SessionStart","exitCode":0,"stdout":"Current workflow session_id: %s"}}\n' \
        "$upstream" > "$TRANSCRIPT_DIR/$upstream.jsonl"
    if [ ! -e "$PLANS/$upstream-intent.md" ]; then
        printf '# fixture intent\n' > "$PLANS/$upstream-intent.md"
    fi
}

# seed_downstream_lineage <downstream-sid> <upstream-sid> — the downstream's own transcript, carrying
# the `forkedFrom` row that makes the upstream its ancestor (#1305).
seed_downstream_lineage() {
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

# Seeds the UPSTREAM session: created with the current cwd+branch so
# findLatestStateForContext matches it, and carrying one annotation of every kind the
# inheritance table names.
#
# ORDER MATTERS: createInitialState() must be written BEFORE the approvals are recorded.
# recordPlanApproval persists plan_approvals into the state file, so seeding it first and
# then writing a fresh initial state over the top wipes the very records the outline/detail
# completions below are gated on — the upstream would die on UnapprovedCompletionError and
# every case in this file would be red for a fixture reason rather than a feature one.
SEED_UPSTREAM="$PRE"'
S.writeState(sid, S.createInitialState(sid, S.getCurrentContext()));
'"$APPROVE_GATED_JS$GLOSSARY_JS"'
S.markStep(sid, "workflow_init", "complete");
complete_gated(sid, "clarify_intent");
S.markStep(sid, "research", "skipped", { skip_reason: "nothing to survey" });
complete_gated(sid, "outline");
complete_gated(sid, "detail");
complete_gated(sid, "review_tests", { token: "tok-upstream", wsid: "wsid-upstream", warnings_summary: "2 advisory findings" });
S.markStep(sid, "branching_complete", "pending", { reset_reason: "post-merge" });
S.markStep(sid, "cleanup", "complete", { skip_reason: "upstream-cleanup-note" });
require("./hooks/workflow-state/state-io/skip-verdict").recordSkipVerdict(sid, "detail", "confirm", "skip-verifier");
require("./hooks/workflow-state/skip-signal-resolver").recordSkipJudgment(sid, "outline", { c1: true }, "test-source");
S.recordSessionModel(sid, { id: "claude-opus-5", source: "transcript" });
S.recordComplexityEvaluation(sid, ["S1-multi-file", "S2-architecture"]);
S.setLastPushedSha(sid, "0".repeat(40));
{ const st = S.readState(sid); st.closes_issues = [1733]; S.writeState(sid, st); }
console.log("UPSTREAM-READY");
'

# Every case needs the same upstream+downstream pair; build it once per case for isolation.
seed_pair() { # sets UPSTREAM and DOWNSTREAM
    next_sid; UPSTREAM="$SID"
    nodejs "$UPSTREAM" "$SEED_UPSTREAM"
    announce_upstream "$UPSTREAM"
    next_sid; DOWNSTREAM="$SID"
    seed_downstream_lineage "$DOWNSTREAM" "$UPSTREAM"
    start_session "$DOWNSTREAM"
}

echo "== SI1: the downstream's stream opens with a verbatim copy of the upstream's, bounded by upstream_copy_seq =="
if run_case "SI1/verbatim-copy"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
const downstream = rd();
const upstreamEvents = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, process.env.UPSTREAM + ".json"), "utf8")).events;
const pre = downstream.events.filter((e) => e.seq <= downstream.upstream_copy_seq);
console.log("boundary_is_upstream_count=" + (downstream.upstream_copy_seq === upstreamEvents.length) +
            " pre_equals_upstream=" + (JSON.stringify(pre) === JSON.stringify(upstreamEvents)) +
            " seq_contiguous=" + downstream.events.every((e, i) => e.seq === i + 1));
'
    assert_eq "SI1/verbatim-copy" "boundary_is_upstream_count=true pre_equals_upstream=true seq_contiguous=true" "$NODE_OUT"
fi

echo "== SI2: only the events after the boundary are session-inherit/backfilled; none names a upstream =="
if run_case "SI2/boundary-provenance"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
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
            " upstream=" + (st.upstream_session_id === process.env.UPSTREAM));
'
    assert_eq "SI2/boundary-provenance" \
        "post=true post_not_backfilled_inherit=0 pre_session_inherit=0 inherited_from=0 upstream=true" "$NODE_OUT"
fi

echo "== SI3: statuses project as in the upstream; a pending step keeps exactly the upstream's events =="
if run_case "SI3/statuses-as-upstream"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const s = st.steps;
const count = (raw) => raw.events.filter((e) => e.kind === "step_status" && e.step === "branching_complete").length;
const upstreamRaw = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, process.env.UPSTREAM + ".json"), "utf8"));
console.log([
  "workflow_init=" + s.workflow_init.status,
  "research=" + s.research.status,
  "review_tests=" + s.review_tests.status,
  "branching_complete=" + s.branching_complete.status,
  "branching_status_events_as_upstream=" + (count(rd()) === count(upstreamRaw) && count(upstreamRaw) > 0),
].join(" "));
'
    assert_eq "SI3/statuses-as-upstream" \
        "workflow_init=complete research=skipped review_tests=complete branching_complete=pending branching_status_events_as_upstream=true" \
        "$NODE_OUT"
fi

echo "== SI4: annotations travel — including those on a PENDING step =="
if run_case "SI4/annotations-inherited"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
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
        "skip_reason=nothing to survey token=tok-upstream wsid=wsid-upstream warnings=2 advisory findings skip_verdict=confirm skip_judgment=true reset_reason=post-merge" \
        "$NODE_OUT"
fi

echo "== SI4b: an inner recorded_at inside an inherited object value is preserved =="
if run_case "SI4b/inner-recorded-at-preserved"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
const upstream = S.readState(process.env.UPSTREAM);
const downstream = S.readState(sid);
const a = upstream.steps.detail.skip_verdict;
const b = downstream.steps.detail.skip_verdict;
console.log(JSON.stringify(a) === JSON.stringify(b) ? "VERBATIM" : "ALTERED\nupstream=" + JSON.stringify(a) + "\ndownstream =" + JSON.stringify(b));
'
    assert_eq "SI4b/inner-recorded-at-preserved" "VERBATIM" "$NODE_OUT"
fi

echo "== SI5: #772 — cleanup becomes skipped and the upstream's cleanup notes are dropped =="
if run_case "SI5/cleanup-reset-772"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
const s = S.readState(sid).steps;
const ev = rd().events.filter((e) => e.step === "cleanup");
console.log([
  "status=" + s.cleanup.status,
  "skip_reason=" + s.cleanup.skip_reason,
  "cleared_event=" + ev.some((e) => e.kind === "step_annotations_cleared"),
  // The upstream note must be GONE, not merely shadowed.
  "upstream_note_in_projection=" + /upstream-cleanup-note/.test(JSON.stringify(s.cleanup)),
].join(" "));
'
    assert_eq "SI5/cleanup-reset-772" \
        "status=skipped skip_reason=inherited-from-prior-session cleared_event=true upstream_note_in_projection=false" \
        "$NODE_OUT"
fi

echo "== SI6: #1133 — plan approvals travel and keep artifact_session_id =="
if run_case "SI6/plan-approvals-1133"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const pa = st.plan_approvals || {};
const steps = Object.keys(pa).sort();
const bad = steps.filter((s) => pa[s].artifact_session_id !== process.env.UPSTREAM);
console.log("steps=" + steps.join(",") +
            " wrong_artifact_sid=" + (bad.join(",") || "0") +
            " events=" + rd().events.filter((e) => e.kind === "plan_approval").length);
'
    # An empty approvals map here would mean writeState threw no-approval-record and the
    # downstream got no state file at all — the exact #1133 symptom. #2277 adds clarify_intent to the gated class.
    assert_eq "SI6/plan-approvals-1133" "steps=clarify_intent,detail,outline wrong_artifact_sid=0 events=3" "$NODE_OUT"
fi

echo "== SI7: session facts (session_model, complexity, closes_issues, last_pushed_sha) are copied =="
if run_case "SI7/session-facts-copied"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const upstream = S.readState(process.env.UPSTREAM);
const ev = rd().events;
const upstreamEv = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, process.env.UPSTREAM + ".json"), "utf8")).events;
const n = (list, kind) => list.filter((e) => e.kind === kind).length;
console.log([
  "session_model=" + (JSON.stringify(st.session_model) === JSON.stringify(upstream.session_model) && !!st.session_model),
  "complexity=" + (JSON.stringify(st.complexity_evaluation) === JSON.stringify(upstream.complexity_evaluation) && !!st.complexity_evaluation),
  "model_events=" + (n(ev, "session_model") === n(upstreamEv, "session_model")),
  "complexity_events=" + (n(ev, "complexity_evaluation") === n(upstreamEv, "complexity_evaluation")),
  "closes_issues=" + JSON.stringify(st.closes_issues || null),
  "last_pushed_sha=" + JSON.stringify(st.last_pushed_sha || null),
].join(" "));
'
    assert_eq "SI7/session-facts-copied" \
        "session_model=true complexity=true model_events=true complexity_events=true closes_issues=[1733] last_pushed_sha=\"0000000000000000000000000000000000000000\"" \
        "$NODE_OUT"
fi

echo "== SI8: the downstream's context is its own, not the upstream's =="
if run_case "SI8/own-context"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE$GENUINE_JS"'
const st = S.readState(sid);
const ctx = S.getCurrentContext();
console.log("branch_matches_cwd=" + (st.git_branch === ctx.git_branch) +
            " cwd_matches=" + (st.cwd === ctx.cwd) +
            " session_id=" + (st.session_id === sid));
'
    assert_eq "SI8/own-context" "branch_matches_cwd=true cwd_matches=true session_id=true" "$NODE_OUT"
fi

echo "== SI9: copied completes keep the upstream's provenance yet do not count as this session's start =="
if run_case "SI9/copied-not-started"; then
    seed_pair
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE"'
const L = require("./hooks/workflow-state/lifecycle");
const st0 = rd();
// Guard: the subject must have been copied as the upstream recorded it, or "not started" is vacuous.
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
    BEFORE_BYTES="$(cksum < "$WF/$DOWNSTREAM.json" | awk '{print $1}')"
    start_session "$DOWNSTREAM"
    AFTER_BYTES="$(cksum < "$WF/$DOWNSTREAM.json" | awk '{print $1}')"
    assert_eq "SI10/idempotent-session-start" "same" \
        "$([ "$BEFORE_BYTES" = "$AFTER_BYTES" ] && echo same || echo changed)"
fi

echo "== SI11: with no upstream in range, the downstream is a plain initial state =="
if run_case "SI11/no-upstream-plain-init"; then
    # Needs a workflow dir with no upstream in it. Every other case in this file shares
    # $WF, which by now holds several matching-context upstreams, so this case runs against
    # its own empty dir.
    next_sid
    EMPTY_WF="$TMPROOT/wf-empty"; mkdir -p "$EMPTY_WF"
    EMPTY_WF_NATIVE="$(native_path "$EMPTY_WF")"
    # Same realistic SessionStart payload as start_session; the downstream simply has no
    # ancestor to name, which is what "no upstream in range" means after #1305.
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
    assert_eq "SI11/no-upstream-plain-init" "inherit_events=0 non_pending=0 version=$EXPECT_STATE_VERSION" "$NODE_OUT"
fi

echo "== SI12: inheriting leaves the UPSTREAM's own state file byte-identical =="
if run_case "SI12/upstream-immutable"; then
    # Inheritance reads the upstream and writes the downstream. A upstream that gets touched at all —
    # a "last_inherited_by" stamp, a re-serialisation that reorders keys, a lock left
    # behind — corrupts a session that may still be RUNNING (SI1..SI11 all assert on the
    # downstream, so none of them would notice). Compared as raw bytes on purpose: any rewrite,
    # semantically neutral or not, is a write to someone else's live file.
    next_sid; UPSTREAM="$SID"
    nodejs "$UPSTREAM" "$SEED_UPSTREAM"
    assert_eq "SI12/upstream-seeded" "UPSTREAM-READY" "$NODE_OUT"
    announce_upstream "$UPSTREAM"

    UPSTREAM_BEFORE="$(cksum < "$WF/$UPSTREAM.json" 2>/dev/null | awk '{print $1}')"
    next_sid; DOWNSTREAM="$SID"
    seed_downstream_lineage "$DOWNSTREAM" "$UPSTREAM"
    start_session "$DOWNSTREAM"
    UPSTREAM_AFTER="$(cksum < "$WF/$UPSTREAM.json" 2>/dev/null | awk '{print $1}')"

    # -n guards the vacuous pass: with no upstream file at all both checksums are empty.
    if [ -n "$UPSTREAM_BEFORE" ] && [ "$UPSTREAM_BEFORE" = "$UPSTREAM_AFTER" ]; then
        UPSTREAM_VERDICT="same"
    else
        UPSTREAM_VERDICT="changed"
    fi
    assert_eq "SI12/upstream-bytes-unchanged" "same" "$UPSTREAM_VERDICT"

    # A .lock or .tmp beside the upstream means the inheritance took the upstream's WRITE path.
    UPSTREAM_DEBRIS="$(find "$WF" -maxdepth 1 -name "$UPSTREAM.json.*" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "SI12/no-upstream-debris" "0" "$UPSTREAM_DEBRIS"

    # And the downstream must actually have inherited — otherwise "upstream untouched" is trivially
    # true because nothing happened.
    nodejs_env "UPSTREAM=$UPSTREAM" "$DOWNSTREAM" "$PRE"'
console.log("inherit_events=" + (rd().events.filter((e) => e.origin === "session-inherit").length > 0) +
            " upstream=" + (rd().upstream_session_id === process.env.UPSTREAM));
'
    assert_eq "SI12/downstream-did-inherit" "inherit_events=true upstream=true" "$NODE_OUT"
fi

finish "session-inherit"

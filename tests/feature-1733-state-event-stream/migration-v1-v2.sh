#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/migration-v1-v2.sh
# Tests: hooks/workflow-state/state-io/migrations/v1-to-v2.js, hooks/workflow-state/state-io/migrations.js, hooks/workflow-state/state-io/core.js
# Tags: workflow-state, event-stream, migration, schema-version, idempotency, scope:issue-specific, pwsh-not-required, TL2
#
# In-flight sessions carry v1 state files, so the conversion is applied lazily on the
# next read. Two properties matter most: JSON key order is INSERTION order, not
# chronological order, so the converter must sort by `at` and not by iteration order;
# and a second read must be a no-op down to the bytes, otherwise every gate evaluation
# rewrites the file and the event stream grows without any workflow progress.
#
# TL3 gap (what this test does NOT catch):
# - conversion of real in-flight state files written by earlier releases; the fixtures
#   here are synthesised by mk-v1.js and cannot contain a field no one predicted.
# - hook registration: the read that triggers the lazy migration is a module call here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG="migv"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MKV1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mk-v1.js"
seed_v1() { (cd "$AGENTS_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$MKV1" "$2") > "$WF/$1.json"; }

echo "== V1: events come out in at-order even though insertion order disagrees =="
if run_case "V1/sorted-by-at"; then
    next_sid
    seed_v1 "$SID" "ordering"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const ev = st.events;
const sorted = ev.every((e, i) => i === 0 || ev[i - 1].at <= e.at);
const order = ev.filter((e) => e.kind === "step_status").map((e) => e.step).join(">");
console.log("version=" + st.version + " sorted=" + sorted + " order=" + order);
'
    # docs has updated_at:null -> at = created_at -> earliest, and at_estimated events
    # sort to the head of their `at` group.
    #
    # The trailing write_code is the v2->v3 stage (#1665): normalizeStateVersion chains
    # both stages, and this fixture settles `docs` — a step AFTER write_code — so the
    # backfill fires. It is appended with the LAST event's own `at`, which is why
    # `sorted` still holds. The v2->v3 stage owns its own cases in
    # tests/feature-1665-write-code-step/f-v2-to-v3.sh; here it is only the chain tail.
    assert_eq "V1/sorted-by-at" \
        "version=3 sorted=true order=docs>workflow_init>clarify_intent>detail>write_code" "$NODE_OUT"
fi

echo "== V2: an empty pending entry is dropped; a non-pending null-timestamp entry is backfilled =="
if run_case "V2/entry-classification"; then
    next_sid
    seed_v1 "$SID" "ordering"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const cleanupEv = st.events.filter((e) => e.step === "cleanup");
const docs = st.events.find((e) => e.kind === "step_status" && e.step === "docs");
const wi = st.events.find((e) => e.kind === "step_status" && e.step === "workflow_init");
console.log([
  "cleanup_events=" + cleanupEv.length,
  "cleanup_projects=" + st.steps.cleanup.status,
  "docs_provenance=" + docs.provenance,
  "docs_at_estimated=" + docs.at_estimated,
  "docs_at_is_created_at=" + (docs.at === st.created_at),
  "wi_provenance=" + wi.provenance,
  "wi_at_estimated=" + ("at_estimated" in wi),
].join(" "));
'
    assert_eq "V2/entry-classification" \
        "cleanup_events=0 cleanup_projects=pending docs_provenance=backfilled docs_at_estimated=true docs_at_is_created_at=true wi_provenance=observed wi_at_estimated=false" \
        "$NODE_OUT"
fi

echo "== V3: seq is renumbered 1..N after the sort =="
if run_case "V3/seq-renumbered"; then
    next_sid
    seed_v1 "$SID" "ordering"
    nodejs "$SID" "$PRE"'
const ev = S.readState(sid).events;
const bad = ev.filter((e, i) => e.seq !== i + 1).length;
console.log("n=" + (ev.length > 0) + " bad_seq=" + bad);
'
    assert_eq "V3/seq-renumbered" "n=true bad_seq=0" "$NODE_OUT"
fi

echo "== V4: timestamped top-level facts become events and leave the top level =="
if run_case "V4/toplevel-facts-converted"; then
    next_sid
    seed_v1 "$SID" "toplevel"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const kinds = st.events.reduce((a, e) => { a[e.kind] = (a[e.kind] || 0) + 1; return a; }, {});
const wt = st.events.filter((e) => e.kind === "worktree");
console.log([
  "worktree=" + (kinds.worktree || 0),
  "session_model=" + (kinds.session_model || 0),
  "complexity=" + (kinds.complexity_evaluation || 0),
  "plan_approval=" + (kinds.plan_approval || 0),
  "transitions=" + wt.map((e) => e.transition).join(","),
  "path_source=" + wt[0].path_source,
  "worktree_path=" + wt[0].worktree_path,
  "wt_provenance=" + wt[0].provenance,
].join(" "));
'
    assert_eq "V4/toplevel-facts-converted" \
        "worktree=2 session_model=1 complexity=1 plan_approval=2 transitions=entered,exited path_source=migration-unknown worktree_path=null wt_provenance=backfilled" \
        "$NODE_OUT"
fi

echo "== V5: the migrated projection restores every top-level fact =="
if run_case "V5/toplevel-facts-projected"; then
    next_sid
    seed_v1 "$SID" "toplevel"
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
console.log([
  "entered=" + st.worktree_entered_at,
  "exited=" + st.worktree_exited_at,
  "model=" + (st.session_model && st.session_model.id),
  "level=" + (st.complexity_evaluation && st.complexity_evaluation.level),
  "approvals=" + Object.keys(st.plan_approvals || {}).sort().join(","),
  "artifact_session_id=" + (st.plan_approvals.outline || {}).artifact_session_id,
  "branch=" + st.git_branch,
].join(" "));
'
    assert_eq "V5/toplevel-facts-projected" \
        "entered=2026-06-20T10:15:00.000Z exited=2026-06-20T13:15:00.000Z model=claude-opus-5 level=high approvals=detail,outline artifact_session_id=genv1 branch=feature/from-v1" \
        "$NODE_OUT"
fi

echo "== V6: git_branch/cwd move into session_start_context, not the top level =="
if run_case "V6/session-start-context"; then
    next_sid
    seed_v1 "$SID" "toplevel"
    nodejs "$SID" "$PRE"'
S.readState(sid); S.persistMigratedState(sid);
const onDisk = rd();
console.log([
  "ctx_branch=" + (onDisk.session_start_context || {}).git_branch,
  "top_git_branch=" + ("git_branch" in onDisk),
  "top_cwd=" + ("cwd" in onDisk),
  "top_is_bugfix=" + ("is_bugfix" in onDisk),
].join(" "));
'
    assert_eq "V6/session-start-context" \
        "ctx_branch=feature/from-v1 top_git_branch=false top_cwd=false top_is_bugfix=false" "$NODE_OUT"
fi

echo "== V7: version-agnostic top-level settings survive the conversion =="
if run_case "V7/settings-preserved"; then
    next_sid
    seed_v1 "$SID" "toplevel"
    nodejs "$SID" "$PRE"'
S.readState(sid); S.persistMigratedState(sid);
const onDisk = rd();
console.log("workflow_type=" + onDisk.workflow_type +
            " closes_issues=" + JSON.stringify(onDisk.closes_issues) +
            " created_at=" + onDisk.created_at);
'
    assert_eq "V7/settings-preserved" \
        "workflow_type=wf-code closes_issues=[1733] created_at=2026-06-20T09:00:00.000Z" "$NODE_OUT"
fi

echo "== V8: one readState persists the current version; the second read is byte-identical =="
if run_case "V8/lazy-persist-idempotent"; then
    next_sid
    seed_v1 "$SID" "toplevel"
    nodejs "$SID" "$PRE"'
const v1raw = raw();
S.readState(sid);
S.persistMigratedState(sid);
const first = raw();
S.readState(sid);
S.persistMigratedState(sid);
const second = raw();
console.log("changed_from_v1=" + (v1raw !== first) +
            " version=" + JSON.parse(first).version +
            " second_read_identical=" + (first === second));
'
    assert_eq "V8/lazy-persist-idempotent" "changed_from_v1=true version=3 second_read_identical=true" "$NODE_OUT"
fi

echo "== V9: migrateV1ToV2 is a pure function — two calls give identical output =="
if run_case "V9/pure-function"; then
    next_sid
    seed_v1 "$SID" "annotations"
    nodejs "$SID" "$PRE"'
const M = require("./hooks/workflow-state/state-io/migrations/v1-to-v2");
const a = JSON.stringify(M.migrateV1ToV2(JSON.parse(raw())));
const b = JSON.stringify(M.migrateV1ToV2(JSON.parse(raw())));
console.log(a === b ? "DETERMINISTIC" : "NONDETERMINISTIC");
'
    assert_eq "V9/pure-function" "DETERMINISTIC" "$NODE_OUT"
fi

echo "== V10: a v1 file still needing field backfill/rename runs both stages in order =="
if run_case "V10/field-backfill-then-v2"; then
    next_sid
    # `verify` -> `run_tests` and `plan` -> outline+detail are v1-internal renames that
    # must happen BEFORE the event conversion, or the events carry retired step names.
    nodejs "$SID" '
const fs = require("fs"), path = require("path");
const p = path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.SID + ".json");
fs.writeFileSync(p, JSON.stringify({
  version: 1, session_id: process.env.SID, created_at: "2026-06-20T09:00:00.000Z",
  workflow_type: "wf-plan",
  steps: {
    verify: { status: "complete", updated_at: "2026-06-20T10:00:00.000Z" },
    branching_decision: { status: "complete", updated_at: "2026-06-20T10:01:00.000Z" },
  },
}, null, 2));
const S = require("./hooks/workflow-state/state-io");
const st = S.readState(process.env.SID);
const steps = st.events.filter((e) => e.kind === "step_status").map((e) => e.step).sort().join(",");
console.log("version=" + st.version + " steps=" + steps + " workflow_type=" + st.workflow_type +
            " retired_present=" + /"step":"(verify|branching_decision)"/.test(JSON.stringify(st.events)));
'
    assert_eq "V10/field-backfill-then-v2" \
        "version=3 steps=branching_complete,run_tests,write_code workflow_type=wf-meta retired_present=false" "$NODE_OUT"
fi

echo "== V11: an already-current file is not re-migrated (no event churn) =="
if run_case "V11/v2-untouched"; then
    next_sid
    nodejs "$SID" "$PRE"'
S.markStep(sid, "workflow_init", "complete");
const before = raw();
for (let i = 0; i < 3; i++) { S.readState(sid); S.persistMigratedState(sid); }
console.log(before === raw() ? "UNTOUCHED" : "REWRITTEN");
'
    assert_eq "V11/v2-untouched" "UNTOUCHED" "$NODE_OUT"
fi

echo "== V12: readRawState stays byte-faithful; normalizeStateVersion is the opt-in (#1681) =="
if run_case "V12/readRawState-unchanged"; then
    next_sid
    seed_v1 "$SID" "ordering"
    nodejs "$SID" "$PRE"'
const before = raw();
const rawState = S.readRawState(sid);
const norm = S.normalizeStateVersion(rawState);
console.log("raw_version=" + rawState.version +
            " raw_has_steps=" + ("steps" in rawState) +
            " norm_version=" + norm.version +
            " norm_has_events=" + Array.isArray(norm.events) +
            " file_untouched=" + (before === raw()));
'
    assert_eq "V12/readRawState-unchanged" \
        "raw_version=1 raw_has_steps=true norm_version=3 norm_has_events=true file_untouched=true" "$NODE_OUT"
fi

echo "== V13: a corrupt state file still fails open (readState -> null, no throw) =="
if run_case "V13/corrupt-fail-open"; then
    next_sid
    printf '%s' '{ this is not json' > "$WF/$SID.json"
    nodejs "$SID" "$PRE"'
let verdict;
try { verdict = "returned=" + String(S.readState(sid)); } catch (e) { verdict = "THREW:" + e.name; }
console.log(verdict);
'
    assert_eq "V13/corrupt-fail-open" "returned=null" "$NODE_OUT"
fi

echo "== V14: a file with NO version field is v1 and migrates like one =="
if run_case "V14/unversioned-v1-migrates"; then
    next_sid
    seed_v1 "$SID" "unversioned"
    # `version` was added after the first releases, so the oldest files on any long-lived
    # installation carry no marker at all. A converter that dispatches on `version === 1`
    # passes every fixture in this file and still hands raw v1 data to a v2 reader — the
    # projection then reads an events array that does not exist.
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
S.persistMigratedState(sid);
const ss = st.events.filter((e) => e.kind === "step_status").map((e) => e.step + "=" + e.status).join(",");
const tok = st.events.find((e) => e.kind === "step_annotation" && e.key === "token");
console.log([
  "version=" + st.version,
  "steps=" + ss,
  "token=" + (tok && tok.value),
  "docs_projects=" + st.steps.docs.status,
  "no_toplevel_steps=" + !Object.prototype.hasOwnProperty.call(rd(), "steps"),
  "persisted_version=" + rd().version,
].join(" "));
'
    assert_eq "V14/unversioned-v1-migrates" \
        "version=3 steps=workflow_init=complete,research=complete token=tok-unversioned docs_projects=pending no_toplevel_steps=true persisted_version=3" \
        "$NODE_OUT"
fi

echo "== V15: entries sharing one updated_at are ordered by the tie-break, not by insertion order =="
if run_case "V15/equal-timestamp-tiebreak"; then
    next_sid
    seed_v1 "$SID" "tiebreak"
    # The fixture lists its steps in the exact REVERSE of the required order, so a sort
    # that is not stable — or that falls back on Object.keys order — reproduces the input
    # and fails here. Two sessions migrating the same file must agree on the sequence,
    # otherwise `seq` stops being a shared identifier for the same event.
    # SCOPED TO THE v1->v2 STAGE ON PURPOSE: normalizeStateVersion chains v2->v3 after
    # it, and this fixture settles run_tests, so #1665 appends one more estimated
    # step_status (write_code) at the TAIL. Judging "estimated events sort first" over
    # the whole stream would therefore measure the later stage's append position rather
    # than this stage's tie-break. The v3 tail is asserted separately below.
    nodejs "$SID" "$PRE"'
const st = S.readState(sid);
const v1ev = st.events.filter((e) => e.origin === "migration-v1-to-v2");
const seq = v1ev.map((e) => e.kind === "step_annotation" ? e.step + ":" + e.key : e.step + ":" + e.kind).join(" ");
const oneAt = new Set(v1ev.map((e) => e.at)).size;
const est = v1ev.filter((e) => e.at_estimated === true).map((e) => e.step).join(",");
const estFirst = v1ev.findIndex((e) => e.at_estimated !== true) >
                 v1ev.map((e) => e.at_estimated === true).lastIndexOf(true);
const tail = st.events[st.events.length - 1];
console.log([
  "distinct_at=" + oneAt,
  "estimated=" + est,
  "estimated_first=" + estFirst,
  "v3_tail=" + tail.step + ":" + tail.origin,
  "order=" + seq,
].join(" "));
'
    # VALID_STEPS index order within the equal-`at` group, step_status before that
    # step annotations, STEP_ANNOTATION_KEYS index (token before wsid) within a step.
    assert_eq "V15/equal-timestamp-tiebreak" \
        "distinct_at=1 estimated=clarify_intent estimated_first=true v3_tail=write_code:migration-v2-to-v3 order=clarify_intent:step_status workflow_init:step_status detail:step_status review_tests:step_status review_tests:token review_tests:wsid run_tests:step_status" \
        "$NODE_OUT"
fi

echo "== V16: the tie-break is deterministic — two migrations of one fixture agree byte-for-byte =="
if run_case "V16/tiebreak-deterministic-and-idempotent"; then
    next_sid
    SID_A16="$SID"
    seed_v1 "$SID_A16" "tiebreak"
    next_sid
    SID_B16="$SID"
    seed_v1 "$SID_B16" "tiebreak"
    nodejs_env "SID_A=$SID_A16 SID_B=$SID_B16" "$SID_A16" "$PRE"'
const a = process.env.SID_A, b = process.env.SID_B;
const load = (s) => { S.readState(s); S.persistMigratedState(s); return fs.readFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, s + ".json"), "utf8"); };
const ra = load(a), rb = load(b);
// Compare the event streams only: session_id differs by construction.
const strip = (t) => JSON.stringify(JSON.parse(t).events);
// ...and a SECOND read of an already-migrated file must not rewrite a single byte.
const again = load(a);
console.log("same_stream=" + (strip(ra) === strip(rb)) + " idempotent=" + (ra === again));
'
    assert_eq "V16/tiebreak-deterministic-and-idempotent" "same_stream=true idempotent=true" "$NODE_OUT"
fi

echo "== V17: the unversioned file is persisted at the current version and re-read unchanged =="
if run_case "V17/unversioned-persist-idempotent"; then
    next_sid
    seed_v1 "$SID" "unversioned"
    nodejs "$SID" "$PRE"'
S.readState(sid);
S.persistMigratedState(sid);
const first = raw();
for (let i = 0; i < 3; i++) { S.readState(sid); S.persistMigratedState(sid); }
const st = JSON.parse(first);
console.log("version=" + st.version + " byte_identical=" + (first === raw()) +
            " events=" + st.events.length + " no_started_at=" + (first.indexOf("started_at") === -1));
'
    assert_eq "V17/unversioned-persist-idempotent" \
        "version=3 byte_identical=true events=3 no_started_at=true" "$NODE_OUT"
fi

echo "== V18: readState never writes — only a writer brings a v1 file forward =="
if run_case "V18/read-does-not-persist"; then
    next_sid
    seed_v1 "$SID" "unversioned"
    # The workflow dir is shared by every session on the machine, and callers read
    # FOREIGN session ids out of it (context-scan.js harvests them from other
    # sessions' transcripts). A v1 file may belong to a session still running an
    # older release that cannot read v2, so a read that migrates corrupts that
    # session — it loses its top-level `steps` and every later sentinel is dropped.
    nodejs "$SID" "$PRE"'
const before = raw();
const st = S.readState(sid);
const readOnly = before === raw();
S.markStep(sid, "docs", "complete");
const after = JSON.parse(raw());
console.log("projected=" + st.steps.workflow_init.status +
            " read_left_bytes_untouched=" + readOnly +
            " writer_migrated=" + (after.version === 3) +
            " write_survived=" + (after.current.steps.docs.status === "complete"));
'
    assert_eq "V18/read-does-not-persist" \
        "projected=complete read_left_bytes_untouched=true writer_migrated=true write_survived=true" \
        "$NODE_OUT"
fi

finish "migration-v1-v2"

#!/usr/bin/env bash
# tests/feature-1733-state-event-stream/event-vocabulary.sh
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/core.js
# Tags: workflow-state, event-stream, allowlist, vocabulary, table-driven, scope:issue-specific, pwsh-not-required, TL2
#
# The two allowlists this schema stands on — EVENT_KINDS (what may enter events[]) and
# PERSISTED_TOP_LEVEL_KEYS (what may reach the file's top level) — are covered here by
# ITERATION over the exported constants, not by a hand-picked sample of members.
#
# Why iteration rather than examples: an allowlist tested by example silently loses
# coverage the moment a tenth kind or a twelfth top-level key is added. Every case below
# walks the exported array, so a new member with no table row fails the set-equality
# assertion first, and its required-field / rejection coverage follows automatically.
#
# TL3 gap (what this file does NOT catch):
# - whether real producers (markStep callers, the worktree recorder, sentinel handlers)
#   actually emit these shapes. That is the behavioural files' job; here the vocabulary
#   itself is the subject.
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh.

CASE_TAG="voc"
# shellcheck source=tests/feature-1733-state-event-stream/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# The table is deliberately written out here rather than derived from the source: a test
# that reads its expectations from the module under test asserts nothing. Each entry is
# {kind: {required extra fields with a valid value}}.
VOCAB_JS='const E = require("./hooks/workflow-state/state-io/events");
const SAMPLE = {
  step_status: { step: "research", status: "complete" },
  step_annotation: { step: "research", key: "token", value: "t1" },
  step_annotations_cleared: { step: "research" },
  worktree: { transition: "entered", git_branch: "fix/x", cwd: "/w", worktree_path: "/w", path_source: "tool_input" },
  session_model: { id: "model-fixture", source: "stop-hook" },
  complexity_evaluation: { level: "high", signals: ["many-files"] },
  plan_approval: { step: "detail", source: "confirm-sentinel", reason: "approved", artifact_sha256: "ab12", artifact_session_id: "sfix", artifact_hash_status: "match" },
  plan_approval_revoked: { step: "detail", reason: "artifact changed" },
  reset: { from_step: "detail", reason: "user asked" },
};
const KINDS = Object.keys(SAMPLE);
const mk = (kind, over) => Object.assign({ kind: kind, provenance: "observed", origin: "vocab-test" }, SAMPLE[kind] || {}, over || {});
const accepts = (ev) => { try { S.appendEvents(sid, [ev]); return true; } catch (e) { return false; } };
const rejects = (ev) => !accepts(ev);
const report = (bad) => console.log(bad.length ? "BAD " + bad.join(" | ") : "OK");
'

echo "== EV1: EVENT_KINDS is exactly the nine documented kinds, in both directions =="
if run_case "EV1/event-kinds-set-equality"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS"'
const exported = Array.from(E.EVENT_KINDS || []).slice().sort();
const table = KINDS.slice().sort();
const missing = table.filter((k) => !exported.includes(k));
const extra = exported.filter((k) => !table.includes(k));
console.log([exported.length, missing.join(",") || "-", extra.join(",") || "-"].join(" "));
'
    assert_eq "EV1/event-kinds-set-equality" "9 - -" "$NODE_OUT"
fi

echo "== EV2: every EVENT_KINDS member is accepted with its required fields present =="
if run_case "EV2/every-kind-accepted"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS"'
S.markStep(sid, "workflow_init", "complete");
const bad = KINDS.filter((k) => !accepts(mk(k))).map((k) => k + ":rejected");
// The stream must have grown by exactly one event per kind, each carrying the common
// fields. A kind accepted but dropped on the floor is the same defect as a rejection.
const evsAll = rd().events.filter((e) => e.origin === "vocab-test");
if (evsAll.length !== KINDS.length) bad.push("appended=" + evsAll.length + "/" + KINDS.length);
evsAll.forEach((e, i) => {
  if (e.seq !== i + 2) bad.push(e.kind + ":seq=" + e.seq);
  if (typeof e.at !== "string" || !/^\d{4}-\d\d-\d\dT.*Z$/.test(e.at)) bad.push(e.kind + ":at=" + e.at);
  if (e.provenance !== "observed") bad.push(e.kind + ":prov=" + e.provenance);
  if (e.origin !== "vocab-test") bad.push(e.kind + ":origin=" + e.origin);
});
report(bad);
'
    assert_eq "EV2/every-kind-accepted" "OK" "$NODE_OUT"
fi

echo "== EV3: for every kind, dropping any single required field is rejected =="
if run_case "EV3/required-fields-per-kind"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS"'
const bad = [];
KINDS.forEach((k) => {
  Object.keys(SAMPLE[k]).forEach((f) => {
    const ev = mk(k);
    delete ev[f];
    if (!rejects(ev)) bad.push(k + "." + f + ":accepted-without");
  });
  // The common fields are required of every kind too.
  ["kind", "provenance", "origin"].forEach((f) => {
    const ev = mk(k);
    delete ev[f];
    if (!rejects(ev)) bad.push(k + "." + f + ":accepted-without");
  });
});
report(bad);
'
    assert_eq "EV3/required-fields-per-kind" "OK" "$NODE_OUT"
fi

echo "== EV4: a kind outside EVENT_KINDS is rejected, whatever else it carries =="
if run_case "EV4/unknown-kind-rejected"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS"'
S.markStep(sid, "workflow_init", "complete");
const bad = [];
const impostors = ["step", "status", "step_statuses", "STEP_STATUS", "", "worktree_entered", "reset_from"];
impostors.forEach((k) => {
  const ev = Object.assign(mk("step_status"), { kind: k });
  if (!rejects(ev)) bad.push(JSON.stringify(k) + ":accepted");
});
// ...and a non-string kind.
[null, undefined, 42, {}, ["step_status"]].forEach((k, i) => {
  const ev = Object.assign(mk("step_status"), { kind: k });
  if (!rejects(ev)) bad.push("nonstring" + i + ":accepted");
});
if (rd().events.length !== 1) bad.push("stream-grew=" + rd().events.length);
report(bad);
'
    assert_eq "EV4/unknown-kind-rejected" "OK" "$NODE_OUT"
fi

echo "== EV5: PROVENANCE_VALUES is the full domain and is enforced on every kind =="
if run_case "EV5/provenance-domain"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS"'
const bad = [];
const exported = Array.from(E.PROVENANCE_VALUES || []).slice().sort();
const want = ["backfilled", "declared", "observed"];
if (exported.join(",") !== want.join(",")) bad.push("PROVENANCE_VALUES=" + exported.join(","));
KINDS.forEach((k) => {
  want.forEach((p) => { if (!accepts(mk(k, { provenance: p }))) bad.push(k + "/" + p + ":rejected"); });
  ["observed ", "OBSERVED", "synthetic", "", "guessed", null, 3].forEach((p, i) => {
    if (!rejects(mk(k, { provenance: p }))) bad.push(k + "/bad" + i + ":accepted");
  });
});
report(bad);
'
    assert_eq "EV5/provenance-domain" "OK" "$NODE_OUT"
fi

echo "== EV6: step_status.status accepts the four workflow statuses and nothing else =="
if run_case "EV6/status-domain"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS$APPROVE_GATED_JS"'
const bad = [];
["pending", "in_progress", "complete", "skipped"].forEach((st) => {
  if (!accepts(mk("step_status", { status: st }))) bad.push(st + ":rejected");
});
["done", "completed", "COMPLETE", "in-progress", "skip", "", null, 1].forEach((st, i) => {
  if (!rejects(mk("step_status", { status: st }))) bad.push("bad" + i + "(" + String(st) + "):accepted");
});
// The step name is an allowlist of its own: VALID_STEPS. outline/detail are
// approval-gated (#1133): APPROVE_GATED_JS seeded a plan_approval for both above, so
// their "complete" transition below satisfies the completion-approval precondition
// the same way every other kind-vocabulary assertion in this file does.
const C = require("./hooks/workflow-state/state-io/core");
(C.VALID_STEPS || []).forEach((s) => {
  if (!accepts(mk("step_status", { step: s }))) bad.push("step:" + s + ":rejected");
});
["not_a_step", "Research", "", null].forEach((s, i) => {
  if (!rejects(mk("step_status", { step: s }))) bad.push("badstep" + i + ":accepted");
});
report(bad);
'
    assert_eq "EV6/status-domain" "OK" "$NODE_OUT"
fi

echo "== EV7: worktree.transition and path_source have closed vocabularies =="
if run_case "EV7/transition-and-path-source-domain"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS"'
const bad = [];
["entered", "exited"].forEach((t) => {
  if (!accepts(mk("worktree", { transition: t }))) bad.push("transition:" + t + ":rejected");
});
["enter", "exit", "ENTERED", "moved", "", null].forEach((t, i) => {
  if (!rejects(mk("worktree", { transition: t }))) bad.push("badtransition" + i + ":accepted");
});
["tool_input", "fallback-process-cwd", "prior-entry", "migration-unknown"].forEach((p) => {
  if (!accepts(mk("worktree", { path_source: p }))) bad.push("path_source:" + p + ":rejected");
});
["toolinput", "cwd", "", null].forEach((p, i) => {
  if (!rejects(mk("worktree", { path_source: p }))) bad.push("badsource" + i + ":accepted");
});
report(bad);
'
    assert_eq "EV7/transition-and-path-source-domain" "OK" "$NODE_OUT"
fi

echo "== EV8: STEP_ANNOTATION_KEYS is the known-key table — known keys pass, unknown keys are kept (warn, never drop) =="
if run_case "EV8/annotation-keys"; then
    next_sid
    nodejs "$SID" "$PRE$VOCAB_JS"'
const bad = [];
const want = ["invalidate_reason", "reset_reason", "skip_judgment", "skip_reason", "skip_verdict",
  "token", "warnings_accepted_reason", "warnings_summary", "wsid"];
const exported = Array.from(E.STEP_ANNOTATION_KEYS || []).slice().sort();
if (exported.join(",") !== want.join(",")) bad.push("STEP_ANNOTATION_KEYS=" + exported.join(","));
want.forEach((k) => {
  if (!accepts(mk("step_annotation", { key: k, value: "v" }))) bad.push("known:" + k + ":rejected");
  if (!accepts(mk("step_annotation", { key: k, value: null }))) bad.push("known:" + k + ":null-rejected");
});
// Rejecting an unfamiliar annotation key would make every future field vanish silently;
// the design keeps them (validateEvent may warn, must not throw).
["future_field", "some_new_key"].forEach((k) => {
  if (!accepts(mk("step_annotation", { key: k, value: { a: 1 } }))) bad.push("unknown:" + k + ":rejected");
});
const kept = rd().events.filter((e) => e.kind === "step_annotation" && e.key === "future_field");
if (kept.length !== 1 || JSON.stringify(kept[0].value) !== JSON.stringify({ a: 1 })) bad.push("unknown-key-not-stored-verbatim");
report(bad);
'
    assert_eq "EV8/annotation-keys" "OK" "$NODE_OUT"
fi

echo "== EV9: PERSISTED_TOP_LEVEL_KEYS is exactly the eleven documented keys =="
if run_case "EV9/persisted-keys-set-equality"; then
    next_sid
    nodejs "$SID" "$PRE"'
const P = require("./hooks/workflow-state/state-io/projection");
const want = ["closes_issues", "created_at", "current", "events", "last_pushed_sha",
  "session_id", "session_start_context", "session_worktree", "verbose_prompt",
  "version", "workflow_type"].sort();
const got = Array.from(P.PERSISTED_TOP_LEVEL_KEYS || []).slice().sort();
console.log(got.length + " " + (got.join(",") === want.join(",") ? "MATCH" : "GOT:" + got.join(",")));
'
    assert_eq "EV9/persisted-keys-set-equality" "11 MATCH" "$NODE_OUT"
fi

echo "== EV10: every PERSISTED_TOP_LEVEL_KEYS member survives a write/read round trip =="
if run_case "EV10/persisted-keys-round-trip"; then
    next_sid
    nodejs "$SID" "$PRE"'
const P = require("./hooks/workflow-state/state-io/projection");
const bad = [];
// Caller-set keys, one per updateTopLevel call so a failure names the key.
const WRITABLE = {
  workflow_type: "wf-code",
  closes_issues: [1733],
  last_pushed_sha: "0123456789abcdef0123456789abcdef01234567",
  session_worktree: { path: "/w", branch: "fix/x" },
  verbose_prompt: true,
  session_start_context: { cwd: "/w", git_branch: "main" },
};
Object.keys(WRITABLE).forEach((k) => {
  try { S.updateTopLevel(sid, (st) => { st[k] = WRITABLE[k]; }); }
  catch (e) { bad.push(k + ":write-threw:" + e.name); }
});
const disk = rd();
Object.keys(WRITABLE).forEach((k) => {
  if (JSON.stringify(disk[k]) !== JSON.stringify(WRITABLE[k])) bad.push(k + ":ondisk=" + JSON.stringify(disk[k]));
});
// Managed keys: written by the state layer itself, never by a caller.
["version", "session_id", "created_at", "events", "current"].forEach((k) => {
  if (disk[k] === undefined) bad.push(k + ":absent");
});
// Nothing outside the allowlist reached the file.
const allow = Array.from(P.PERSISTED_TOP_LEVEL_KEYS || []);
const stray = Object.keys(disk).filter((k) => !allow.includes(k));
if (stray.length) bad.push("stray=" + stray.join(","));
console.log(bad.length ? "BAD " + bad.join(" | ") : "OK");
'
    assert_eq "EV10/persisted-keys-round-trip" "OK" "$NODE_OUT"
fi

echo "== EV11: a top-level key outside the allowlist is refused with UnknownStateKeyError =="
if run_case "EV11/unknown-top-level-key"; then
    next_sid
    nodejs "$SID" "$PRE"'
// Bootstrap: the state file for a fresh sid does not exist yet, and raw() reads it
// with no fail-open — a no-op updateTopLevel materialises it before before=raw() is
// captured, so the refused writes below are compared against a real "no-op" baseline
// instead of crashing on ENOENT.
S.updateTopLevel(sid, () => {});
const bad = [];
const before = raw();
["bogus_key", "steps_v3", "started_at", "updated_at", "notes"].forEach((k) => {
  let name = "NO-THROW";
  try { S.updateTopLevel(sid, (st) => { st[k] = "x"; }); }
  catch (e) { name = e.name; }
  if (name !== "UnknownStateKeyError") bad.push(k + ":" + name);
});
// A refused write must not have written anything.
if (raw() !== before) bad.push("file-changed-after-refusal");
console.log(bad.length ? "BAD " + bad.join(" | ") : "OK");
'
    assert_eq "EV11/unknown-top-level-key" "OK" "$NODE_OUT"
fi

echo "== EV12: every PROJECTION_KEYS member is structurally impossible at the top level =="
if run_case "EV12/projection-keys-never-persisted"; then
    next_sid
    nodejs "$SID" "$PRE"'
const P = require("./hooks/workflow-state/state-io/projection");
const bad = [];
const want = ["complexity_evaluation", "cwd", "git_branch", "is_bugfix", "plan_approvals",
  "session_model", "skip_judgment", "steps", "worktree_entered_at", "worktree_exited_at"].sort();
const got = Array.from(P.PROJECTION_KEYS || []).slice().sort();
if (got.join(",") !== want.join(",")) bad.push("PROJECTION_KEYS=" + got.join(","));
S.markStep(sid, "research", "complete");
// Setting a projection key at the top level is not an error — it is simply stripped,
// because the projection is rebuilt from events on every read. What must never happen
// is the value landing on disk, where a `jq .steps` consumer would treat it as truth.
got.forEach((k) => {
  try { S.updateTopLevel(sid, (st) => { st[k] = "forged-" + k; }); } catch (e) { /* stripped or refused: both fine */ }
  if (Object.prototype.hasOwnProperty.call(rd(), k)) bad.push(k + ":persisted");
});
// ...and the projection still reports the real value, not the forgery.
const st = S.readState(sid);
if (!st.current || !st.current.steps || st.current.steps.research.status !== "complete") bad.push("projection-corrupted");
console.log(bad.length ? "BAD " + bad.join(" | ") : "OK");
'
    assert_eq "EV12/projection-keys-never-persisted" "OK" "$NODE_OUT"
fi

feature_banner
finish "event-vocabulary"

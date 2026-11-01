#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/progress-file.js, hooks/progress-nudge/evaluate.js
// Tags: TL2, hooks, progress-nudge, progress-pressure, idle, no-op-write, regression, regression-2748, scope:common, progress-file, sidecar, root-sid, donor-chain
// #2594 (A): updatePressure skips the sidecar write when every patch value JSON-equals the current
// record, still returning out.result; a differing or new key writes the merged record.
// #2594 (B): an idle evaluation (no new complete, no transcript growth, session-progress.md untouched)
// changes no value of progress-pressure.json, so both updatePressure phases skip the write and
// the file keeps its bytes and its (backdated) mtime. A call with a real change still writes.
// TL3 gap (what this test does NOT catch):
// - the hook registration in settings.json firing under a real Claude Code host (evaluate is called in-process)
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "pn-idle-write-"));
const T = path.join(TMP, "t");
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [T, CFG, TRANSCRIPTS]) fs.mkdirSync(d);
// markStep reads the approval gates from $AGENTS_MAIN_ROOT/.env, never process.env.
fs.writeFileSync(path.join(CFG, ".env"), "CONFIRM_OUTLINE=off\nCONFIRM_DETAIL=off\n");
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
after(() => {
  process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const S = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const PF = require(path.join(ROOT, "hooks", "lib", "progress-file"));
const { sidecarPath } = require(path.join(ROOT, "hooks", "lib", "control-sidecar"));
const { evaluate } = require(path.join(ROOT, "hooks", "progress-nudge", "evaluate"));

let passed = 0;
let failed = 0;
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
const failures = () => failed;

const transcriptOf = (sid) => path.join(T, `${sid}.jsonl`);
const fileOf = (sid) => sidecarPath(sid, PF.PRESSURE_SUFFIX);
const run = (sid, event, tool) => evaluate({ sid, event, tool, transcriptPath: transcriptOf(sid), now: Date.now() });

// settled(sid) — a session whose pressure record has absorbed every change: the steps so far are
// delivered, the baseline sits at the transcript size and session-progress.md has been seen.
function settled(sid) {
  S.writeState(sid, S.createInitialState(sid, { cwd: "/x", git_branch: "feature/x" }));
  S.markStep(sid, "workflow_init", "complete");
  fs.writeFileSync(transcriptOf(sid), Buffer.alloc(10 * 1024, 120));
  for (let i = 0; i < 3; i++) run(sid, "PostToolUse", "Bash");
}
// backdate(sid) -> {bytes, mtimeMs} of the pressure file after its mtime is set an hour back.
function backdate(sid) {
  const at = new Date(Math.floor((Date.now() - 60 * 60 * 1000) / 1000) * 1000);
  fs.utimesSync(fileOf(sid), at, at);
  return snap(sid);
}
function snap(sid) {
  const f = fileOf(sid);
  return { bytes: fs.readFileSync(f, "utf8"), mtimeMs: fs.statSync(f).mtimeMs };
}
function unchanged(sid, before) {
  const after = snap(sid);
  eq(after.mtimeMs, before.mtimeMs, "file rewritten: mtimeMs");
  eq(after.bytes, before.bytes, "file rewritten: bytes");
}
function rewritten(sid, before) {
  if (snap(sid).mtimeMs === before.mtimeMs) throw new Error(`not rewritten: mtimeMs still ${before.mtimeMs}`);
}
// seed(sid, record) -> {bytes, mtimeMs} of a pressure file holding record, mtime set an hour back.
function seed(sid, record) {
  if (!PF.mergePressure(sid, record)) throw new Error(`fixture: pressure write failed for ${sid}`);
  return backdate(sid);
}
const tmpLeftovers = (sid) => fs.readdirSync(path.dirname(fileOf(sid))).filter((n) => n.endsWith(".tmp"));

const ISO_A = "2026-10-18T00:00:00.000Z";
const ISO_B = "2026-10-18T00:30:00.000Z";
const BASE_RECORD = { root_sid: "pn-root", progress_path: "/fixture/p.md", event_cursor: 3, requests_at: [ISO_A, ISO_B] };

caseBegin("all-equal-patch-skips-write", "hooks/lib/progress-file.js");
test("all-equal-patch-skips-write", () => noNewFailures(failures, () => {
  const sid = "pnw-equal";
  const before = seed(sid, BASE_RECORD);
  const r = PF.updatePressure(sid, () => ({ patch: { root_sid: "pn-root", progress_path: "/fixture/p.md", event_cursor: 3 }, result: "R1" }));
  check("A1: an all-equal patch still returns out.result", () => eq(r, "R1", "result"));
  check("A1: an all-equal patch leaves the pressure file unrewritten (bytes and mtime)", () => unchanged(sid, before));
  check("A1: no tmp file is left in the sidecar dir", () => eq(tmpLeftovers(sid), [], "tmp files"));
}));
caseEnd();

caseBegin("changed-value-patch-writes", "hooks/lib/progress-file.js");
test("changed-value-patch-writes", () => noNewFailures(failures, () => {
  const sid = "pnw-changed";
  const before = seed(sid, BASE_RECORD);
  const r = PF.updatePressure(sid, () => ({ patch: { root_sid: "pn-root", event_cursor: 4 }, result: "R2" }));
  check("A2: a patch with one changed value returns out.result", () => eq(r, "R2", "result"));
  check("A2: that patch rewrites the pressure file", () => rewritten(sid, before));
  check("A2: the changed key is updated and the others are kept", () => eq(PF.readPressure(sid), Object.assign({}, BASE_RECORD, { event_cursor: 4 }), "record"));
}));
caseEnd();

caseBegin("new-key-patch-writes", "hooks/lib/progress-file.js");
test("new-key-patch-writes", () => noNewFailures(failures, () => {
  const sid = "pnw-newkey";
  const before = seed(sid, BASE_RECORD);
  const r = PF.updatePressure(sid, () => ({ patch: { root_sid: "pn-root", last_request_at: ISO_B }, result: "R3" }));
  check("A3: a patch adding a new key returns out.result", () => eq(r, "R3", "result"));
  check("A3: that patch rewrites the pressure file", () => rewritten(sid, before));
  check("A3: the new key is added and the existing keys are kept", () => eq(PF.readPressure(sid), Object.assign({}, BASE_RECORD, { last_request_at: ISO_B }), "record"));
}));
caseEnd();

caseBegin("content-equal-array-skips-write", "hooks/lib/progress-file.js");
test("content-equal-array-skips-write", () => noNewFailures(failures, () => {
  const sid = "pnw-array";
  const before = seed(sid, BASE_RECORD);
  const fresh = [ISO_A, ISO_B].map((s) => new Date(s).toISOString());
  const r = PF.updatePressure(sid, (cur) => {
    if (cur.requests_at === fresh) throw new Error("fixture: the patch array must be a fresh object");
    return { patch: { requests_at: fresh }, result: "R4" };
  });
  check("A4: a content-equal fresh array returns out.result", () => eq(r, "R4", "result"));
  check("A4: a content-equal fresh array leaves the pressure file unrewritten (bytes and mtime)", () => unchanged(sid, before));
}));
caseEnd();

caseBegin("empty-patch-skips-write", "hooks/lib/progress-file.js");
test("empty-patch-skips-write", () => noNewFailures(failures, () => {
  const sid = "pnw-empty";
  const before = seed(sid, BASE_RECORD);
  const r = PF.updatePressure(sid, () => ({ patch: {}, result: "R5" }));
  check("A5: an empty patch returns out.result", () => eq(r, "R5", "result"));
  check("A5: an empty patch leaves the pressure file unrewritten (bytes and mtime)", () => unchanged(sid, before));
}));
caseEnd();

caseBegin("null-fn-result-skips-write", "hooks/lib/progress-file.js");
test("null-fn-result-skips-write", () => noNewFailures(failures, () => {
  const sid = "pnw-null";
  const before = seed(sid, BASE_RECORD);
  const r = PF.updatePressure(sid, () => null);
  check("A6: fn returning null makes updatePressure return null", () => eq(r, null, "result"));
  check("A6: fn returning null leaves the pressure file unrewritten (bytes and mtime)", () => unchanged(sid, before));
}));
caseEnd();

caseBegin("idle-read-call-leaves-pressure-unwritten", "hooks/progress-nudge/evaluate.js");
test("idle-read-call-leaves-pressure-unwritten", () => noNewFailures(failures, () => {
  const sid = "pni-read";
  settled(sid);
  run(sid, "PostToolUse", "Read");
  const before = backdate(sid);
  const ctx = run(sid, "PostToolUse", "Read");
  check("B1: an idle Read evaluation delivers no request", () => eq(ctx, null, "evaluate"));
  check("B1: an idle Read evaluation leaves the pressure file unrewritten (bytes and mtime)", () => unchanged(sid, before));
}));
caseEnd();

caseBegin("idle-bash-call-leaves-pressure-unwritten", "hooks/progress-nudge/evaluate.js");
test("idle-bash-call-leaves-pressure-unwritten", () => noNewFailures(failures, () => {
  const sid = "pni-bash";
  settled(sid);
  const before = backdate(sid);
  const ctx = run(sid, "PostToolUse", "Bash");
  check("B2: an idle Bash evaluation delivers no request", () => eq(ctx, null, "evaluate"));
  check("B2: an idle Bash evaluation leaves the pressure file unrewritten (bytes and mtime)", () => unchanged(sid, before));
}));
caseEnd();

caseBegin("new-complete-still-writes-pressure", "hooks/lib/progress-file.js");
test("new-complete-still-writes-pressure", () => noNewFailures(failures, () => {
  const sid = "pni-change";
  settled(sid);
  const cursorBefore = (PF.readPressure(sid) || {}).event_cursor;
  S.markStep(sid, "research", "complete");
  const before = backdate(sid);
  const ctx = run(sid, "PostToolUse", "Bash");
  const after = PF.readPressure(sid) || {};
  check("B3: a Bash evaluation after a new complete asks for an update naming it", () => (typeof ctx === "string" && ctx.includes("step complete: research") ? undefined : `ctx=${show(ctx)}`));
  check("B3: that evaluation rewrites the pressure file", () => (snap(sid).mtimeMs !== before.mtimeMs ? undefined : `mtimeMs still ${before.mtimeMs}`));
  check("B3: the event cursor advanced past the new complete", () => (typeof after.event_cursor === "number" && after.event_cursor > cursorBefore ? undefined : `before=${show(cursorBefore)} after=${show(after.event_cursor)}`));
}));
caseEnd();

// #2748: session chains come from the real applyInheritance; the cycle and cap cases use pre-#2311 legacy
// states (raw upstream_session_id only), the one shape that still needs a walk.
const APPLY = require(path.join(ROOT, "hooks", "workflow-state", "inheritance", "apply"));
const CTX = { cwd: "/x", git_branch: "feature/x" };
// firstGen(sid) — a first generation: no session chain keys.
function firstGen(sid) {
  S.writeState(sid, S.createInitialState(sid, CTX));
}
// adopt(sid, up) — sid adopts up through the real applyInheritance.
function adopt(sid, up) {
  firstGen(sid);
  const createdAt = JSON.parse(fs.readFileSync(S.getStatePath(sid), "utf8")).created_at;
  const res = APPLY.applyInheritance(sid, createdAt, up);
  if (!res || res.ok === false) throw new Error(`fixture: applyInheritance(${sid}, ${up}) failed: ${show(res)}`);
}
// legacy(sid, up) — a pre-#2311 raw state carrying upstream_session_id only.
function legacy(sid, up) {
  const st = S.createInitialState(sid, CTX);
  delete st.previous_session_ids;
  delete st.first_session_id;
  st.upstream_session_id = up;
  fs.writeFileSync(S.getStatePath(sid), JSON.stringify(st, null, 2));
}
// realChain / legacyChain(prefix, n) -> sids g1..gn, each g(k>1) a session-downstream of g(k-1),
// none with a saved root_sid.
function realChain(prefix, n) {
  const sids = [];
  for (let i = 1; i <= n; i++) {
    const sid = `${prefix}-g${i}`;
    if (i === 1) firstGen(sid);
    else adopt(sid, sids[i - 2]);
    sids.push(sid);
  }
  return sids;
}
function legacyChain(prefix, n) {
  const sids = [];
  for (let i = 1; i <= n; i++) {
    const sid = `${prefix}-g${i}`;
    if (i === 1) firstGen(sid);
    else legacy(sid, sids[i - 2]);
    sids.push(sid);
  }
  return sids;
}

caseBegin("long-donor-chain-resolves-to-first-generation", "hooks/lib/progress-file.js");
test("long-donor-chain-resolves-to-first-generation", () => noNewFailures(failures, () => {
  const sids = realChain("prc-long", 11);
  check("E1: the fixture saved no root_sid anywhere in the chain", () => eq(sids.filter((s) => PF.readPressure(s)), [], "sids with a pressure record"));
  check("E1: an 11-generation donor chain resolves to its first generation", () => eq(PF.resolveRootSid(sids[10]), sids[0], "root sid"));
  check("E1: a 9-generation tail of the same chain still resolves to the first generation", () => eq(PF.resolveRootSid(sids[8]), sids[0], "root sid"));
}));
caseEnd();

// expectOneRoot(label, sids, want) — every sid resolves to want and shares one progress file, so a
// cycle can never split one history across files depending on which member asks.
function expectOneRoot(label, sids, want) {
  const roots = sids.map((s) => PF.resolveRootSid(s));
  sids.forEach((s, i) => check(`${label}: ${s} resolves to ${want}`, () => eq(roots[i], want, "root sid")));
  check(`${label}: every member resolves to one identical sid`, () => (new Set(roots).size === 1 ? undefined : `roots=${show(roots)}`));
  const paths = sids.map((s) => PF.progressPathFor(s));
  check(`${label}: every member shares one progress file path`, () => (new Set(paths).size === 1 && typeof paths[0] === "string" ? undefined : `paths=${show(paths)}`));
}

caseBegin("donor-cycle-terminates", "hooks/lib/progress-file.js");
test("donor-cycle-terminates", () => noNewFailures(failures, () => {
  // Created out of sorted order so neither creation order nor the asking member picks the root.
  const b = "prc-cyc-b";
  const c = "prc-cyc-c";
  const a = "prc-cyc-a";
  legacy(b, a);
  legacy(c, b);
  legacy(a, c);
  check("E2: the cycle fixture saved no root_sid", () => eq([a, b, c].filter((s) => PF.readPressure(s)), [], "sids with a pressure record"));
  expectOneRoot("E2 cycle a->c->b->a", [b, c, a], a);

  // A tail leading into a cycle: z0 -> m1 -> a2 -> m1. The cycle's smallest member is a2.
  const z0 = "prc-tail-z0";
  const m1 = "prc-tail-m1";
  const a2 = "prc-tail-a2";
  legacy(m1, a2);
  legacy(a2, m1);
  legacy(z0, m1);
  expectOneRoot("E2 tail z0->m1->a2->m1", [z0, m1, a2], a2);

  const self = "prc-cyc-self";
  legacy(self, self);
  check("E2: a session naming itself as donor resolves to itself", () => eq(PF.resolveRootSid(self), self, "root sid"));

  // A saved root_sid on any member still wins over the cycle's smallest member.
  const sx = "prc-sav-x";
  const sy = "prc-sav-y";
  const saved = "prc-sav-root";
  legacy(sx, sy);
  legacy(sy, sx);
  check("E2: the saved-root fixture wrote its root_sid", () => eq(PF.mergePressure(sy, { root_sid: saved }), true, "mergePressure"));
  expectOneRoot("E2 saved root on a cycle member", [sx, sy], saved);
}));
caseEnd();

// countStateReads(fn) -> {result, reads}: the donor walk reads one workflow state per hop, so the
// readState count during one resolveRootSid call is the number of hops it took.
function countStateReads(fn) {
  const orig = S.readState;
  let reads = 0;
  S.readState = function (...args) { reads += 1; return orig.apply(this, args); };
  try {
    return { result: fn(), reads };
  } finally {
    S.readState = orig;
  }
}

caseBegin("over-long-donor-chain-walk-is-bounded", "hooks/lib/progress-file.js");
test("over-long-donor-chain-walk-is-bounded", () => noNewFailures(failures, () => {
  const sids = legacyChain("prc-cap", 200);
  const first = countStateReads(() => PF.resolveRootSid(sids[199]));
  const second = PF.resolveRootSid(sids[199]);
  check("F1: a 200-generation legacy chain resolves to a valid sid", () => (PF.isValidSid(first.result) ? undefined : `root=${show(first.result)}`));
  check("F1: resolving the same sid twice gives the same root", () => eq(second, first.result, "root sid"));
  check("F1: the legacy walk stops after a bounded number of hops (<= 128 state reads, not 200)", () => (first.reads <= 128 ? undefined : `state reads=${first.reads}`));
  // #2748: the capped walk writes no pin back (pinCapRoot is gone), so only the newest sid's own
  // answer is pinned down here: a sid of this chain, short of the true root g1.
  check("F1: the capped answer is an older sid of this chain, short of the true root", () => (sids.includes(first.result) && first.result !== sids[0]
    && first.result !== sids[199] ? undefined : `root=${show(first.result)}`));
}));
caseEnd();

caseBegin("two-member-cycle-stays-deterministic", "hooks/lib/progress-file.js");
test("two-member-cycle-stays-deterministic", () => noNewFailures(failures, () => {
  const a = "prc-cap-cyc-a";
  const b = "prc-cap-cyc-b";
  legacy(a, b);
  legacy(b, a);
  const ra = countStateReads(() => PF.resolveRootSid(a));
  check("F2: an A->B->A cycle terminates within a few state reads", () => (ra.reads <= 4 ? undefined : `state reads=${ra.reads}`));
  check("F2: both members and a repeated call agree on one root", () => eq([PF.resolveRootSid(b), PF.resolveRootSid(a)], [ra.result, ra.result], "roots"));
}));
caseEnd();

caseBegin("short-donor-chain-still-reaches-root", "hooks/lib/progress-file.js");
test("short-donor-chain-still-reaches-root", () => noNewFailures(failures, () => {
  const sids = realChain("prc-short", 3);
  check("F3: a 3-generation chain resolves to its first generation", () => eq(PF.resolveRootSid(sids[2]), sids[0], "root sid"));
}));
caseEnd();

// templated(sid) -> {file, ref}: the progress file ensureProgressFile creates, and its full text.
function templated(sid) {
  firstGen(sid);
  const r = PF.ensureProgressFile(sid);
  if (!r.path || !r.created) throw new Error(`fixture: ensureProgressFile did not create a file for ${sid}: ${show(r)}`);
  return { file: r.path, ref: fs.readFileSync(r.path, "utf8") };
}
// Recovery rule asserted below: restore the template only over a 0-byte regular file; any non-empty
// file — even a strict byte-prefix of the template, which may be a model edit — is kept byte-identical.

caseBegin("empty-progress-file-gets-the-template", "hooks/lib/progress-file.js");
test("empty-progress-file-gets-the-template", () => noNewFailures(failures, () => {
  const { file, ref } = templated("pef-empty");
  fs.writeFileSync(file, "");
  const r = PF.ensureProgressFile("pef-empty");
  check("G1: a 0-byte progress file yields its path, created", () => eq([r.path, r.created], [file, true], "result"));
  check("G1: a 0-byte progress file is restored to the full template", () => eq(fs.readFileSync(file, "utf8"), ref, "content"));
}));
caseEnd();

// prefixKept(sid, label, cut) — a non-empty strict byte-prefix of the template (cut(len) bytes) is
// left as written: ensureProgressFile reports it not created and keeps its bytes.
function prefixKept(sid, label, cut) {
  const { file, ref } = templated(sid);
  const refBuf = Buffer.from(ref, "utf8");
  const partial = Buffer.from(refBuf.subarray(0, cut(refBuf.length)));
  check(`${label}: the fixture is a non-empty strict byte-prefix of the template`, () => (partial.length > 0 && partial.length < refBuf.length && refBuf.subarray(0, partial.length).equals(partial) ? undefined : `partial=${partial.length} ref=${refBuf.length}`));
  fs.writeFileSync(file, partial);
  const r = PF.ensureProgressFile(sid);
  check(`${label}: a non-empty template prefix yields its path, not created`, () => eq([r.path, r.created], [file, false], "result"));
  check(`${label}: that file is left byte-identical (not restored)`, () => (fs.readFileSync(file).equals(partial) ? undefined : "content changed"));
}

caseBegin("partial-progress-file-is-kept", "hooks/lib/progress-file.js");
test("partial-progress-file-is-kept", () => noNewFailures(failures, () => prefixKept("pef-partial", "G2", (n) => Math.floor(n / 2))));
caseEnd();

caseBegin("one-byte-prefix-progress-file-is-kept", "hooks/lib/progress-file.js");
test("one-byte-prefix-progress-file-is-kept", () => noNewFailures(failures, () => prefixKept("pef-onebyte", "G7", () => 1)));
caseEnd();

caseBegin("complete-progress-file-with-user-content-is-kept", "hooks/lib/progress-file.js");
test("complete-progress-file-with-user-content-is-kept", () => noNewFailures(failures, () => {
  const { file, ref } = templated("pef-full");
  const written = `${ref}\n## Notes\nuser-written-line pef-full\n`;
  fs.writeFileSync(file, written);
  const r = PF.ensureProgressFile("pef-full");
  check("G3: a complete file with appended user content yields its path, not created", () => eq([r.path, r.created], [file, false], "result"));
  check("G3: that file is left byte-identical", () => eq(fs.readFileSync(file, "utf8"), written, "content"));
}));
caseEnd();

caseBegin("model-filled-progress-file-is-kept", "hooks/lib/progress-file.js");
test("model-filled-progress-file-is-kept", () => noNewFailures(failures, () => {
  const { file, ref } = templated("pef-short");
  // The model's edit: every "(...)" placeholder line of the template becomes a short filled-in line.
  const refLines = ref.split("\n");
  const headings = refLines.filter((l) => /^#+ /.test(l));
  const placeholders = refLines.filter((l) => /^\(.*\)$/.test(l));
  const written = refLines.map((l) => (/^\(.*\)$/.test(l) ? (l.startsWith("(In a few lines") ? "Editing G5 of pef-short; next: run the suite." : "- none") : l)).join("\n");
  const writtenLines = written.split("\n");
  check("G5: the fixture keeps every template heading and fills every placeholder", () => (headings.length > 0 && placeholders.length > 0 && headings.every((h) => writtenLines.includes(h)) && !writtenLines.some((l) => /^\(.*\)$/.test(l)) ? undefined : `headings=${headings.length} placeholders=${placeholders.length}`));
  check("G5: the fixture is shorter than the template and not a byte-prefix of it", () => (Buffer.byteLength(written) < Buffer.byteLength(ref) && !Buffer.from(ref, "utf8").subarray(0, Buffer.byteLength(written)).equals(Buffer.from(written, "utf8")) ? undefined : "fixture is a prefix or not shorter"));
  fs.writeFileSync(file, written);
  const r = PF.ensureProgressFile("pef-short");
  check("G5: a model-filled file yields its path, not created", () => eq([r.path, r.created], [file, false], "result"));
  check("G5: that file is left byte-identical", () => eq(fs.readFileSync(file, "utf8"), written, "content"));
}));
caseEnd();

caseBegin("exact-template-progress-file-is-kept", "hooks/lib/progress-file.js");
test("exact-template-progress-file-is-kept", () => noNewFailures(failures, () => {
  const { file, ref } = templated("pef-exact");
  const before = fs.readFileSync(file);
  const r = PF.ensureProgressFile("pef-exact");
  check("G6: a file equal to the full template yields its path, not created", () => eq([r.path, r.created], [file, false], "result"));
  check("G6: that file is left byte-identical to the template", () => (fs.readFileSync(file).equals(before) && before.toString("utf8") === ref ? undefined : "content changed"));
}));
caseEnd();

caseBegin("symlinked-progress-file-is-refused", "hooks/lib/progress-file.js");
test("symlinked-progress-file-is-refused", (t) => noNewFailures(failures, () => {
  const sid = "pef-link";
  firstGen(sid);
  const file = PF.progressPathFor(sid);
  const outside = path.join(TMP, "outside-target.md");
  fs.writeFileSync(outside, "outside-content\n");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let linked = true;
  try { fs.symlinkSync(outside, file, "file"); } catch (_) { linked = false; }
  if (!linked) {
    t.skip("G4: this host cannot create a file symlink (no privilege); the lstat refusal is unexercised here");
    return;
  } else {
    const r = PF.ensureProgressFile(sid);
    check("G4: a symlink at the progress path yields no path", () => eq(r.path, null, "path"));
    check("G4: the symlink target is left untouched", () => eq(fs.readFileSync(outside, "utf8"), "outside-content\n", "target content"));
  }
}));
caseEnd();

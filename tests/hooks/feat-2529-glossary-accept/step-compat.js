"use strict";
// #2820 part of tests/hooks/feat-2529-glossary-accept.js: the step= discriminator is canonical,
// the legacy stage= discriminator and a legacy { stage } record still grant through the compat
// layer. Holds no case markers; the entrypoint wraps each run function in one.

const REASON = "user accepted this spelling";
const RS_BODY = "\"use strict\";\n// Mid-line the glossary-drift appears.\nmodule.exports = 1;\n";
const INTENT_GOAL = "Mid-line the glossary-drift appears in the goal.";

const grantsOf = (F, sid, step) => { const r = F.recordOf(sid, step); return (r && Array.isArray(r.grants)) ? r.grants : []; };
const oneFinding = (rec) => !!rec && Array.isArray(rec.findings) && rec.findings.length === 1;
const noStageKey = (rec) => !!rec && !("stage" in rec);

// A session at write_code with one recorded review_tests finding (staged tests/t.js). → { repo, sid, rec }
function reviewTests(F, tag) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.seedAt(sid, "write_code", repo);
  F.stageFile(repo, "tests/t.js", RS_BODY);
  const d = F.drift(sid, "review_tests", repo, true);
  const rec = F.recordOf(sid, "review_tests");
  F.check(`#2820 [${tag}] precondition: --step review_tests --record wrote one finding in a { step } record`,
    F.reached(d) && oneFinding(rec) && rec.step === "review_tests" && noStageKey(rec), `code=${d.code} ${JSON.stringify(rec)} ${d.all}`);
  return { repo, sid, rec };
}

// A session at clarify_intent whose intent.md carries one variant, recorded. → { repo, sid, rec }
function clarifyIntent(F, tag) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid, { goal: INTENT_GOAL });
  F.seedAt(sid, "clarify_intent", repo);
  const d = F.drift(sid, "clarify_intent", repo, true);
  const rec = F.recordOf(sid, "clarify_intent");
  F.check(`#2820 [${tag}] precondition: --step clarify_intent --record wrote one finding`,
    F.reached(d) && oneFinding(rec) && rec.step === "clarify_intent", `code=${d.code} ${JSON.stringify(rec)} ${d.all}`);
  return { repo, sid, rec };
}

const sameGrant = (g, s) => g.length === 1 && !!s.rec && g[0].fingerprint === s.rec.fingerprint &&
  g[0].reason === REASON && typeof g[0].norm === "string" && g[0].norm !== "";
const shapeOf = (g) => JSON.stringify(g.map((x) => ({ norm: x.norm, reason: x.reason })));

// step=review_tests is accepted; legacy stage=tests gives the same grant on the review_tests record.
function discriminator(F) {
  const a = reviewTests(F, "step-rt");
  const ra = F.mark(a.sid, F.accepted(F.TERM, "step=review_tests", REASON), a.repo);
  const ga = grantsOf(F, a.sid, "review_tests");
  F.check("#2820 step=review_tests: one grant { norm, fingerprint: the record's, reason }", sameGrant(ga, a), `${JSON.stringify(ga)} ${ra.all}`);
  F.check("#2820 step=review_tests: the record stays { step: review_tests } with no stage key",
    noStageKey(F.recordOf(a.sid, "review_tests")) && F.recordOf(a.sid, "review_tests").step === "review_tests",
    JSON.stringify(F.recordOf(a.sid, "review_tests")));

  const b = reviewTests(F, "stage-tests");
  const rb = F.mark(b.sid, F.accepted(F.TERM, "stage=tests", REASON), b.repo);
  const gb = grantsOf(F, b.sid, "review_tests");
  F.check("#2820 compat stage=tests: one grant on the review_tests record", sameGrant(gb, b), `${JSON.stringify(gb)} ${rb.all}`);
  F.check("#2820 compat stage=tests: the grant equals the step=review_tests grant (norm, reason)",
    ga.length === 1 && gb.length === 1 && shapeOf(ga) === shapeOf(gb), `${shapeOf(ga)} vs ${shapeOf(gb)}`);
  F.check("#2820 compat stage=tests: the record is written as { step: review_tests } with no stage key",
    noStageKey(F.recordOf(b.sid, "review_tests")) && F.recordOf(b.sid, "review_tests").step === "review_tests",
    JSON.stringify(F.recordOf(b.sid, "review_tests")));

  const c = reviewTests(F, "step-op");
  F.expectRejected("#2820 step=review_tests combined with op=add (with an open finding to grant)", c.sid,
    F.accepted(F.TERM, "step=review_tests op=add", REASON), c.repo, /malformed/i);
  F.expectRejected("#2820 compat stage=tests combined with cat=user (with an open finding to grant)", c.sid,
    F.accepted(F.TERM, "stage=tests cat=user", REASON), c.repo, /malformed/i);
}

function lastRawRecord(F, sid, step) {
  const raw = F.rawState(sid);
  const events = raw ? JSON.parse(raw).events : [];
  const hit = events.filter((e) => e.kind === "step_annotation" && e.step === step && e.key === "glossary_check").pop();
  return hit ? hit.value : null;
}

// A record written before #2820 ({ v, stage: "tests", ... }) is granted and rewritten as { step }.
function legacyRecord(F) {
  for (const ids of ["step=review_tests", "stage=tests", ""]) {
    const s = reviewTests(F, `legacy-rec-${ids.replace(/\W+/g, "") || "none"}`);
    if (!s.rec) continue;
    const legacy = Object.assign({ v: 1, stage: F.LEGACY_STAGE_OF.review_tests }, s.rec);
    delete legacy.step;
    F.inject(s.sid, "review_tests", "glossary_check", legacy);
    // Read the raw stream: a read-side normalization must not hide that the seeded record is legacy.
    const seeded = lastRawRecord(F, s.sid, "review_tests");
    F.check(`#2820 legacy record [${ids || "no discriminator"}] precondition: the seeded record is { stage: tests } with no step`,
      !!seeded && seeded.stage === "tests" && !("step" in seeded), JSON.stringify(seeded));
    const r = F.mark(s.sid, F.accepted(F.TERM, ids, REASON), s.repo);
    const rec = lastRawRecord(F, s.sid, "review_tests");
    F.check(`#2820 legacy record [${ids || "no discriminator"}]: granted against the record's fingerprint`,
      sameGrant(grantsOf(F, s.sid, "review_tests"), s), `${JSON.stringify(rec)} ${r.all}`);
    F.check(`#2820 legacy record [${ids || "no discriminator"}]: rewritten as { step: review_tests } with no stage key`,
      !!rec && rec.step === "review_tests" && noStageKey(rec) && rec.fingerprint === s.rec.fingerprint, JSON.stringify(rec));
  }
}

// clarify_intent is a glossary step the sentinel can name; legacy stage=intent maps onto it.
function clarify(F) {
  const a = clarifyIntent(F, "step-ci");
  const ra = F.mark(a.sid, F.accepted(F.TERM, "step=clarify_intent", REASON), a.repo);
  F.check("#2820 step=clarify_intent: one grant on the clarify_intent record",
    sameGrant(grantsOf(F, a.sid, "clarify_intent"), a), `${JSON.stringify(F.recordOf(a.sid, "clarify_intent"))} ${ra.all}`);

  const b = clarifyIntent(F, "stage-intent");
  const rb = F.mark(b.sid, F.accepted(F.TERM, "stage=intent", REASON), b.repo);
  F.check("#2820 compat stage=intent: one grant on the clarify_intent record",
    sameGrant(grantsOf(F, b.sid, "clarify_intent"), b), `${JSON.stringify(F.recordOf(b.sid, "clarify_intent"))} ${rb.all}`);

  const c = clarifyIntent(F, "step-ci-ng");
  F.expectRejected("#2820 step=review_docs while only clarify_intent holds the finding", c.sid,
    F.accepted(F.TERM, "step=review_docs", REASON), c.repo, /step=review_docs has no open finding/);
}

module.exports = { discriminator, legacyRecord, clarify };

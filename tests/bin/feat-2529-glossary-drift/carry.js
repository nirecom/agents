"use strict";
// #2770 grant carry-over: a re-record moves a grant to the new fingerprint only when the artifact
// (since #2909 also the rules) changed and the granted norm's variant set did not grow or change.
// The same rule holds for the provenance record (ops in the artifact's role, blocked as the set).

const RECORD = "hooks/workflow-state/glossary-check/record.js";
const SRC = "src/a.js";
const BODY = "\"use strict\";\n// a mid-line glossary-drift comment\nmodule.exports = 1;\n";

// A review_security step with one granted finding (variant glossary-drift in a new staged file).
function granted(F, tag) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.stageFile(repo, SRC, BODY);
  F.seedAt(sid, "review_security", repo);
  const r = F.drift(sid, "review_security", repo, true);
  F.check(`${tag} precondition: --record exits 1 with a finding`, F.reached(r) && r.code === 1, `code=${r.code} ${r.all}`);
  const m = F.mark(sid, F.accepted(F.TERM, "step=review_security"), repo);
  const rec = F.recordOf(sid, "review_security");
  F.check(`${tag} precondition: one grant on the record fingerprint`,
    !!rec && (rec.grants || []).length === 1 && rec.grants[0].fingerprint === rec.fingerprint, `${JSON.stringify(rec)} ${m.all}`);
  return { repo, sid, rec };
}

function evaluate(F, s) {
  const R = F.mod(RECORD);
  return R ? R.evaluateGlossaryCheck(s.sid, "review_security", F.readState(s.sid), { repoDir: s.repo }) : null;
}

// Re-records and reports { r, rec, carried } where carried counts grants on the new fingerprint.
function rerecord(F, s) {
  const r = F.drift(s.sid, "review_security", s.repo, true);
  const rec = F.recordOf(s.sid, "review_security") || {};
  const carried = (rec.grants || []).filter((g) => g.norm && g.fingerprint === rec.fingerprint).length;
  return { r, rec, carried, all: `code=${r.code} ${JSON.stringify(rec)} ${r.all}` };
}

function expectDropped(F, name, s) {
  const x = rerecord(F, s);
  F.check(`${name}: exit 1 and the grant is not carried`,
    x.r.code === 1 && x.rec.fingerprint !== s.rec.fingerprint && (x.rec.grants || []).length === 0, x.all);
}

function artifactOnly(F) {
  const s = granted(F, "carry-art");
  F.stageFile(s.repo, SRC, `${BODY}module.exports.b = 2;\n`);
  const x = rerecord(F, s);
  const variants = (rec) => JSON.stringify([...new Set((rec.findings || []).map((f) => f.variant))].sort());
  F.check("artifact-only change: the re-record still detects the same variant set as before",
    (x.rec.findings || []).length > 0 && variants(x.rec) === variants(s.rec), x.all);
  F.check("artifact-only change with the same variants: exit 0, the grant moves to the new fingerprint",
    x.r.code === 0 && x.rec.fingerprint !== s.rec.fingerprint && x.carried === 1 && x.rec.grants.length === 1, x.all);
  const v = evaluate(F, s);
  F.check("artifact-only change with the same variants: evaluateGlossaryCheck passes", !!v && v.ok === true, JSON.stringify(v));
  F.stageFile(s.repo, SRC, `${BODY}module.exports.b = 2;\nmodule.exports.c = 3;\n`);
  const y = rerecord(F, s);
  F.check("a second artifact-only re-record still holds exactly one grant",
    y.r.code === 0 && y.carried === 1 && y.rec.grants.length === 1, y.all);
}

// #2962: a glossary-only change carries the grant unless a matching field of its term moved.
function glossaryOnly(F) {
  const d = granted(F, "carry-def");
  F.touchDefinition(d.repo);
  const x = rerecord(F, d);
  F.check("a glossary Definition-only change: exit 0, the grant moves to the new fingerprint (#2962)",
    x.r.code === 0 && x.rec.fingerprint !== d.rec.fingerprint && x.carried === 1 && x.rec.grants.length === 1, x.all);
  F.check("a glossary Definition-only change: the re-record keeps term_fields for the granted norm",
    !!x.rec.term_fields && typeof x.rec.term_fields[F.TERM] === "string", x.all);
  const v = evaluate(F, d);
  F.check("a glossary Definition-only change: evaluateGlossaryCheck passes after the re-record", !!v && v.ok === true, JSON.stringify(v));
}

function notCarried(F) {
  const g = granted(F, "carry-fields");
  F.touchMatch(g.repo);
  const x = rerecord(F, g);
  F.check("a glossary matching-field change: exit 1, the grant lapses with the fields cause",
    x.r.code === 1 && (x.rec.grants || []).length === 0 && /EXPIRED: grant for "glossary drift" — its `Identifier` \/ `Short forms` \/ heading changed;/.test(x.r.all),
    x.all);

  const v = granted(F, "carry-var");
  F.stageFile(v.repo, SRC, `${BODY}// and the glossarydrift spelling\n`);
  expectDropped(F, "an artifact change adding a new variant of the granted term", v);

  const i = granted(F, "carry-int");
  F.writeIntent(i.sid, { rows: [[F.TERM, "user", "add", "A spelling that differs from the glossary term."],
    ["release gate", "user", "add", "A fixture gate."]] });
  expectDropped(F, "an intent glossary row change", i);
}

// checkRecordEvents / provenanceRecordEvents directly: the rules component cannot be moved from a fixture repo.
function unit(F) {
  const R = F.mod(RECORD);
  if (!R) return;
  const I = { artifact: F.FP("1"), glossary: F.FP("2"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const find = (variant, line) => ({ term: F.TERM, norm: F.TERM, variant, where: `${SRC}:${line}` });
  const prev = { fingerprint: F.FP("a"), inputs: I, findings: [find("glossary-drift", 2)],
    grants: [{ norm: F.TERM, fingerprint: F.FP("a"), reason: "fixture" }], ledger_grants: [] };
  const valueOf = (evs) => (evs && evs[0] && (evs[0].value || evs[0])) || {};
  const at = (over) => ({ fingerprint: F.FP("b"), inputs: Object.assign({}, I, over) });
  const a = valueOf(R.checkRecordEvents(prev, "review_security", at({ artifact: F.FP("9") }), [find("glossary-drift", 3)]));
  F.check("checkRecordEvents: artifact-only change, same variants: the grant moves to the new fingerprint",
    (a.grants || []).length === 1 && a.grants[0].fingerprint === F.FP("b") && a.grants[0].norm === F.TERM, JSON.stringify(a));
  const r = valueOf(R.checkRecordEvents(prev, "review_security", at({ rules: F.FP("9") }), [find("glossary-drift", 2)]));
  F.check("checkRecordEvents: rules-only change, same variants: the grant moves to the new fingerprint (#2909)",
    (r.grants || []).length === 1 && r.grants[0].fingerprint === F.FP("b") && r.grants[0].norm === F.TERM, JSON.stringify(r));
  const g = valueOf(R.checkRecordEvents(prev, "review_security", at({ artifact: F.FP("9") }),
    [find("glossary-drift", 2), find("glossarydrift", 4)]));
  F.check("checkRecordEvents: artifact-only change adding a variant: the grant is not carried",
    (g.grants || []).length === 0, JSON.stringify(g));
  const ag = valueOf(R.checkRecordEvents(prev, "review_security", at({ artifact: F.FP("9"), glossary: F.FP("8") }),
    [find("glossary-drift", 3)]));
  F.check("checkRecordEvents: artifact and glossary both change, same variants: the grant is not carried",
    (ag.grants || []).length === 0, JSON.stringify(ag));

  const P = { ops: F.FP("5"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const blocked = [{ term: "beta", norm: "beta", operation: "add", category: "user", reason: "not-in-intent" }];
  const pprev = { fingerprint: F.FP("c"), inputs: P, blocked,
    grants: [{ norm: "beta", operation: "add", category: "user", fingerprint: F.FP("c"), reason: "fixture" }] };
  const pat = (over) => ({ fingerprint: F.FP("d"), inputs: Object.assign({}, P, over) });
  const po = valueOf(R.provenanceRecordEvents(pprev, pat({ ops: F.FP("8") }), "explicit", blocked));
  F.check("provenanceRecordEvents: ops-only change, same blocked set: the grant moves to the new fingerprint",
    (po.grants || []).length === 1 && po.grants[0].fingerprint === F.FP("d"), JSON.stringify(po));
  const pr = valueOf(R.provenanceRecordEvents(pprev, pat({ rules: F.FP("8") }), "explicit", blocked));
  F.check("provenanceRecordEvents: rules-only change, same blocked set: the grant moves to the new fingerprint (#2909)",
    (pr.grants || []).length === 1 && pr.grants[0].fingerprint === F.FP("d"), JSON.stringify(pr));
  const more = blocked.concat([{ term: "beta", norm: "beta", operation: "add", category: "internal", reason: "not-in-intent" }]);
  const pb = valueOf(R.provenanceRecordEvents(pprev, pat({ ops: F.FP("8") }), "explicit", more));
  F.check("provenanceRecordEvents: ops-only change with a grown blocked set: the grant is not carried",
    (pb.grants || []).length === 0, JSON.stringify(pb));
  const pi = valueOf(R.provenanceRecordEvents(pprev, pat({ ops: F.FP("8"), intent_rows: F.FP("7") }), "explicit", blocked));
  F.check("provenanceRecordEvents: ops and intent_rows both change, same blocked set: the grant is not carried",
    (pi.grants || []).length === 0, JSON.stringify(pi));
}

// #2962 checkRecordEvents directly: a glossary-only change carries the grant only when the granted
// norm's entry fingerprint (term_fields) is the same; the record stores term_fields for its
// findings' and grants' norms; an old record (no term_fields) never carries over a glossary change.
function unitFields(F) {
  const R = F.mod(RECORD);
  if (!R) return;
  const I = { artifact: F.FP("1"), glossary: F.FP("2"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const find = (variant) => ({ term: F.TERM, norm: F.TERM, variant, where: `${SRC}:2` });
  const TF = { [F.TERM]: F.FP("e") };
  const prev = { fingerprint: F.FP("a"), inputs: I, findings: [find("glossary-drift")], term_fields: TF,
    grants: [{ norm: F.TERM, fingerprint: F.FP("a"), reason: "fixture" }], ledger_grants: [] };
  const valueOf = (evs) => (evs && evs[0] && (evs[0].value || evs[0])) || {};
  const at = (over, termFields) => ({ fingerprint: F.FP("b"), inputs: Object.assign({}, I, over), termFields });
  const kept = (v) => (v.grants || []).length === 1 && v.grants[0].fingerprint === F.FP("b") && v.grants[0].norm === F.TERM;

  const same = valueOf(R.checkRecordEvents(prev, "review_security", at({ glossary: F.FP("8") }, TF), [find("glossary-drift")]));
  F.check("checkRecordEvents: glossary-only change, same term_fields: the grant moves to the new fingerprint", kept(same), JSON.stringify(same));
  F.check("checkRecordEvents: the written record stores term_fields for the finding's norm",
    !!same.term_fields && same.term_fields[F.TERM] === F.FP("e"), JSON.stringify(same));

  const moved = valueOf(R.checkRecordEvents(prev, "review_security", at({ glossary: F.FP("8") }, { [F.TERM]: F.FP("f") }), [find("glossary-drift")]));
  F.check("checkRecordEvents: glossary-only change, the granted norm's term_fields moved: the grant is not carried",
    (moved.grants || []).length === 0 && moved.term_fields && moved.term_fields[F.TERM] === F.FP("f"), JSON.stringify(moved));

  const old = Object.assign({}, prev);
  delete old.term_fields;
  const legacy = valueOf(R.checkRecordEvents(old, "review_security", at({ glossary: F.FP("8") }, TF), [find("glossary-drift")]));
  F.check("checkRecordEvents: glossary-only change on an old record without term_fields: the grant is not carried (fail-safe)",
    (legacy.grants || []).length === 0, JSON.stringify(legacy));

  const both = valueOf(R.checkRecordEvents(prev, "review_security", at({ glossary: F.FP("8"), rules: F.FP("9") }, TF), [find("glossary-drift")]));
  F.check("checkRecordEvents: glossary and rules both change, same term_fields: the grant is not carried",
    (both.grants || []).length === 0, JSON.stringify(both));
  const ag = valueOf(R.checkRecordEvents(prev, "review_security", at({ glossary: F.FP("8"), artifact: F.FP("9") }, TF), [find("glossary-drift")]));
  F.check("checkRecordEvents: glossary and artifact both change, same term_fields: the grant is not carried",
    (ag.grants || []).length === 0, JSON.stringify(ag));
}

function run(F) {
  artifactOnly(F);
  glossaryOnly(F);
  unitFields(F);
  notCarried(F);
  unit(F);
}

module.exports = { run };

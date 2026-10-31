"use strict";
// #2770 grant carry-over: a re-record moves a grant to the new fingerprint only when the artifact
// is the one component that changed and the granted norm's variant set did not grow or change.
// The same rule holds for the provenance record (ops in the artifact's role, blocked as the set).

const RECORD = "hooks/workflow-state/glossary-check/record.js";
const SRC = "src/a.js";
const BODY = "\"use strict\";\n// a mid-line glossary-drift comment\nmodule.exports = 1;\n";

// A code stage with one granted finding (variant glossary-drift in a new staged file).
function granted(F, tag) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.stageFile(repo, SRC, BODY);
  F.seedAt(sid, "review_security", repo);
  const r = F.drift(sid, "code", repo, true);
  F.check(`${tag} precondition: --record exits 1 with a finding`, F.reached(r) && r.code === 1, `code=${r.code} ${r.all}`);
  const m = F.mark(sid, F.accepted(F.TERM, "stage=code"), repo);
  const rec = F.recordOf(sid, "code");
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
  const r = F.drift(s.sid, "code", s.repo, true);
  const rec = F.recordOf(s.sid, "code") || {};
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

function notCarried(F) {
  const g = granted(F, "carry-glo");
  F.writeFile(g.repo, "docs/glossary/user.md", F.GLOSSARY_FILES["docs/glossary/user.md"].replace("differs from", "deviates from"));
  expectDropped(F, "a glossary definition change", g);

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
  const a = valueOf(R.checkRecordEvents(prev, "code", at({ artifact: F.FP("9") }), [find("glossary-drift", 3)]));
  F.check("checkRecordEvents: artifact-only change, same variants: the grant moves to the new fingerprint",
    (a.grants || []).length === 1 && a.grants[0].fingerprint === F.FP("b") && a.grants[0].norm === F.TERM, JSON.stringify(a));
  const r = valueOf(R.checkRecordEvents(prev, "code", at({ rules: F.FP("9") }), [find("glossary-drift", 2)]));
  F.check("checkRecordEvents: rules-only change: the grant is not carried", (r.grants || []).length === 0, JSON.stringify(r));
  const g = valueOf(R.checkRecordEvents(prev, "code", at({ artifact: F.FP("9") }),
    [find("glossary-drift", 2), find("glossarydrift", 4)]));
  F.check("checkRecordEvents: artifact-only change adding a variant: the grant is not carried",
    (g.grants || []).length === 0, JSON.stringify(g));
  const ag = valueOf(R.checkRecordEvents(prev, "code", at({ artifact: F.FP("9"), glossary: F.FP("8") }),
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
  F.check("provenanceRecordEvents: rules-only change: the grant is not carried", (pr.grants || []).length === 0, JSON.stringify(pr));
  const more = blocked.concat([{ term: "beta", norm: "beta", operation: "add", category: "internal", reason: "not-in-intent" }]);
  const pb = valueOf(R.provenanceRecordEvents(pprev, pat({ ops: F.FP("8") }), "explicit", more));
  F.check("provenanceRecordEvents: ops-only change with a grown blocked set: the grant is not carried",
    (pb.grants || []).length === 0, JSON.stringify(pb));
  const pi = valueOf(R.provenanceRecordEvents(pprev, pat({ ops: F.FP("8"), intent_rows: F.FP("7") }), "explicit", blocked));
  F.check("provenanceRecordEvents: ops and intent_rows both change, same blocked set: the grant is not carried",
    (pi.grants || []).length === 0, JSON.stringify(pi));
}

function run(F) {
  artifactOnly(F);
  notCarried(F);
  unit(F);
}

module.exports = { run };

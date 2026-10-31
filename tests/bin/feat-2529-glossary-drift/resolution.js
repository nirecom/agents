"use strict";
// T5-3 part of tests/bin/feat-2529-glossary-drift.js (#2529). Holds no case markers; the
// entrypoint wraps run() in one.
// A finding is resolved only by fixing the artifact or by a grant bound to the record's own
// fingerprint: a glossary or intent-row entry alone leaves it open, a grant on another
// fingerprint is neither counted nor carried, an artifact change drops the grants but keeps the
// ledger_grants, and the record shape has no "resolved" field.

const RECORD_KEYS = ["findings", "fingerprint", "grants", "inputs", "ledger_grants", "stage", "v"];
const INPUT_KEYS = ["artifact", "glossary", "intent_rows", "rules"];
const FINDING_KEYS = ["class", "norm", "source", "term", "variant", "where"];
const keys = (o) => Object.keys(o || {}).sort().join(",");
const plan = (extra) => `# Outline\n\n## Approach\n\nMid-line the glossary-drift appears.\n${extra || ""}`;

function shape(F, rec) {
  F.check("T5-3 record: top-level keys are exactly v/stage/fingerprint/inputs/findings/grants/ledger_grants",
    keys(rec) === RECORD_KEYS.join(","), keys(rec));
  if (!rec) return;
  F.check("T5-3 record: v=1, stage=outline, fingerprint is a non-empty string",
    rec.v === 1 && rec.stage === "outline" && typeof rec.fingerprint === "string" && rec.fingerprint !== "", JSON.stringify(rec));
  F.check("T5-3 record: inputs has exactly artifact/glossary/intent_rows/rules", keys(rec.inputs) === INPUT_KEYS.join(","), keys(rec.inputs));
  const fs = Array.isArray(rec.findings) ? rec.findings : [];
  F.check("T5-3 record: one finding for the variant", fs.length === 1, JSON.stringify(rec.findings));
  F.check("T5-3 record: every finding has exactly source/class/term/norm/variant/where (no resolved field)",
    fs.length > 0 && fs.every((f) => keys(f) === FINDING_KEYS.join(",")), JSON.stringify(fs));
  F.check("T5-3 record: finding is deterministic/spelling for glossary-drift -> glossary drift",
    fs.length > 0 && fs[0].source === "deterministic" && fs[0].class === "spelling" &&
    fs[0].variant === "glossary-drift" && fs[0].term === F.TERM, JSON.stringify(fs));
  F.check("T5-3 record: grants and ledger_grants start empty",
    Array.isArray(rec.grants) && rec.grants.length === 0 && Array.isArray(rec.ledger_grants) && rec.ledger_grants.length === 0,
    JSON.stringify(rec));
}

function run(F) {
  const repo = F.mkRepo("res");
  const sid = F.newSid("res");
  // The term is in the user glossary file and in the intent glossary rows.
  F.writeIntent(sid);
  F.writePlan(sid, "outline", plan());
  F.seedAt(sid, "outline", repo);

  const r1 = F.drift(sid, "outline", repo, false);
  F.check("T5-3 term in both glossaries: the variant is still DRIFT and exit 1",
    F.reached(r1) && r1.code === 1 && F.driftLines(r1.all).length === 1, `code=${r1.code} ${r1.all}`);
  F.check("T5-3 without --record: no glossary_check is written", F.reached(r1) && F.recordOf(sid, "outline") === null,
    JSON.stringify(F.recordOf(sid, "outline")));
  F.check("T5-3 DRIFT output names the narrow echo form term=<term> stage=outline",
    /WORKFLOW_GLOSSARY_ACCEPTED: term=\S.* stage=outline/.test(r1.all), r1.all);

  const r2 = F.drift(sid, "outline", repo, true);
  F.check("T5-3 --record with an open finding exits 1", F.reached(r2) && r2.code === 1, `code=${r2.code} ${r2.all}`);
  const rec = F.recordOf(sid, "outline");
  shape(F, rec);
  const norm = rec && rec.findings && rec.findings[0] ? rec.findings[0].norm : F.TERM;
  const fp = rec ? rec.fingerprint : "absent";

  // A grant bound to another fingerprint is not counted and not carried.
  F.inject(sid, "outline", "glossary_check", Object.assign({}, rec, {
    grants: [{ norm, fingerprint: "0".repeat(64), reason: "foreign fingerprint" }],
  }));
  const r3 = F.drift(sid, "outline", repo, true);
  const rec3 = F.recordOf(sid, "outline");
  F.check("T5-3 grant on a foreign fingerprint: still exit 1 with DRIFT",
    F.reached(r3) && r3.code === 1 && F.driftLines(r3.all).length === 1, `code=${r3.code} ${r3.all}`);
  F.check("T5-3 grant on a foreign fingerprint: dropped by --record", !!rec3 && Array.isArray(rec3.grants) && rec3.grants.length === 0,
    JSON.stringify(rec3));

  // A grant on the record's own fingerprint resolves it; ledger_grants ride along.
  F.inject(sid, "outline", "glossary_check", Object.assign({}, rec3 || rec, {
    grants: [{ norm, fingerprint: fp, reason: "user accepted" }],
    ledger_grants: [{ norm, discrim: "d9", reason: "user accepted" }],
  }));
  const r4 = F.drift(sid, "outline", repo, true);
  const rec4 = F.recordOf(sid, "outline");
  F.check("T5-3 grant on the same fingerprint: --record exits 0 with no DRIFT",
    F.reached(r4) && r4.code === 0 && F.driftLines(r4.all).length === 0, `code=${r4.code} ${r4.all}`);
  F.check("T5-3 grant on the same fingerprint: carried by --record (fingerprint unchanged)",
    !!rec4 && rec4.fingerprint === fp && Array.isArray(rec4.grants) && rec4.grants.length === 1 && rec4.grants[0].fingerprint === fp,
    JSON.stringify(rec4));

  // An artifact change that adds a new variant of the granted term: the grant lapses, the finding reopens.
  F.writePlan(sid, "outline", plan("\nOne more sentence with the Glossary Drift.\n"));
  const r5 = F.drift(sid, "outline", repo, true);
  const rec5 = F.recordOf(sid, "outline");
  F.check("T5-3 artifact changed: exit 1 with the same DRIFT again",
    F.reached(r5) && r5.code === 1 && F.driftLines(r5.all).some((d) => d.variant === "glossary-drift"), `code=${r5.code} ${r5.all}`);
  F.check("T5-3 artifact changed: new fingerprint, grants not carried, finding open again",
    !!rec5 && rec5.fingerprint !== fp && Array.isArray(rec5.grants) && rec5.grants.length === 0 &&
    Array.isArray(rec5.findings) && rec5.findings.some((f) => f.norm === norm), JSON.stringify(rec5));
  F.check("T5-3 artifact changed: ledger_grants carried unchanged",
    F.reached(r5) && !!rec5 && typeof rec5.fingerprint === "string" && rec5.fingerprint !== fp &&
    Array.isArray(rec5.ledger_grants) && rec5.ledger_grants.length === 1 && rec5.ledger_grants[0].discrim === "d9",
    JSON.stringify(rec5 && rec5.ledger_grants));

  // Fixing the artifact is the other resolution.
  F.writePlan(sid, "outline", "# Outline\n\n## Approach\n\nMid-line the glossary drift appears.\n");
  const r6 = F.drift(sid, "outline", repo, true);
  const rec6 = F.recordOf(sid, "outline");
  F.check("T5-3 variant removed: --record exits 0 with no DRIFT and no findings",
    F.reached(r6) && r6.code === 0 && F.driftLines(r6.all).length === 0 && !!rec6 && Array.isArray(rec6.findings) &&
    rec6.findings.length === 0, `code=${r6.code} ${r6.all} ${JSON.stringify(rec6)}`);
}

module.exports = { run };

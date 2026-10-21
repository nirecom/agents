"use strict";
// T4-2 part of tests/hooks/feat-2529-glossary-accept.js (#2529), target (c) tagged ledger
// concerns and the bin/check-glossary-ledger-grant CLI. Holds no case markers; the entrypoint
// wraps each run function in one.

const fs = require("node:fs");
const REASON = "user accepted this spelling";
const TAGGED_PAIR = (F) => [
  { id: "C1", discrim: "d1", text: F.tagged(F.TERM) },
  { id: "C2", discrim: "d2", text: F.tagged("Glossary-Drift", "second spelling of the same term") },
];

// A repo + session sitting at `step`, no glossary_check record, with `rows` in the stage's ledger.
function atStep(F, tag, step, format, rows) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.seedAt(sid, step, repo);
  if (format && rows) F.writeLedger(sid, format, rows);
  return { repo, sid };
}
const lgrants = (F, sid, stage) => { const r = F.recordOf(sid, stage); return (r && Array.isArray(r.ledger_grants)) ? r.ledger_grants : []; };

// Granted at every ledger stage; the record has no fingerprint and the stage stays incomplete.
function grants(F) {
  const R = F.mod("hooks/workflow-state/glossary-check/record.js");
  const out = {};
  for (const [stage, format] of Object.entries(F.LEDGER_FORMAT)) {
    const s = atStep(F, `lg-${stage}`, F.STAGE_STEP[stage], format, TAGGED_PAIR(F));
    const r = F.mark(s.sid, F.accepted("glossary drifts", "", REASON), s.repo);
    const rec = F.recordOf(s.sid, stage);
    const g = lgrants(F, s.sid, stage);
    F.check(`T4-2 (c) ${stage}/${format}: one term-level sentinel grants both tagged concerns (d1, d2)`,
      g.map((x) => x.discrim).sort().join(",") === "d1,d2" && g.every((x) => x.reason === REASON && typeof x.norm === "string" && x.norm !== ""),
      `${JSON.stringify(rec)} ${r.all}`);
    F.check(`T4-2 (c) ${stage}: the new record is { v: 1, stage, ledger_grants } with no fingerprint`,
      !!rec && rec.v === 1 && rec.stage === stage && !("fingerprint" in rec), JSON.stringify(rec));
    const ev = R && typeof R.evaluateGlossaryCheck === "function"
      ? R.evaluateGlossaryCheck(s.sid, F.STAGE_STEP[stage], F.readState(s.sid), { repoDir: s.repo }) : null;
    F.check(`T4-2 (c) ${stage}: evaluateGlossaryCheck stays glossary-check-missing`,
      !!ev && ev.ok === false && ev.code === "glossary-check-missing", JSON.stringify(ev));
    out[stage] = Object.assign({ norm: g[0] ? g[0].norm : F.TERM }, s);
  }
  return out;
}

// Nothing pending in the ledger → rejected; a reopened concern is pending.
function pending(F) {
  const cases = [
    ["untagged concern naming the term", [{ id: "C1", discrim: "d1", text: "glossary-drift is spelled differently" }]],
    ["tagged concern already rejected", [{ id: "C1", state: "rejected", discrim: "d1", text: F.tagged(F.TERM) }]],
    ["tagged concern already resolved", [{ id: "C1", state: "resolved", discrim: "d1", text: F.tagged(F.TERM) }]],
    ["tagged concern for another term", [{ id: "C1", discrim: "d1", text: F.tagged(F.TERM2) }]],
    ["no ledger file", null],
  ];
  for (const [label, rows] of cases) {
    const s = atStep(F, "lp", "detail", "detail-plan", rows);
    F.expectRejected(`T4-2 (c) detail: ${label}`, s.sid, F.accepted(F.TERM, "", REASON), s.repo);
  }
  const s = atStep(F, "lp-re", "detail", "detail-plan", [{ id: "C1", state: "reopened", discrim: "d7", text: F.tagged(F.TERM) }]);
  F.mark(s.sid, F.accepted(F.TERM, "", REASON), s.repo);
  F.check("T4-2 (c) detail: a reopened tagged concern is granted",
    lgrants(F, s.sid, "detail").map((x) => x.discrim).join(",") === "d7", JSON.stringify(F.recordOf(s.sid, "detail")));

  for (const [stage, step] of [["intent", "clarify_intent"], ["docs", "review_docs"]]) {
    const t = atStep(F, `lp-${stage}`, step, null, null);
    for (const format of Object.values(F.LEDGER_FORMAT)) F.writeLedger(t.sid, format, TAGGED_PAIR(F));
    F.expectRejected(`T4-2 (c) ${stage} stage has no ledger: tagged concerns elsewhere are not granted`,
      t.sid, F.accepted(F.TERM, "", REASON), t.repo);
  }
}

// list-drift cannot read the ledger → (c) adds nothing (fail-closed); (a) and (b) are unaffected.
function failClosed(F) {
  const u = atStep(F, "lf-c", "detail", null, null);
  fs.mkdirSync(F.ledgerPath(u.sid, "detail-plan"), { recursive: true });
  F.expectRejected("T4-2 (c) unreadable ledger (a directory): nothing granted", u.sid, F.accepted(F.TERM, "", REASON), u.repo);

  const a = atStep(F, "lf-a", "outline", null, null);
  F.writePlan(a.sid, "outline", "# Outline\n\n## Approach\n\nMid-line the glossary-drift appears.\n");
  F.drift(a.sid, "outline", a.repo, true);
  fs.mkdirSync(F.ledgerPath(a.sid, "outline-plan"), { recursive: true });
  F.mark(a.sid, F.accepted(F.TERM, "", REASON), a.repo);
  const ra = F.recordOf(a.sid, "outline");
  F.check("T4-2 (c) unreadable ledger: the (a) grant is still recorded and no ledger_grants are added",
    !!ra && Array.isArray(ra.grants) && ra.grants.length === 1 && lgrants(F, a.sid, "outline").length === 0, JSON.stringify(ra));

  const b = atStep(F, "lf-b", "detail", null, null);
  fs.mkdirSync(F.ledgerPath(b.sid, "detail-plan"), { recursive: true });
  F.inject(b.sid, "review_docs", "glossary_provenance", F.provenanceRecord(F.FP("e"),
    [{ term: F.TERM, operation: "add", category: "user", reason: "unmatched" }]));
  F.mark(b.sid, F.accepted(F.TERM, "", REASON), b.repo);
  const p = F.ann(b.sid, "review_docs", "glossary_provenance");
  F.check("T4-2 (c) unreadable ledger: the (b) grant is still recorded",
    !!p && Array.isArray(p.grants) && p.grants.length === 1 && p.grants[0].fingerprint === F.FP("e"), JSON.stringify(p));
  F.check("T4-2 (c) unreadable ledger: no ledger_grants are added beside (b)",
    !!p && Array.isArray(p.grants) && p.grants.length === 1 && lgrants(F, b.sid, "detail").length === 0,
    JSON.stringify(F.recordOf(b.sid, "detail")));
}

// The plans dir reaches list-drift as a Windows path whichever form the env carries.
function windowsPath(F) {
  if (process.platform !== "win32") {
    console.log("SKIP T4-2 (c) Windows plans-dir forms: not a Windows host");
    return;
  }
  const win = process.env.WORKFLOW_PLANS_DIR;
  const posix = F.slash(win).replace(/^([A-Za-z]):/, (_m, d) => `/${d.toLowerCase()}`);
  for (const [label, dir] of [["C:\\ form", win], ["/c/ form", posix]]) {
    const s = atStep(F, "lw", "detail", "detail-plan", TAGGED_PAIR(F));
    F.mark(s.sid, F.accepted(F.TERM, "", REASON), s.repo, { WORKFLOW_PLANS_DIR: dir });
    F.check(`T4-2 (c) plans dir in ${label} (${dir}): list-drift runs and both concerns are granted`,
      lgrants(F, s.sid, "detail").length === 2, JSON.stringify(F.recordOf(s.sid, "detail")));
  }
}

// --record rewrites the record and carries ledger_grants.
function carried(F, at) {
  const s = at.detail;
  F.writePlan(s.sid, "detail", "# Detail\n\n## Steps\n\nMid-line the glossary-drift appears.\n");
  const d = F.drift(s.sid, "detail", s.repo, true);
  const rec = F.recordOf(s.sid, "detail");
  F.check("T4-2 (c) --record after a ledger grant: fingerprint written, ledger_grants d1/d2 carried",
    F.reached(d) && !!rec && typeof rec.fingerprint === "string" &&
    lgrants(F, s.sid, "detail").map((x) => x.discrim).sort().join(",") === "d1,d2", `${JSON.stringify(rec)} ${d.all}`);
}

function cli(F, at) {
  F.check("T4-2 bin/check-glossary-ledger-grant exists", fs.existsSync(`${F.ROOT}/bin/check-glossary-ledger-grant`), "missing");
  const det = at.detail;
  const out = at.outline;
  const run = (sid, format, norm, discrim) => F.ledgerGrant(["--session", sid, "--format", format, "--norm", norm, "--discrim", discrim]);
  const cases = [
    ["norm and discrim both match (detail-plan)", run(det.sid, "detail-plan", det.norm, "d1"), 0],
    ["second discrim of the same term", run(det.sid, "detail-plan", det.norm, "d2"), 0],
    ["norm and discrim both match (outline-plan)", run(out.sid, "outline-plan", out.norm, "d1"), 0],
    ["discrim only half-matches (other discrim)", run(det.sid, "detail-plan", det.norm, "d9"), 1],
    ["norm only half-matches (other norm)", run(det.sid, "detail-plan", F.TERM2, "d1"), 1],
    ["another stage's grant (outline-plan on a detail-only session)", run(det.sid, "outline-plan", det.norm, "d1"), 1],
    ["format with no stage (security-plan)", run(det.sid, "security-plan", det.norm, "d1"), 1],
    ["--discrim missing", F.ledgerGrant(["--session", det.sid, "--format", "detail-plan", "--norm", det.norm]), 2],
    ["invalid session id", run("../escape", "detail-plan", det.norm, "d1"), 2],
  ];
  for (const [label, r, want] of cases) {
    F.check(`T4-2 check-glossary-ledger-grant: ${label} → exit ${want}`, F.reached(r) && r.code === want, `code=${r.code} ${r.all}`);
  }
}

module.exports = { grants, pending, failClosed, windowsPath, carried, cli };

"use strict";
// T4-2 part of tests/hooks/feat-2529-glossary-accept.js (#2529), targets (a) deterministic
// findings and (b) provenance blocks. Holds no case markers; the entrypoint wraps each run
// function in one. The (a) records come from the real `check-glossary-drift --record`, so the
// fingerprint the handler recomputes is the one the CLI wrote.

const PLAN = "# Outline\n\n## Approach\n\nMid-line the glossary-drift appears.\n";
const REASON = "user accepted this spelling";

// A repo + session at outline with a recorded open finding for the variant glossary-drift.
function pendingOutline(F, tag) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.writePlan(sid, "outline", PLAN);
  F.seedAt(sid, "outline", repo);
  const d = F.drift(sid, "outline", repo, true);
  const rec = F.recordOf(sid, "outline");
  F.check(`T4-2 [${tag}] precondition: --record wrote an outline record with one finding`,
    F.reached(d) && !!rec && Array.isArray(rec.findings) && rec.findings.length === 1, `code=${d.code} ${d.all}`);
  return { repo, sid, rec, norm: rec && rec.findings && rec.findings[0] ? rec.findings[0].norm : F.TERM };
}

function grantsOf(F, sid, stage) { const r = F.recordOf(sid, stage); return (r && Array.isArray(r.grants)) ? r.grants : []; }

// (a): normalization, duplicate, preemptive, stage discriminator, provenance discriminator.
function findings(F) {
  for (const spelling of ["glossary drift", "Glossary Drift", "glossary-drift", "GLOSSARY-DRIFTS", "glossary drifts"]) {
    const s = pendingOutline(F, `norm-${spelling.replace(/\W+/g, "")}`);
    const r = F.mark(s.sid, F.accepted(spelling, "", REASON), s.repo);
    const g = grantsOf(F, s.sid, "outline");
    F.check(`T4-2 (a) term=${spelling}: one grant { norm, fingerprint: the record's, reason }`,
      g.length === 1 && g[0].norm === s.norm && !!s.rec && g[0].fingerprint === s.rec.fingerprint && g[0].reason === REASON,
      `${JSON.stringify(g)} ${r.all}`);
    if (spelling === "glossary drift") {
      F.expectRejected("T4-2 (a) the same term again (already granted)", s.sid, F.accepted("Glossary-Drift", "", REASON), s.repo);
      F.expectRejected("T4-2 (a) a term with no finding (preemptive)", s.sid, F.accepted(F.TERM2, "", REASON), s.repo);
    }
  }
  const st = pendingOutline(F, "stage-ok");
  F.mark(st.sid, F.accepted(F.TERM, "stage=outline", REASON), st.repo);
  F.check("T4-2 (a) stage=<current stage>: grant recorded", grantsOf(F, st.sid, "outline").length === 1,
    JSON.stringify(F.recordOf(st.sid, "outline")));
  const sm = pendingOutline(F, "stage-ng");
  F.expectRejected("T4-2 (a) stage=detail while the current stage is outline", sm.sid, F.accepted(F.TERM, "stage=detail", REASON), sm.repo,
    /stage=detail has no open finding/);
  F.expectRejected("T4-2 (a) op=add on a finding with no provenance block", sm.sid, F.accepted(F.TERM, "op=add", REASON), sm.repo);
  F.inject(sm.sid, "review_docs", "glossary_provenance", F.provenanceRecord(F.FP("b"),
    [{ term: F.TERM2, operation: "add", category: "internal", reason: "unmatched" }]));
  F.expectRejected("T4-2 (b) stage=outline on a term with only a provenance block", sm.sid, F.accepted(F.TERM2, "stage=outline", REASON), sm.repo);
}

// (a) refuses a record older than its inputs: artifact, combined glossary, intent rows.
function stale(F) {
  const a = pendingOutline(F, "stale-art");
  F.writePlan(a.sid, "outline", PLAN + "\nOne more unrelated sentence.\n");
  F.expectRejected("T4-2 (a) artifact changed after --record", a.sid, F.accepted(F.TERM, "", REASON), a.repo, /--record/);

  const g = pendingOutline(F, "stale-glo");
  F.writeFile(g.repo, "docs/glossary/user.md", F.GLOSSARY_FILES["docs/glossary/user.md"].replace("glossary term.", "glossary term!"));
  F.expectRejected("T4-2 (a) combined glossary changed after --record", g.sid, F.accepted(F.TERM, "", REASON), g.repo, /--record/);

  const i = pendingOutline(F, "stale-row");
  F.writeIntent(i.sid, { rows: [[F.TERM, "user", "add", "A spelling that differs from the glossary term."],
    ["review round", "session", "add", "One planner/reviewer exchange."]] });
  F.reapprove(i.sid, "clarify_intent");
  F.check("T4-2 [stale-row] precondition: the current step is still outline after re-approval",
    F.currentStep(i.sid) === "outline", F.currentStep(i.sid));
  F.expectRejected("T4-2 (a) intent glossary rows changed after --record", i.sid, F.accepted(F.TERM, "", REASON), i.repo, /--record/);
}

// (b): every blocked reason, op/cat narrowing, and (a) ignored where the step has no stage.
const REASONS = ["intent-missing", "session-unverified", "intent-unreadable", "intent-unapproved", "intent-modified"];
function provenance(F) {
  const repo = F.mkRepo("prov");
  const sid = F.newSid("prov");
  F.writeIntent(sid);
  F.seedAt(sid, "write_code", repo);
  const pfp = F.FP("c");
  const blocked = REASONS.map((reason, n) => ({ term: `term ${"abcde"[n]}`, operation: "add", category: n % 2 ? "internal" : "user", reason }))
    .concat([{ term: "zeta term", operation: "add", category: "user", reason: "unmatched" },
      { term: "zeta term", operation: "delete", category: "internal", reason: "unmatched" },
      { term: "eta term", operation: "add", category: "user", reason: "unmatched" },
      { term: "eta term", operation: "redefine", category: "internal", reason: "unmatched" }]);
  F.inject(sid, "review_docs", "glossary_provenance", F.provenanceRecord(pfp, blocked));
  F.inject(sid, "outline", "glossary_check", F.findingRecord("outline", F.FP("d")));
  const pgrants = () => { const p = F.ann(sid, "review_docs", "glossary_provenance"); return (p && Array.isArray(p.grants)) ? p.grants : []; };
  const has = (term, op, cat) => pgrants().some((x) => x.norm === term && x.operation === op && x.category === cat &&
    x.fingerprint === pfp && x.reason === REASON);

  for (const b of blocked.slice(0, REASONS.length)) {
    F.mark(sid, F.accepted(b.term, "", REASON), repo);
    F.check(`T4-2 (b) blocked reason ${b.reason}: grant { norm, operation, category, fingerprint } recorded`,
      has(b.term, b.operation, b.category), JSON.stringify(pgrants()));
  }
  F.mark(sid, F.accepted("zeta term", "op=add", REASON), repo);
  F.check("T4-2 (b) op=add: only the add block of zeta term is granted",
    has("zeta term", "add", "user") && !has("zeta term", "delete", "internal"), JSON.stringify(pgrants()));
  F.mark(sid, F.accepted("zeta term", "cat=internal", REASON), repo);
  F.check("T4-2 (b) cat=internal: the delete/internal block is granted next", has("zeta term", "delete", "internal"), JSON.stringify(pgrants()));
  F.expectRejected("T4-2 (b) op=redefine with no matching block", sid, F.accepted("zeta term", "op=redefine", REASON), repo);
  F.mark(sid, F.accepted("eta term", "", REASON), repo);
  F.check("T4-2 (b) no discriminator: every block of eta term is granted",
    has("eta term", "add", "user") && has("eta term", "redefine", "internal"), JSON.stringify(pgrants()));
  F.check("T4-2 (b) grants total = 5 reasons + 2 zeta + 2 eta", pgrants().length === REASONS.length + 4, JSON.stringify(pgrants()));
  // The injected record is stale (FP("d")) and holds an open finding, so the read side refuses
  // outline's complete and the current step is outline again: (a) is refused with the --record
  // reason. A current step with no stage is covered by cross-stage.js otherStage (R-S fixture).
  F.expectRejected("T4-2 (a) an injected stale outline record reopens outline and is refused with the --record reason",
    sid, F.accepted(F.TERM, "", REASON), repo, /--stage outline --record/);
}

// A grant is scoped to its stage and record: the next stage's record starts without it.
function scope(F) {
  const s = pendingOutline(F, "scope");
  F.mark(s.sid, F.accepted(F.TERM, "", REASON), s.repo);
  F.appendRaw(s.sid, [F.statusEvent("outline", "complete"), F.approvalEvent(s.sid, "outline")]);
  F.writePlan(s.sid, "detail", "# Detail\n\n## Steps\n\nMid-line the glossary-drift appears.\n");
  const d = F.drift(s.sid, "detail", s.repo, true);
  const det = F.recordOf(s.sid, "detail");
  F.check("T4-2 scope: the outline grant does not resolve the same variant at detail (exit 1)",
    F.reached(d) && d.code === 1 && !!det && Array.isArray(det.grants) && det.grants.length === 0, `code=${d.code} ${d.all}`);
  F.check("T4-2 scope: the outline record keeps its own grant", grantsOf(F, s.sid, "outline").length === 1,
    JSON.stringify(F.recordOf(s.sid, "outline")));
}

module.exports = { findings, stale, provenance, scope };

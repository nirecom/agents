"use strict";
// #2909 grant carry over a set of inputs and the shown grant expiry: a re-record carries a grant
// when only the inputs of its role set changed (check: artifact, rules; provenance: ops, rules)
// and its variants did not grow; any other change expires it into expired_grants with a cause.
// The CLI prints carried / EXPIRED lines, and recoveryFor names the terms and the changed inputs.

const path = require("node:path");

const RECORD = "hooks/workflow-state/glossary-check/record.js";
const CARRY = "hooks/workflow-state/glossary-check/grant-carry.js";
const STEP = "review_security";
const SRC = "src/a.js";
const BODY = "\"use strict\";\n// a mid-line glossary-drift comment\nmodule.exports = 1;\n";
const ECHO = "WORKFLOW_GLOSSARY_ACCEPTED: term=";
const FORBIDDEN = "cannot be accepted with GLOSSARY_ACCEPTED";

const valueOf = (evs) => (evs && evs[0] && (evs[0].value || evs[0])) || {};
const expiredOf = (v) => (Array.isArray(v.expired_grants) ? v.expired_grants : []);
const hasQuote = (s) => String(s).includes("'");

// checkRecordEvents / provenanceRecordEvents directly over hand-made inputs digests.
function unit(F) {
  const R = F.mod(RECORD);
  if (!R) return;
  const I = { artifact: F.FP("1"), glossary: F.FP("2"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const find = (variant, line) => ({ term: F.TERM, norm: F.TERM, variant, where: `${SRC}:${line}` });
  const prev = { fingerprint: F.FP("a"), inputs: I, findings: [find("glossary-drift", 2)],
    grants: [{ norm: F.TERM, fingerprint: F.FP("a"), reason: "fixture" }], ledger_grants: [] };
  const at = (over) => ({ fingerprint: F.FP("b"), inputs: Object.assign({}, I, over) });
  const rec = (over, findings) => valueOf(R.checkRecordEvents(prev, STEP, at(over), findings || [find("glossary-drift", 3)]));

  const ar = rec({ artifact: F.FP("9"), rules: F.FP("9") });
  F.check("artifact and rules both change, same variants: the grant moves to the new fingerprint, nothing expires",
    (ar.grants || []).length === 1 && ar.grants[0].fingerprint === F.FP("b") && expiredOf(ar).length === 0, JSON.stringify(ar));

  const ag = rec({ artifact: F.FP("9"), glossary: F.FP("8") });
  const e1 = expiredOf(ag)[0] || {};
  F.check("artifact and glossary change: the grant expires with cause inputs and the changed inputs",
    (ag.grants || []).length === 0 && expiredOf(ag).length === 1 && e1.norm === F.TERM && e1.term === F.TERM &&
    e1.cause === "inputs" && JSON.stringify([...(e1.changed || [])].sort()) === JSON.stringify(["artifact", "glossary"]) &&
    e1.fingerprint === F.FP("b"), JSON.stringify(ag));

  const ir = rec({ intent_rows: F.FP("7"), rules: F.FP("9") });
  F.check("intent_rows and rules change: the grant expires with cause inputs",
    (ir.grants || []).length === 0 && (expiredOf(ir)[0] || {}).cause === "inputs", JSON.stringify(ir));

  const rv = rec({ rules: F.FP("9") }, [find("glossary-drift", 2), find("glossarydrift", 4)]);
  F.check("rules change with a new variant: the grant expires with cause variants",
    (rv.grants || []).length === 0 && (expiredOf(rv)[0] || {}).cause === "variants", JSON.stringify(rv));

  const bare = Object.assign({}, prev);
  delete bare.inputs;
  const nb = valueOf(R.checkRecordEvents(bare, STEP, { fingerprint: F.FP("b") }, [find("glossary-drift", 2)]));
  F.check("a record without inputs names no change: the grant is not carried and expires with cause inputs",
    (nb.grants || []).length === 0 && (expiredOf(nb)[0] || {}).cause === "inputs", JSON.stringify(nb));

  F.check("a previous record without expired_grants is read as none", Array.isArray(ar.expired_grants), JSON.stringify(ar));
  const again = valueOf(R.checkRecordEvents(ag, STEP, at({ artifact: F.FP("9"), glossary: F.FP("8") }), [find("glossary-drift", 3)]));
  F.check("re-recording at the same fingerprint keeps expired_grants unchanged (idempotent)",
    JSON.stringify(expiredOf(again)) === JSON.stringify(expiredOf(ag)), `${JSON.stringify(again)} vs ${JSON.stringify(ag)}`);

  const P = { ops: F.FP("5"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const blocked = [{ term: "beta", norm: "beta", operation: "add", category: "user", reason: "not-in-intent" }];
  const pprev = { fingerprint: F.FP("c"), inputs: P, blocked,
    grants: [{ norm: "beta", operation: "add", category: "user", fingerprint: F.FP("c"), reason: "fixture" }] };
  const pat = (over) => ({ fingerprint: F.FP("d"), inputs: Object.assign({}, P, over) });
  const po = valueOf(R.provenanceRecordEvents(pprev, pat({ ops: F.FP("8"), rules: F.FP("8") }), "explicit", blocked));
  F.check("provenance: ops and rules both change, same blocked set: the grant moves to the new fingerprint",
    (po.grants || []).length === 1 && po.grants[0].fingerprint === F.FP("d") && expiredOf(po).length === 0, JSON.stringify(po));
  const pi = valueOf(R.provenanceRecordEvents(pprev, pat({ intent_rows: F.FP("7"), rules: F.FP("8") }), "explicit", blocked));
  F.check("provenance: intent_rows and rules change: the grant expires with cause inputs",
    (pi.grants || []).length === 0 && (expiredOf(pi)[0] || {}).cause === "inputs" && (expiredOf(pi)[0] || {}).norm === "beta",
    JSON.stringify(pi));
  const grown = blocked.concat([{ term: "beta", norm: "beta", operation: "add", category: "internal", reason: "not-in-intent" }]);
  const pv = valueOf(R.provenanceRecordEvents(pprev, pat({ ops: F.FP("8") }), "explicit", grown));
  const ev = expiredOf(pv)[0] || {};
  F.check("provenance: only ops changes but the blocked set grows for the granted norm: the grant expires with cause variants",
    (pv.grants || []).length === 0 && expiredOf(pv).length === 1 && ev.cause === "variants" && ev.norm === "beta", JSON.stringify(pv));
}

// One re-record, two granted norms, only rules changed: A keeps its variants and carries, B gains a
// variant and expires with cause variants.
function mixedUnit(F) {
  const R = F.mod(RECORD);
  if (!R) return;
  const B = F.TERM2;
  const I = { artifact: F.FP("1"), glossary: F.FP("2"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const find = (norm, variant, line) => ({ term: norm, norm, variant, where: `${SRC}:${line}` });
  const grant = (norm) => ({ norm, fingerprint: F.FP("a"), reason: "fixture" });
  const prev = { fingerprint: F.FP("a"), inputs: I, findings: [find(F.TERM, "glossary-drift", 2), find(B, "concern-ledger", 3)],
    grants: [grant(F.TERM), grant(B)], ledger_grants: [] };
  const now = { fingerprint: F.FP("b"), inputs: Object.assign({}, I, { rules: F.FP("9") }) };
  const v = valueOf(R.checkRecordEvents(prev, STEP, now,
    [find(F.TERM, "glossary-drift", 2), find(B, "concern-ledger", 3), find(B, "concernledger", 4)]));
  const grants = v.grants || [];
  const exp = expiredOf(v);
  F.check("mixed: grants holds only the unchanged-variant norm, on the new fingerprint",
    grants.length === 1 && grants[0].norm === F.TERM && grants[0].fingerprint === F.FP("b"), JSON.stringify(v));
  F.check("mixed: expired_grants holds only the norm with a new variant, with cause variants",
    exp.length === 1 && exp[0].norm === B && exp[0].cause === "variants", JSON.stringify(v));
}

// grantCarry on a previous record without a fingerprint: nothing to carry and nothing to expire.
function noPrevFingerprint(F) {
  const C = F.mod(CARRY);
  if (!C) return;
  const keysOf = (list, norm) => (list || []).filter((x) => x.norm === norm).map((x) => x.variant);
  const termOf = (norm) => norm;
  const prev = { inputs: { artifact: F.FP("1") }, findings: [{ term: F.TERM, norm: F.TERM, variant: "glossary-drift" }],
    grants: [{ norm: F.TERM, fingerprint: F.FP("a") }] };
  const fp = { ok: true, fingerprint: F.FP("b"), inputs: { artifact: F.FP("9") } };
  let got;
  try {
    got = C.grantCarry(prev, fp, C.CARRY_ROLES.check, keysOf, prev.findings, prev.findings, termOf);
  } catch (e) {
    got = `threw ${e && e.message}`;
  }
  F.check("grantCarry: a previous record without a fingerprint gives { carried: [], expired: [] }",
    JSON.stringify(got) === JSON.stringify({ carried: [], expired: [] }), JSON.stringify(got));
}

// The text parts of grant-carry.js: termsText, causeText, staleOutlook, reacceptText.
function texts(F) {
  const C = F.mod(CARRY);
  if (!C) return;
  F.check("CARRY_ROLES: check carries over artifact and rules, provenance over ops and rules",
    JSON.stringify(C.CARRY_ROLES) === JSON.stringify({ check: ["artifact", "rules"], provenance: ["ops", "rules"] }), JSON.stringify(C.CARRY_ROLES));
  F.check("termsText drops single quotes and duplicates", C.termsText(["user's guide", "a", "a"]) === "users guide, a", C.termsText(["user's guide", "a", "a"]));
  F.check("causeText of an inputs expiry names the changed inputs",
    C.causeText({ cause: "inputs", changed: ["glossary", "rules"] }) === "glossary, rules changed", C.causeText({ cause: "inputs", changed: ["glossary", "rules"] }));
  F.check("causeText of a variants expiry", C.causeText({ cause: "variants", changed: ["rules"] }) === "a new variant appeared",
    C.causeText({ cause: "variants", changed: ["rules"] }));
  F.check("causeText of a fields expiry (#2962)",
    C.causeText({ cause: "fields", changed: ["glossary"] }) === "its `Identifier` / `Short forms` / heading changed",
    C.causeText({ cause: "fields", changed: ["glossary"] }));
  const rec = { fingerprint: F.FP("a"), findings: [{ term: F.TERM, norm: F.TERM, variant: "glossary-drift" }],
    grants: [{ norm: F.TERM, fingerprint: F.FP("a") }] };
  const pos = C.staleOutlook(rec, ["rules"], C.CARRY_ROLES.check);
  F.check("staleOutlook: a rules change keeps carry possible and names the granted term",
    pos.carry === "possible" && JSON.stringify(pos.granted_terms) === JSON.stringify([F.TERM]), JSON.stringify(pos));
  const none = C.staleOutlook(rec, ["glossary", "rules"], C.CARRY_ROLES.check);
  F.check("staleOutlook: a glossary change gives carry none", none.carry === "none", JSON.stringify(none));

  const accept = (t) => `re-accept with: echo "<<${ECHO}${t} step=${STEP} — <reason>>>"`;
  const table = [
    ["cli, safe term", C.reacceptText(F.TERM, STEP, "cli"), (s) => s === accept(F.TERM)],
    ["hint, safe term", C.reacceptText(F.TERM, STEP, "hint"), (s) => s === accept(F.TERM)],
    ["cli, forbidden character", C.reacceptText("a$b", STEP, "cli"),
      (s) => s === `the term has a forbidden character ('$'), so it ${FORBIDDEN} — fix the heading or record it in the intent glossary`],
    ["hint, forbidden character", C.reacceptText("a$b", STEP, "hint"),
      (s) => s.includes("(U+0024)") && s.includes(FORBIDDEN) && !s.includes(ECHO) && !hasQuote(s)],
    ["cli, single quote", C.reacceptText("user's guide", STEP, "cli"), (s) => s === accept("user's guide")],
    ["hint, single quote", C.reacceptText("user's guide", STEP, "hint"),
      (s) => !hasQuote(s) && s.includes(`${ECHO}<term> step=${STEP}`) && s.includes("copy the term from the EXPIRED line of check-glossary-drift")],
  ];
  for (const [name, got, ok] of table) F.check(`reacceptText ${name}`, ok(String(got)), got);
  for (const t of [F.TERM, "a$b", "user's guide"]) {
    F.check(`reacceptText without a target (and with an unknown one) equals hint for ${t}`,
      C.reacceptText(t, STEP) === C.reacceptText(t, STEP, "hint") && C.reacceptText(t, STEP, "bogus") === C.reacceptText(t, STEP, "hint"),
      C.reacceptText(t, STEP));
  }
}

// A review_security session whose current inputs digests are known; body: the staged src file.
function session(F, tag, body) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.stageFile(repo, SRC, body);
  F.seedAt(sid, STEP, repo);
  const { stepFingerprint } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope"));
  const now = stepFingerprint(sid, STEP, { repoDir: repo });
  F.check(`${tag} precondition: the current fingerprint is computable`, now.ok === true, JSON.stringify(now));
  return { repo, sid, now };
}

// A previous record at a stale fingerprint granting `term`; over: the inputs it differs in.
function staleRecord(F, s, term, over, extra) {
  return Object.assign({
    v: 1, step: STEP, fingerprint: F.FP("e"), inputs: Object.assign({}, s.now.inputs, over),
    findings: [{ source: "deterministic", class: "spelling", term, norm: term, variant: term.replace(/ /g, "-"), where: `${SRC}:2` }],
    grants: [{ norm: term, fingerprint: F.FP("e"), reason: "fixture" }], ledger_grants: [],
  }, extra || {});
}

function evaluateOn(F, s, rec) {
  const R = F.mod(RECORD);
  return R ? R.evaluateGlossaryCheck(s.sid, STEP, { steps: { [STEP]: { glossary_check: rec } } }, { repoDir: s.repo }) : null;
}

function recovery(F) {
  const s = session(F, "exp-rec", "module.exports = 1;\n");
  if (!s.now.ok) return;
  const run = `check-glossary-drift --session ${s.sid} --step ${STEP} --record`;
  const recOf = (v) => String((v && v.detail && v.detail.recovery) || "");

  const pos = evaluateOn(F, s, staleRecord(F, s, F.TERM, { rules: F.FP("9") }));
  const pr = recOf(pos);
  F.check("stale, carry possible: detail names carry possible and the granted term",
    !!pos && pos.code === "glossary-check-stale" && pos.detail.carry === "possible" &&
    (pos.detail.granted_terms || []).includes(F.TERM) && JSON.stringify(pos.detail.changed) === JSON.stringify(["rules"]), JSON.stringify(pos));
  F.check("stale, carry possible: recovery names the changed input, the run and the carried term, not artifact",
    pr.includes("older than its inputs (changed: rules)") && pr.includes(run) &&
    pr.includes(`the grants for ${F.TERM} carry over when their variants did not change`) && !pr.includes("artifact") && !hasQuote(pr), pr);

  const ng = evaluateOn(F, s, staleRecord(F, s, F.TERM, { rules: F.FP("9") }, { grants: [] }));
  const ngr = recOf(ng);
  F.check("stale, carry possible, no grant: detail names carry possible and no granted term",
    !!ng && ng.code === "glossary-check-stale" && ng.detail.carry === "possible" && (ng.detail.granted_terms || []).length === 0, JSON.stringify(ng));
  F.check("stale, carry possible, no grant: recovery drops the grant clause and still names the change and the run",
    ngr.includes("older than its inputs (changed: rules)") && ngr.includes(run) && !ngr.includes("the grants for") &&
    !ngr.includes("carry over") && ngr.includes("then complete the step again") && !hasQuote(ngr), ngr);

  const none = evaluateOn(F, s, staleRecord(F, s, F.TERM, { glossary: F.FP("8"), rules: F.FP("9") }));
  const nr = recOf(none);
  F.check("stale, carry none: detail names carry none", !!none && none.detail.carry === "none", JSON.stringify(none));
  F.check("stale, carry none: recovery names the lapsing term, the cause and the re-accept echo",
    nr.includes(`the grants for ${F.TERM} lapse on that record because glossary, rules changed`) &&
    nr.includes(`${ECHO}${F.TERM} step=${STEP}`) && nr.includes(run) && !nr.includes("artifact") && !hasQuote(nr), nr);

  const bad = recOf(evaluateOn(F, s, staleRecord(F, s, "a$b", { glossary: F.FP("8") })));
  F.check("stale, carry none, forbidden character: no echo, U+0024, no single quote",
    bad.includes(FORBIDDEN) && bad.includes("U+0024") && !bad.includes(ECHO) && !hasQuote(bad), bad);

  const ap = recOf(evaluateOn(F, s, staleRecord(F, s, "user's guide", { glossary: F.FP("8") })));
  F.check("stale, carry none, single quote: placeholder term and the EXPIRED line pointer, no single quote",
    !hasQuote(ap) && ap.includes(`${ECHO}<term>`) && ap.includes("EXPIRED line"), ap);

  const expired = [{ norm: "user's guide", term: "user's guide", cause: "inputs", changed: ["glossary"], fingerprint: s.now.fingerprint }];
  const open = (extra) => Object.assign(staleRecord(F, s, "user's guide", {}, extra), { fingerprint: s.now.fingerprint, grants: [] });
  const ux = evaluateOn(F, s, open({ expired_grants: expired }));
  const uxr = recOf(ux);
  F.check("unresolved with an expired grant: detail.expired holds it",
    !!ux && ux.code === "glossary-findings-unresolved" && (ux.detail.expired || []).length === 1, JSON.stringify(ux));
  F.check("unresolved with an expired grant: recovery names the lapse first, no single quote",
    uxr.startsWith("the grant for users guide lapsed on the last record (glossary changed); ") && !hasQuote(uxr), uxr);
  const u = recOf(evaluateOn(F, s, open({})));
  F.check("unresolved without an expired grant: the findings list drops the single quote",
    u.includes("users guide") && !hasQuote(u) && !u.includes("lapsed"), u);
}

const expiredLine = (out, term) => String(out).split(/\r?\n/).find((l) => l.startsWith(`  EXPIRED: grant for "${term}" — `)) || "";

function cli(F) {
  const c = session(F, "exp-carry", BODY);
  F.inject(c.sid, STEP, "glossary_check", staleRecord(F, c, F.TERM, { rules: F.FP("9") }, { findings: [
    { source: "deterministic", class: "spelling", term: F.TERM, norm: F.TERM, variant: "glossary-drift", where: `${SRC}:2` }] }));
  const carried = `check-glossary-drift: carried 1 grant(s) (changed: rules): ${F.TERM}`;
  const dry = F.drift(c.sid, STEP, c.repo, false);
  F.check("without --record: the carried line is printed ahead of the record, exit 0", dry.code === 0 && dry.out.includes(carried), dry.all);
  const r = F.drift(c.sid, STEP, c.repo, true);
  F.check("--record: the carried line is printed and the grant sits on the new fingerprint",
    r.code === 0 && r.out.includes(carried) && ((F.recordOf(c.sid, STEP) || {}).grants || []).length === 1, `${r.all} ${JSON.stringify(F.recordOf(c.sid, STEP))}`);

  // #2962: a glossary-only change no longer expires with cause inputs, so the inputs cause is
  // driven by glossary + rules; FIELDS is the cause of a glossary-only change whose term moved.
  const GR = { glossary: F.FP("8"), rules: F.FP("9") };
  const FIELDS = "its `Identifier` / `Short forms` / heading changed";
  for (const [tag, term, over, extra, want, bad] of [
    ["exp-dollar", "a$b", GR, null, `  EXPIRED: grant for "a$b" — glossary, rules changed; the term has a forbidden character ('$'), so it ${FORBIDDEN}`, ECHO],
    ["exp-quote", "user's guide", GR, null, `  EXPIRED: grant for "user's guide" — glossary, rules changed; re-accept with: echo "<<${ECHO}user's guide step=${STEP} — <reason>>>"`, null],
    ["exp-fields", F.TERM, { glossary: F.FP("8") }, { term_fields: { [F.TERM]: F.FP("0") } },
      `  EXPIRED: grant for "${F.TERM}" — ${FIELDS}; re-accept with: echo "<<${ECHO}${F.TERM} step=${STEP} — <reason>>>"`, null],
  ]) {
    const s = session(F, tag, "module.exports = 1;\n");
    F.inject(s.sid, STEP, "glossary_check", staleRecord(F, s, term, over, extra));
    const x = F.drift(s.sid, STEP, s.repo, true);
    const line = expiredLine(x.out, term);
    F.check(`EXPIRED line for ${term} (${tag})`, line.startsWith(want) && (!bad || !line.includes(bad)), x.all);
  }

  // An old record (no term_fields) never carries over a glossary-only change; only the lapse is pinned.
  const o = session(F, "exp-old", "module.exports = 1;\n");
  F.inject(o.sid, STEP, "glossary_check", staleRecord(F, o, F.TERM, { glossary: F.FP("8") }));
  const ox = F.drift(o.sid, STEP, o.repo, true);
  F.check("an old record without term_fields: a glossary-only change expires the grant",
    expiredLine(ox.out, F.TERM) !== "" && ((F.recordOf(o.sid, STEP) || {}).grants || []).length === 0, ox.all);
}

// The same mix through the CLI: the staged file adds a new variant of TERM2 only.
function mixedCli(F) {
  const B = F.TERM2;
  const s = session(F, "exp-mixed", BODY.replace("module.exports", "// a mid-line concernledger comment\nmodule.exports"));
  if (!s.now.ok) return;
  const rec = staleRecord(F, s, F.TERM, { rules: F.FP("9") }, {
    findings: [
      { source: "deterministic", class: "spelling", term: F.TERM, norm: F.TERM, variant: "glossary-drift", where: `${SRC}:2` },
      { source: "deterministic", class: "spelling", term: B, norm: B, variant: "concern-ledger", where: `${SRC}:9` },
    ],
    grants: [{ norm: F.TERM, fingerprint: F.FP("e"), reason: "fixture" }, { norm: B, fingerprint: F.FP("e"), reason: "fixture" }],
  });
  F.inject(s.sid, STEP, "glossary_check", rec);
  const r = F.drift(s.sid, STEP, s.repo, true);
  F.check("mixed CLI: stdout carries one grant for the unchanged norm",
    r.out.includes(`check-glossary-drift: carried 1 grant(s) (changed: rules): ${F.TERM}`), r.all);
  F.check("mixed CLI: stdout prints an EXPIRED line for the norm with a new variant",
    expiredLine(r.out, B).includes("a new variant appeared") && expiredLine(r.out, F.TERM) === "", r.all);
  const after = F.recordOf(s.sid, STEP) || {};
  F.check("mixed CLI: the record keeps one grant and one expired entry",
    (after.grants || []).length === 1 && after.grants[0].norm === F.TERM && expiredOf(after).length === 1 && expiredOf(after)[0].norm === B,
    JSON.stringify(after));
}

// Scenario 4: a granted step, then a glossary edit; the re-record shows the expiry, a re-accept clears it.
function lapseShown(F) {
  const s = session(F, "exp-glo", BODY);
  F.drift(s.sid, STEP, s.repo, true);
  F.mark(s.sid, F.accepted(F.TERM, `step=${STEP}`), s.repo);
  F.check("exp-glo precondition: one grant", ((F.recordOf(s.sid, STEP) || {}).grants || []).length === 1, JSON.stringify(F.recordOf(s.sid, STEP)));
  // #2962: a matching-field edit (`Short forms`) of the granted term; a Definition-only edit carries.
  F.touchMatch(s.repo);
  const r = F.drift(s.sid, STEP, s.repo, true);
  const line = expiredLine(r.out, F.TERM);
  F.check("a glossary matching-field edit: the re-record prints an EXPIRED line naming the fields cause and the re-accept echo",
    r.code === 1 && line.includes("its `Identifier` / `Short forms` / heading changed") && line.includes(`${ECHO}${F.TERM} step=${STEP}`), r.all);
  const first = F.recordOf(s.sid, STEP) || {};
  F.check("the record keeps the expired grant with cause fields and glossary among the changed inputs",
    expiredOf(first).length === 1 && expiredOf(first)[0].cause === "fields" && (expiredOf(first)[0].changed || []).includes("glossary"), JSON.stringify(first));
  F.drift(s.sid, STEP, s.repo, true);
  F.check("a second re-record at the same fingerprint leaves expired_grants unchanged",
    JSON.stringify(expiredOf(F.recordOf(s.sid, STEP) || {})) === JSON.stringify(expiredOf(first)), JSON.stringify(F.recordOf(s.sid, STEP)));
  F.mark(s.sid, F.accepted(F.TERM, `step=${STEP}`), s.repo);
  const after = F.drift(s.sid, STEP, s.repo, true);
  F.check("after the re-accept: the re-record exits 0 and drops the expired entry",
    after.code === 0 && expiredOf(F.recordOf(s.sid, STEP) || {}).length === 0 && !after.out.includes("EXPIRED"), `${after.all} ${JSON.stringify(F.recordOf(s.sid, STEP))}`);
}

function run(F) {
  unit(F);
  mixedUnit(F);
  noPrevFingerprint(F);
  texts(F);
  recovery(F);
  cli(F);
  mixedCli(F);
  lapseShown(F);
}

module.exports = { run };

"use strict";
// #2962 the glossary-only staleness at evaluate time: a record is stale over a glossary-only change
// only when the rescan finds a different finding set, or a matching field (`Identifier` /
// `Short forms` / heading) of a found or granted term moved. Plus the provenance grant `basis`
// "definition-only", which keeps covering a redefine whose Definition text changes later.

const path = require("node:path");
const { spawnSync } = require("node:child_process");

const RECORD = "hooks/workflow-state/glossary-check/record.js";
const SCAN = "bin/lib/glossary-drift/scan.js";
const STEP = "review_security";
const SRC = "src/a.js";
const BODY = "\"use strict\";\n// a mid-line glossary-drift comment\nmodule.exports = 1;\n";
const INTERNAL = "docs/glossary/internal.md";

// A review_security step recorded over `body`, with the TERM finding granted.
function granted(F, tag, body) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.stageFile(repo, SRC, body || BODY);
  F.seedAt(sid, STEP, repo);
  const r = F.drift(sid, STEP, repo, true);
  F.check(`${tag} precondition: --record exits 1 with a finding`, F.reached(r) && r.code === 1, `code=${r.code} ${r.all}`);
  const m = F.mark(sid, F.accepted(F.TERM, `step=${STEP}`), repo);
  const rec = F.recordOf(sid, STEP);
  F.check(`${tag} precondition: one grant on the record fingerprint`,
    !!rec && (rec.grants || []).length === 1 && rec.grants[0].fingerprint === rec.fingerprint, `${JSON.stringify(rec)} ${m.all}`);
  return { repo, sid, rec };
}

function evaluate(F, s) {
  const R = F.mod(RECORD);
  return R ? R.evaluateGlossaryCheck(s.sid, STEP, F.readState(s.sid), { repoDir: s.repo }) : null;
}
const passes = (v) => !!v && v.ok === true;
const staleWith = (v, term) => !!v && v.ok === false && v.code === "glossary-check-stale" &&
  (!term || (Array.isArray(v.detail && v.detail.terms) && v.detail.terms.includes(term)));
const addEntry = (F, repo, term) =>
  F.writeFile(repo, INTERNAL, `${F.GLOSSARY_FILES[INTERNAL]}\n${F.entry(term, "A fixture entry.")}`);

function recordsTermFields(F) {
  const s = granted(F, "fields-rec");
  F.check("--record writes term_fields with the finding's norm (#2962)",
    !!s.rec && !!s.rec.term_fields && typeof s.rec.term_fields[F.TERM] === "string", JSON.stringify(s.rec));
}

function definitionOnly(F) {
  const s = granted(F, "fields-def");
  F.touchDefinition(s.repo);
  const v = evaluate(F, s);
  F.check("a glossary Definition-only change: the granted record stays current (#2962)", passes(v), JSON.stringify(v));
}

function matchingField(F) {
  const s = granted(F, "fields-match");
  F.touchMatch(s.repo);
  const v = evaluate(F, s);
  F.check("a glossary matching-field change: the record is stale and detail.terms names the term", staleWith(v, F.TERM), JSON.stringify(v));
  const rec = String(v && v.detail && v.detail.recovery);
  F.check("a glossary matching-field change: the recovery text names the term", rec.includes(F.TERM), rec);
  F.check("a glossary matching-field change: the recovery text holds no single quote", !rec.includes("'"), rec);
}

// (a) an added entry the artifact never spells.
function unrelatedEntry(F) {
  const s = granted(F, "fields-unrel");
  addEntry(F, s.repo, "zebra crossing");
  const v = evaluate(F, s);
  F.check("(a) an added unrelated glossary entry: the record stays current", passes(v), JSON.stringify(v));
}

// (b) an added entry the artifact spells apart: a new finding on rescan.
function driftingEntry(F) {
  const s = granted(F, "fields-new", "\"use strict\";\n// glossary-drift and release-gate\nmodule.exports = 1;\n");
  addEntry(F, s.repo, "release gate");
  const v = evaluate(F, s);
  F.check("(b) an added entry the artifact spells apart: the record is stale and detail.terms names it",
    staleWith(v, "release gate"), JSON.stringify(v));
}

// (c) artifact and glossary change together: stale at evaluate, cause "inputs" on the re-record.
function withArtifact(F) {
  const s = granted(F, "fields-both");
  F.touchDefinition(s.repo);
  F.stageFile(s.repo, SRC, `${BODY}module.exports.b = 2;\n`);
  const v = evaluate(F, s);
  F.check("(c) artifact and glossary both change: the record is stale",
    !!v && v.ok === false && v.code === "glossary-check-stale" &&
    v.detail.changed.includes("artifact") && v.detail.changed.includes("glossary"), JSON.stringify(v));
  const r = F.drift(s.sid, STEP, s.repo, true);
  const rec = F.recordOf(s.sid, STEP) || {};
  const exp = (rec.expired_grants || []).find((e) => e && e.norm === F.TERM);
  F.check("(c) artifact and glossary both change: the re-record lapses the grant with cause inputs",
    r.code === 1 && (rec.grants || []).length === 0 && !!exp && exp.cause === "inputs", `${r.code} ${JSON.stringify(rec)}`);
}

// (d) a record written before #2962 (no term_fields) is stale over any glossary change.
function oldRecord(F) {
  const s = granted(F, "fields-old");
  const old = Object.assign({}, s.rec);
  delete old.term_fields;
  F.inject(s.sid, STEP, "glossary_check", old);
  F.touchDefinition(s.repo);
  const v = evaluate(F, s);
  F.check("(d) a record without term_fields: a glossary Definition-only change stales it",
    !!v && v.ok === false && v.code === "glossary-check-stale", JSON.stringify(v));
}

// (e) the rescan throws: glossary-fingerprint-unavailable with error rescan-failed. The scan is
// patched in a child process so this process keeps the real module.
function rescanFails(F) {
  const s = granted(F, "fields-fail");
  F.touchDefinition(s.repo);
  const code = [
    `const S = require(${JSON.stringify(path.join(F.ROOT, SCAN))});`,
    "S.scanStageInputs = () => { throw new Error('fixture rescan failure'); };",
    `const R = require(${JSON.stringify(path.join(F.ROOT, RECORD))});`,
    `const W = require(${JSON.stringify(path.join(F.ROOT, "hooks/workflow-state"))});`,
    `const sid = ${JSON.stringify(s.sid)};`,
    `const v = R.evaluateGlossaryCheck(sid, ${JSON.stringify(STEP)}, W.readState(sid), { repoDir: ${JSON.stringify(s.repo)} });`,
    "process.stdout.write(JSON.stringify(v));",
  ].join("\n");
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, ["-e", code], { cwd: s.repo, encoding: "utf8", timeout: 60000, env });
  let v = null;
  try { v = JSON.parse(r.stdout); } catch (e) { v = null; }
  F.check("(e) a failing rescan: glossary-fingerprint-unavailable with error rescan-failed",
    !!v && v.ok === false && v.code === "glossary-fingerprint-unavailable" && v.detail && v.detail.error === "rescan-failed",
    `${r.status} ${r.stdout} ${r.stderr}`);
}

// G9: provenanceRecordEvents over an ops-only change whose redefine entry changed its Definition.
function provenanceBasis(F) {
  const R = F.mod(RECORD);
  if (!R) return;
  const P = { ops: F.FP("5"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const entry = (definition, extra) => Object.assign({ term: "beta", norm: "beta", operation: "redefine",
    category: "user", reason: "not-in-intent", definition }, extra);
  const grant = (extra) => Object.assign({ norm: "beta", operation: "redefine", category: "user",
    fingerprint: F.FP("c"), reason: "fixture" }, extra);
  const prev = (g) => ({ fingerprint: F.FP("c"), inputs: P, unmatched: [entry("Old text.", { fields_changed: false })],
    blocked: [], grants: [g] });
  const at = { fingerprint: F.FP("d"), inputs: Object.assign({}, P, { ops: F.FP("8") }) };
  const valueOf = (evs) => (evs && evs[0] && (evs[0].value || evs[0])) || {};
  const run = (g, next) => valueOf(R.provenanceRecordEvents(prev(g), at, "explicit", [next]));
  const kept = (v) => (v.grants || []).length === 1 && v.grants[0].fingerprint === F.FP("d");

  const basis = grant({ basis: "definition-only" });
  const a = run(basis, entry("New text.", { fields_changed: false }));
  F.check("provenanceRecordEvents: a definition-only grant carries over a later Definition edit (#2962)", kept(a), JSON.stringify(a));
  F.check("provenanceRecordEvents: the carried definition-only grant keeps its basis",
    kept(a) && a.grants[0].basis === "definition-only", JSON.stringify(a));
  const b = run(grant(), entry("New text.", { fields_changed: false }));
  F.check("provenanceRecordEvents: a grant without basis does not carry over a Definition edit", (b.grants || []).length === 0, JSON.stringify(b));
  const c = run(basis, entry("New text.", { fields_changed: true }));
  F.check("provenanceRecordEvents: a definition-only grant does not carry over a redefine whose matching fields changed",
    (c.grants || []).length === 0, JSON.stringify(c));
  const d = run(basis, entry("New text."));
  F.check("provenanceRecordEvents: a definition-only grant does not carry over an entry without fields_changed",
    (d.grants || []).length === 0, JSON.stringify(d));

  // The blocked filter at the same fingerprint: a definition-only grant covers only a redefine whose
  // fields_changed is false; an old entry without the field stays blocked (fail-safe).
  const same = (g, next) => valueOf(R.provenanceRecordEvents(Object.assign(prev(g), { unmatched: [next] }),
    { fingerprint: F.FP("c"), inputs: P }, "explicit", [next]));
  const covered = same(basis, entry("Old text.", { fields_changed: false }));
  F.check("provenanceRecordEvents: a definition-only grant covers a redefine with fields_changed false",
    (covered.blocked || []).length === 0, JSON.stringify(covered));
  const bare = same(basis, entry("Old text."));
  F.check("provenanceRecordEvents: a definition-only grant does not cover an old entry without fields_changed",
    (bare.blocked || []).length === 1, JSON.stringify(bare));
  const moved = same(basis, entry("Old text.", { fields_changed: true }));
  F.check("provenanceRecordEvents: a definition-only grant does not cover a redefine with fields_changed true",
    (moved.blocked || []).length === 1, JSON.stringify(moved));
  const plain = same(grant(), entry("Old text."));
  F.check("provenanceRecordEvents: a grant without basis still covers its entry as before (control)",
    (plain.blocked || []).length === 0, JSON.stringify(plain));
}

// A review_security step recorded over an artifact with no finding (a clean record).
function clean(F, tag) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.stageFile(repo, SRC, "\"use strict\";\nmodule.exports = 1;\n");
  F.seedAt(sid, STEP, repo);
  const r = F.drift(sid, STEP, repo, true);
  const rec = F.recordOf(sid, STEP);
  F.check(`${tag} precondition: --record exits 0 with no finding`,
    F.reached(r) && r.code === 0 && !!rec && (rec.findings || []).length === 0, `code=${r.code} ${JSON.stringify(rec)} ${r.all}`);
  return { repo, sid, rec };
}

// #2962: a clean record stays current over a glossary-only change that moves no finding.
function cleanRecord(F) {
  const t = clean(F, "fields-clean-tf");
  F.check("a clean record also writes term_fields as an empty map (#2962)",
    !!t.rec && !!t.rec.term_fields && typeof t.rec.term_fields === "object" && Object.keys(t.rec.term_fields).length === 0,
    JSON.stringify(t.rec));
  const d = clean(F, "fields-clean-def");
  F.touchDefinition(d.repo);
  const dv = evaluate(F, d);
  F.check("a clean record, then a glossary Definition-only change: the record stays current (#2962)", passes(dv), JSON.stringify(dv));
  const u = clean(F, "fields-clean-unrel");
  addEntry(F, u.repo, "zebra crossing");
  const uv = evaluate(F, u);
  F.check("a clean record, then an added unrelated glossary entry: the record stays current (#2962)", passes(uv), JSON.stringify(uv));
}

// #2962 checkRecordEvents: a glossary-only change with the same term_fields still lapses the grant
// with cause "variants" when the new findings hold another variant of the granted norm.
function variantGrowth(F) {
  const R = F.mod(RECORD);
  if (!R) return;
  const I = { artifact: F.FP("1"), glossary: F.FP("2"), intent_rows: F.FP("3"), rules: F.FP("4") };
  const find = (variant, line) => ({ term: F.TERM, norm: F.TERM, variant, where: `${SRC}:${line}` });
  const TF = { [F.TERM]: F.FP("e") };
  const prev = { fingerprint: F.FP("a"), inputs: I, findings: [find("glossary-drift", 2)], term_fields: TF,
    grants: [{ norm: F.TERM, fingerprint: F.FP("a"), reason: "fixture" }], ledger_grants: [] };
  const at = { fingerprint: F.FP("b"), inputs: Object.assign({}, I, { glossary: F.FP("8") }), termFields: TF };
  const evs = R.checkRecordEvents(prev, STEP, at, [find("glossary-drift", 2), find("glossarydrift", 4)]);
  const v = (evs && evs[0] && (evs[0].value || evs[0])) || {};
  const exp = (v.expired_grants || []).find((e) => e && e.norm === F.TERM);
  F.check("checkRecordEvents: glossary-only change, same term_fields, a new variant: the grant is not carried",
    (v.grants || []).length === 0, JSON.stringify(v));
  F.check("checkRecordEvents: glossary-only change, same term_fields, a new variant: the grant lapses with cause variants",
    !!exp && exp.cause === "variants", JSON.stringify(v));
}

// #2962: a glossary-only change that makes the finding vanish (the variant is declared as the
// term's Identifier): stale at evaluate naming the term, and the re-record holds no finding.
function vanishingFinding(F) {
  const s = granted(F, "fields-vanish");
  F.writeFile(s.repo, "docs/glossary/user.md", F.GLOSSARY_FILES["docs/glossary/user.md"]
    .replace("the glossary term.\n", "the glossary term.\n- **Identifier**: `glossary-drift`\n"));
  const v = evaluate(F, s);
  F.check("a glossary-only change that removes the finding: the record is stale and detail.terms names the term",
    staleWith(v, F.TERM) && JSON.stringify(v.detail.changed) === "[\"glossary\"]", JSON.stringify(v));
  const r = F.drift(s.sid, STEP, s.repo, true);
  const rec = F.recordOf(s.sid, STEP) || {};
  F.check("a glossary-only change that removes the finding: the re-record exits 0 and holds no finding",
    r.code === 0 && Array.isArray(rec.findings) && rec.findings.length === 0, `${r.code} ${JSON.stringify(rec)} ${r.all}`);
  const after = evaluate(F, s);
  F.check("a glossary-only change that removes the finding: the re-recorded step evaluates current", passes(after), JSON.stringify(after));
}

function run(F) {
  recordsTermFields(F);
  definitionOnly(F);
  matchingField(F);
  unrelatedEntry(F);
  driftingEntry(F);
  withArtifact(F);
  oldRecord(F);
  rescanFails(F);
}

module.exports = { run, provenanceBasis, cleanRecord, variantGrowth, vanishingFinding };

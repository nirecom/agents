"use strict";
// T7-4 (input 4, rules): through the opts.ruleModules seam, one changed byte in a copy of each
// RULE_MODULES file (inside a function body) moves rulesVersion() and stales the record for all
// six glossary steps; a re-record carries the stale record's grants (#2909). A file outside RULE_MODULES does
// not move the digest, and the real digest is computed from every rule module's bytes (no probes).

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");
const C = require("./common");

const RULE_MODULES = ["bin/lib/glossary-drift.js", "hooks/lib/glossary-term.js",
  "hooks/lib/comment-block-scan.js", "hooks/lib/markdown-fence.js", "bin/lib/glossary-provenance.js",
  "bin/lib/glossary-drift/extract.js", "bin/lib/glossary-drift/terms.js", "bin/lib/glossary-drift/context.js",
  "bin/lib/glossary-drift/match.js", "bin/lib/glossary-drift/scan.js",
  "hooks/workflow-state/glossary-check/scope/changed-lines.js"];
const digestOf = (v) => (typeof v === "string" ? v : v && v.digest) || null;

// Copies of the rule modules under one temp root; returns { root, paths } or null.
function copies(tag) {
  const root = F.slash(fs.mkdtempSync(path.join(os.tmpdir(), `g2529-rules-${tag}-`)));
  const paths = [];
  for (const rel of RULE_MODULES) {
    const src = path.join(F.ROOT, rel);
    if (!fs.existsSync(src)) return F.check(`rule module ${rel} exists`, false, "missing") && null;
    const dst = path.join(root, ...rel.split("/"));
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
    paths.push(F.slash(dst));
  }
  return { root, paths };
}

// One byte inside a function body: an extra space after the first `return`.
function bump(file) {
  const text = fs.readFileSync(file, "utf8");
  fs.writeFileSync(file, /return /.test(text) ? text.replace("return ", "return  ") : `${text} `);
}

function realDigest(m) {
  const shas = RULE_MODULES.slice().sort().map((rel) => F.sha256(fs.readFileSync(path.join(F.ROOT, rel))));
  const got = digestOf(m.scope.rulesVersion());
  const candidates = [shas.join(""), shas.join("\n"), JSON.stringify(shas)].map((s) => F.sha256(s));
  F.check("rulesVersion(): the real digest is the sha256 of every rule module's sha256 in path order",
    !!got && candidates.includes(got), JSON.stringify({ got, shas }));
  const src = fs.readFileSync(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope.js"), "utf8");
  F.check("scope.js: no probe-word list feeds the rules digest", !/probe/i.test(src), "probe found");
}

function seam(m) {
  const base = copies("seam");
  if (!base) return;
  const d0 = digestOf(m.scope.rulesVersion({ ruleModules: base.paths }));
  F.writeFile(base.root, "hooks/lib/not-a-rule.js", "module.exports = 1;\n");
  F.check("rulesVersion: a file outside RULE_MODULES does not move the digest",
    !!d0 && digestOf(m.scope.rulesVersion({ ruleModules: base.paths })) === d0, d0);
  RULE_MODULES.forEach((rel, i) => {
    const c = copies(`one-${i}`);
    if (!c) return;
    bump(c.paths[i]);
    const d = digestOf(m.scope.rulesVersion({ ruleModules: c.paths }));
    F.check(`rulesVersion: one byte inside a function of ${rel} moves the digest`, !!d && !!d0 && d !== d0, `${d0} ${d}`);
  });
}

function staleness(m, steps = F.GLOSSARY_STEPS) {
  const changed = copies("stale");
  if (!changed) return;
  bump(changed.paths[1]);
  const opts = { ruleModules: changed.paths };
  for (const step of steps) {
    const ctx = C.baseline(m, `t74-${step}`, step);
    const before = C.fp(m, ctx);
    const after = C.fp(m, ctx, opts);
    const moved = before.ok && after.ok ? C.COMPONENTS.filter((k) => before.inputs[k] !== after.inputs[k]) : null;
    F.check(`${step} changed rule module: only rules moves`, !!moved && moved.join(",") === "rules", JSON.stringify(moved));
    const v = C.evaluate(m, ctx, opts);
    F.check(`${step} changed rule module: evaluateGlossaryCheck is glossary-check-stale naming only rules`,
      !!v && v.ok === false && v.code === "glossary-check-stale" && C.named(v.detail).join(",") === "rules", JSON.stringify(v));
    F.check(`${step} changed rule module: the stale detail says the grant can carry and names its term (#2909)`,
      !!v && !!v.detail && v.detail.carry === "possible" && (v.detail.granted_terms || []).includes(F.TERM), JSON.stringify(v));
    const rec = F.recordOf(ctx.sid, step);
    const valueAfter = (fpr) => {
      const evs = m.record.checkRecordEvents(rec, step, fpr, rec ? rec.findings : []) || [];
      const ev = evs.find((e) => e && e.key === "glossary_check");
      return ev && ev.value ? ev.value : null;
    };
    const grantsOf = (val) => (val ? val.grants || [] : null);
    F.check(`${step} changed rule module: a same-fingerprint re-record keeps the grant (control)`,
      (grantsOf(valueAfter(before)) || []).length > 0, JSON.stringify(valueAfter(before)));
    const val = valueAfter(after);
    const g = grantsOf(val);
    F.check(`${step} changed rule module: the re-record carries the grant to the new fingerprint (#2909)`,
      Array.isArray(g) && g.length > 0 && g.every((x) => x.fingerprint === after.fingerprint), JSON.stringify(val));
    if (!val) continue;
    F.appendRaw(ctx.sid, [F.annotationEvent(step, "glossary_check", val)]);
    const p = C.evaluate(m, ctx, opts);
    F.check(`${step} changed rule module: the re-record with the carried grant passes under the same rule modules`,
      C.passes(p), JSON.stringify(p));
  }
}

// Section entry points, so entry files can split the sections across processes.
const runDigest = C.withModules((m) => {
  realDigest(m);
  seam(m);
});
const runStaleness = C.withModules(staleness);

function run() {
  runDigest();
  runStaleness();
}

module.exports = { run, runDigest, runStaleness, copies, bump };

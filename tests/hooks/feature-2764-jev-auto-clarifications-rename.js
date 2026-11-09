#!/usr/bin/env node
// tests/hooks/feature-2764-jev-auto-clarifications-rename.js
// Tests: hooks/lib/temporary-migrations/jev-auto-clarifications-rename.js
// Tags: TL2, hooks, jev, config-flag, flag-rename, temporary-migration, table-driven, scope:issue-specific, pwsh-not-required
// #2764: JEV_AUTO_SKIP_ASKUSER -> JEV_AUTO_CLARIFICATIONS. The new name wins; only while it is
// unset is the old one read, and a user's old "off" stays off with one stderr warning per process.
// TL3 gap: none; the resolver reads env and .env files only.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { after, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./feature-2461-jev/fixture");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2764fr-"));
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const REL = "hooks/lib/temporary-migrations/jev-auto-clarifications-rename.js";
const MOD = F.lib(REL);
const NEW = "JEV_AUTO_CLARIFICATIONS";
const OLD = "JEV_AUTO_SKIP_ASKUSER";
// resolve(name, {env, dotenv, calls}) -> {values (lower-cased, one per call), warnings (stderr lines naming the new flag)}.
// The resolver may return the value or {value, ...}; both read the same here.
function resolve(name, opt = {}) {
  const sc = F.scene(ROOT, name);
  if (opt.dotenv) fs.writeFileSync(path.join(sc.cfg, ".env"), opt.dotenv);
  const o = F.nodeEval(sc, null, `const m = require(${JSON.stringify(MOD)});
const v = [];
for (let i = 0; i < Number(process.argv[2]); i++) {
  const r = m.resolveClarificationsFlag();
  v.push(String(r && typeof r === "object" ? r.value : r).trim().toLowerCase());
}
console.log(JSON.stringify({ v }));`, [String(opt.calls || 1)], Object.assign({ JEV: "off" }, opt.env || {}));
  assert.strictEqual(o.status, 0, o.stderr.slice(0, 300));
  return { values: o.json.v, warnings: o.stderr.split("\n").filter((l) => l.includes(NEW)) };
}

caseBegin("resolution", "hooks/lib/temporary-migrations/jev-auto-clarifications-rename.js");
const CASES = [
  { name: "neither set: default on", env: {}, want: "on", warn: 0 },
  { name: "new on", env: { [NEW]: "on" }, want: "on", warn: 0 },
  { name: "new off", env: { [NEW]: "off" }, want: "off", warn: 0 },
  { name: "new on wins over old off", env: { [NEW]: "on", [OLD]: "off" }, want: "on", warn: 0 },
  { name: "new off wins over old on", env: { [NEW]: "off", [OLD]: "on" }, want: "off", warn: 0 },
  { name: "only old off (export): off with a warning", env: { [OLD]: "off" }, want: "off", warn: 1 },
  { name: "only old off (.env): off with a warning", dotenv: `${OLD}=off\n`, want: "off", warn: 1 },
  { name: "new in .env wins over old export", env: { [OLD]: "off" }, dotenv: `${NEW}=on\n`, want: "on", warn: 0 },
];
for (const c of CASES) {
  test(c.name, () => {
    const r = resolve(`r-${c.name.replace(/[^a-z0-9]+/gi, "-")}`, c);
    assert.deepStrictEqual(r.values, [c.want], c.name);
    assert.strictEqual(r.warnings.length, c.warn, `${c.name}: warnings ${JSON.stringify(r.warnings)}`);
  });
}
test("only old on: on (the old value is honoured)", () => {
  assert.deepStrictEqual(resolve("r-old-on", { env: { [OLD]: "on" } }).values, ["on"]);
});
test("only old off, three calls in one process: off every time, one warning", () => {
  const r = resolve("r-once", { env: { [OLD]: "off" }, calls: 3 });
  assert.deepStrictEqual(r.values, ["off", "off", "off"]);
  assert.strictEqual(r.warnings.length, 1, JSON.stringify(r.warnings));
  assert.ok(r.warnings[0].includes(OLD), `the warning names the old flag (${r.warnings[0]})`);
});
caseEnd();

caseBegin("temporary-markers", "hooks/lib/temporary-migrations/jev-auto-clarifications-rename.js");
test("the module is one BEGIN/END temporary block with a dated BEGIN line and a deletion-condition", () => {
  const text = fs.readFileSync(path.join(F.REPO, REL), "utf8").replace(/\r/g, "");
  const ls = text.split("\n");
  const b = ls.findIndex((l) => /^\/\/ --- BEGIN temporary: .*JEV_AUTO_SKIP_ASKUSER.* (->|→) .*JEV_AUTO_CLARIFICATIONS.* migration added \d{4}-\d{2}-\d{2} ---$/.test(l));
  assert.ok(b >= 0, "BEGIN line");
  assert.ok(/^\/\/ deletion-condition: \S/.test(ls[b + 1] || ""), "deletion-condition right after BEGIN");
  assert.ok(ls.some((l) => /^\/\/ --- END temporary: .*JEV_AUTO_SKIP_ASKUSER.* (->|→) .*JEV_AUTO_CLARIFICATIONS.* migration ---$/.test(l)), "END line");
});
test("no other hooks/ or bin/ JS file reads the old flag name", () => {
  const hits = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { if (e.name !== "node_modules") walk(p); continue; }
      if (!/\.js$/.test(e.name) && !/^[^.]+$/.test(e.name)) continue;
      if (F.fwd(p).endsWith(REL)) continue;
      if (fs.readFileSync(p, "utf8").includes(OLD)) hits.push(F.fwd(path.relative(F.REPO, p)));
    }
  };
  walk(path.join(F.REPO, "hooks"));
  walk(path.join(F.REPO, "bin"));
  assert.deepStrictEqual(hits, []);
});
caseEnd();

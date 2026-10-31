"use strict";
// Staged-read part of tests/hooks/feature-2507-precommit-node.js (#2507). The migration-blocks gate
// runs as the real module (copied into a stub cfgDir); the other five gates are rc-0 stubs. A child
// Node with the tests/lib/node-spawn-log.js preload counts git processes. No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { stubCfg } = require("./gate-cases");

const MIGRATION = "bin/lib/check-migration-blocks.js";
// Marker lines are assembled so this file never holds a block line itself. Synthetic description.
const BAD = `// --- ${"BEGIN"} temporary: fixture shim ---\nconst x = 1;\n// --- ${"END"} temporary: fixture shim ---\n`;
const GOOD = "const x = 1;\n";
const GIT_RE = /(^|\/)git(\.exe)?( |$)/;

function realMigrationCfg(F) {
  const cfg = stubCfg(F);
  fs.copyFileSync(path.join(F.REPO, MIGRATION), path.join(cfg.dir, MIGRATION));
  return cfg.dir;
}

// runGates(F, repoTop, cfgDir) -> { result, gitCount } from snapshot + agents-repo-gates in a child.
function runGates(F, repoTop, cfgDir) {
  const dir = F.tmp("gate-staged-run");
  const runner = path.join(dir, "runner.js");
  fs.writeFileSync(runner, `"use strict";
(async () => {
  const snap = await require(${JSON.stringify(path.join(F.PCD, "snapshot.js"))}).createSnapshot({ repoTop: process.argv[2], env: process.env });
  const ctx = { repoTop: process.argv[2], cfgDir: process.argv[3], env: process.env, isAgentsRepo: true };
  const r = await require(${JSON.stringify(path.join(F.PCD, "checks", "agents-repo-gates.js"))}).run({ context: ctx, snapshot: snap, files: snap.files() });
  process.stdout.write(JSON.stringify(r));
})();
`);
  const log = path.join(dir, "spawn.log");
  const preload = path.join(F.REPO, "tests", "lib", "node-spawn-log.js").replace(/\\/g, "/");
  const r = spawnSync(process.execPath, [runner, repoTop, cfgDir], {
    cwd: repoTop, encoding: "utf8", timeout: 120000,
    env: F.cleanEnv({ NODE_OPTIONS: `--require "${preload}"`, TEST_NODE_SPAWN_LOG: log }),
  });
  assert.strictEqual(r.status, 0, `${r.stdout}${r.stderr}`);
  const line = (rec) => [rec.cmd, ...rec.args].join(" ").replace(/\\/g, "/");
  const records = fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  assert.ok(records.some((rec) => rec.fn === "main"), "the preload reached the runner");
  const gitLines = records.filter((rec) => rec.fn !== "main" && GIT_RE.test(line(rec))).map(line);
  return { result: JSON.parse(r.stdout), gitLines };
}

const stdoutOf = (r) => r.messages.filter((m) => m.stream === "stdout").map((m) => m.text);

function gateStagedReads(F) {
  test("the migration-blocks gate judges the staged content when staged and working tree differ", () => {
    const cfgDir = realMigrationCfg(F);
    const dirty = F.repo("gate-staged-dirty");
    F.write(dirty, "bin/tool.js", BAD);
    F.stage(dirty, "bin/tool.js");
    F.write(dirty, "bin/tool.js", GOOD);
    const blocked = runGates(F, dirty, cfgDir).result;
    assert.strictEqual(blocked.verdict, "block", JSON.stringify(blocked));
    assert.deepStrictEqual(stdoutOf(blocked), [
      "bin/tool.js:1: error: migration block description missing arrow (→ or ->) or 'migration' keyword: \"fixture shim\"",
      "",
      "Commit blocked: migration block format violations (checker rc=1).",
    ]);
    const clean = F.repo("gate-staged-clean");
    F.write(clean, "bin/tool.js", GOOD);
    F.stage(clean, "bin/tool.js");
    F.write(clean, "bin/tool.js", BAD);
    const passed = runGates(F, clean, cfgDir).result;
    assert.strictEqual(passed.verdict, "pass", JSON.stringify(passed));
  });
  test("the git process count of snapshot + gates does not grow with the staged file count (1 vs 12)", () => {
    const cfgDir = realMigrationCfg(F);
    const counts = [1, 12].map((n) => {
      const dir = F.repo(`gate-staged-n${n}`);
      const rels = Array.from({ length: n }, (_, i) => `bin/m${i}.js`);
      for (const rel of rels) F.write(dir, rel, GOOD);
      F.stage(dir, ...rels);
      const { result, gitLines } = runGates(F, dir, cfgDir);
      assert.strictEqual(result.verdict, "pass", JSON.stringify(result));
      assert.deepStrictEqual(gitLines.filter((l) => / show :/.test(l)), [], `N=${n}: no per-file git show`);
      return gitLines.length;
    });
    assert.strictEqual(counts[1], counts[0], `N=12 starts ${counts[1]} git processes, N=1 starts ${counts[0]}`);
  });
}

module.exports = { gateStagedReads };

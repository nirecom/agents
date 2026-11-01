"use strict";
// Runs one pre-commit check, or one tests-frontmatter gate, over the index of the repo at the cwd,
// so a test drives a single check without a whole commit (#2507: replaces sourcing the retired
// hooks/lib/precommit-*.sh). CLI: node precommit-check-runner.js [--cfg <dir>] [--markers] <check> [<gate>]
// A <check> runs through the shipped orchestrator (agentsRepoOnly and failMode apply) and exits
// with its rc; section markers are left out unless --markers. A <gate> (frontmatter, case-markers,
// test-runner, language-match) runs alone: exit 1 when it blocks, else 0. Any throw exits 3. --cfg
// defaults to this checkout. Module: run({ cwd, cfgDir, env, check, gate, markers }) -> rc.
const path = require("path");

const CHECKOUT = path.resolve(__dirname, "..", "..");
const GATES = {
  frontmatter: "frontmatter-gate", "case-markers": "case-markers-gate",
  "test-runner": "test-runner-gate", "language-match": "language-match-gate",
};

async function run({ cwd = process.cwd(), cfgDir = CHECKOUT, env = process.env, check, gate, markers = false }) {
  const cfg = path.resolve(cfgDir);
  const pcd = path.join(cfg, "hooks", "pre-commit.d");
  const output = require(path.join(pcd, "output.js"));
  const realMarker = output.marker;
  if (!markers) output.marker = () => {};
  try {
    const { spawnSync } = require("child_process");
    const top = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd, env, encoding: "utf8" });
    const repoTop = top.status === 0 ? String(top.stdout).replace(/\r?\n$/, "") : cwd;
    const context = await require(path.join(pcd, "context.js")).buildContext({ cfgDir: cfg, repoTop, env, isTTY: false });
    const snapshot = await require(path.join(pcd, "snapshot.js")).createSnapshot({ repoTop: context.repoTop, env });
    if (gate) {
      if (check !== "tests-frontmatter" || !GATES[gate]) throw new Error(`unknown gate ${check}/${gate}`);
      const g = require(path.join(pcd, "checks", "tests-frontmatter", `${GATES[gate]}.js`)).gate;
      const R = require(path.join(cfg, "hooks", "lib", "test-gates", "registry.js"));
      const files = await snapshot.files();
      const r = R.withEnv(env, () => g({ context, snapshot, files }));
      output.writeMessages(r.messages);
      return r.block ? 1 : 0;
    }
    const registry = require(path.join(pcd, "registry.js"));
    const entry = registry.CHECKS.find((c) => c.name === check);
    if (!entry) throw new Error(`unknown check ${check}`);
    return await require(path.join(pcd, "orchestrator.js")).run({
      entries: [entry], context, snapshot, loadCheck: (e) => require(path.join(pcd, "checks", `${e.name}.js`)),
    });
  } finally {
    output.marker = realMarker;
  }
}

if (require.main === module) {
  const argv = process.argv.slice(2);
  const opts = { markers: false };
  while (argv[0] && argv[0].startsWith("--")) {
    const flag = argv.shift();
    if (flag === "--cfg") opts.cfgDir = argv.shift();
    else if (flag === "--markers") opts.markers = true;
    else {
      process.stderr.write(`precommit-check-runner: unknown flag ${flag}\n`);
      process.exit(2);
    }
  }
  [opts.check, opts.gate] = argv;
  if (!opts.check) {
    process.stderr.write("usage: precommit-check-runner.js [--cfg <dir>] [--markers] <check> [<gate>]\n");
    process.exit(2);
  }
  run(opts).then((rc) => {
    process.exitCode = rc;
  }, (e) => {
    process.stderr.write(`precommit-check-runner: ${(e && e.message) || e}\n`);
    process.exitCode = 3;
  });
}

module.exports = { run, CHECKOUT };

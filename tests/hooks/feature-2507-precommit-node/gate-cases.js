"use strict";
// agents-repo-gates part of tests/hooks/feature-2507-precommit-node.js (#2507). The six gate
// modules are stubbed in a temp cfgDir; each stub records argv and cwd and returns a set rc.
// Expected text is the retired bash gates' wording, now hooks/pre-commit.d/checks/agents-repo-gates.js.
// No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

// module path, marker name, what, doc — in call order.
const GATES = [
  ["bin/lib/check-on-demand-rules.js", "agents-repo-gate-check-on-demand-rules", "on-demand rules-injection notation violations", "docs/architecture/claude-code/rules-injection.md"],
  ["bin/check-session-id-ssot/main.js", "agents-repo-gate-check-session-id-ssot", "session-id env reads bypassing the SSOT resolver", "docs/architecture/claude-code/session-id-resolution.md"],
  ["bin/lib/check-migration-blocks.js", "agents-repo-gate-check-migration-blocks", "migration block format violations", ""],
  ["bin/check-plans-artifacts", "agents-repo-gate-check-plans-artifacts", "plans-dir names that are not registered artifacts", "docs/architecture/claude-code/state-dirs.md"],
  ["bin/check-plans-dir-isolation/main.js", "agents-repo-gate-check-plans-dir-isolation", "test fixture isolation violations", "rules/test/fixture-isolation.md"],
  ["bin/check-root-names/main.js", "agents-repo-gate-check-root-names", "root-name violations", "docs/architecture/claude-code/root-names.md"],
];
const FAIL_CLOSED = "Commit blocked: the agents-repo gate fails closed. Emergency bypass: git commit --no-verify";

// stubCfg(F, behaviour) — behaviour[i] is an rc, "throw", "norun" or "missing" for gate i.
function stubCfg(F, behaviour = []) {
  const dir = F.tmp("gate-cfg");
  const logDir = F.tmp("gate-log");
  GATES.forEach(([mod], i) => {
    const b = behaviour[i] === undefined ? 0 : behaviour[i];
    if (b === "missing") return;
    const rec = `require("fs").writeFileSync(${JSON.stringify(path.join(logDir, `${i}.json`))}, JSON.stringify({ argv: o.argv, cwd: o.cwd }));`;
    const body = b === "norun" ? "module.exports = {};\n"
      : b === "throw" ? `module.exports = { run(o) { ${rec} throw new Error("fixture-gate-throw"); } };\n`
        : `module.exports = { run(o) { ${rec} o.stdout.write("gate-out-${i}\\n"); return ${b}; } };\n`;
    F.write(dir, mod, `"use strict";\n${body}`);
  });
  const called = (i) => {
    const f = path.join(logDir, `${i}.json`);
    return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : null;
  };
  return { dir, called };
}

function stagedRepo(F) {
  const dir = F.repo("gates");
  F.write(dir, "rules/a.md", "a\n");
  F.write(dir, "rules/sub/b.md", "b\n");
  F.write(dir, "hooks/lib/rules-injection-policy.js", "x\n");
  F.write(dir, "tests/t.sh", "t\n");
  F.write(dir, "bin/tool", "x\n");
  F.stage(dir, "rules/a.md", "rules/sub/b.md", "hooks/lib/rules-injection-policy.js", "tests/t.sh", "bin/tool");
  return dir;
}

const markers = (log) => log.filter((r) => r.fd === 2 && /^pre-commit-section: /.test(r.text)).map((r) => r.text.trim().slice(20));

async function runGates(F, repoTop, cfg) {
  const { value, log } = await F.capture(() => F.runCheck("agents-repo-gates", { repoTop, cfgDir: cfg.dir, env: F.cleanEnv() }));
  return { r: value, log };
}

function agentsRepoGates(F) {
  test("all six run in order from the repo top with the bash arguments; rc 0 output is discarded", async () => {
    const dir = stagedRepo(F);
    const cfg = stubCfg(F);
    const { r, log } = await runGates(F, dir, cfg);
    assert.strictEqual(r.verdict, "pass", F.texts(r));
    assert.deepStrictEqual(markers(log), GATES.map((g) => g[1]));
    assert.doesNotMatch(F.texts(r) + log.map((x) => x.text).join(""), /gate-out-/);
    const args = GATES.map((_g, i) => cfg.called(i));
    for (const a of args) assert.strictEqual(fs.realpathSync(a.cwd), fs.realpathSync(dir));
    assert.deepStrictEqual(args[0].argv.slice().sort(), ["--staged", "hooks/lib/rules-injection-policy.js", "rules/a.md", "rules/sub/b.md"].sort());
    assert.strictEqual(args[0].argv[0], "--staged");
    assert.deepStrictEqual(args[1].argv, ["--staged"]);
    assert.deepStrictEqual(args[2].argv.slice(1).sort(), ["bin/tool", "hooks/lib/rules-injection-policy.js"]);
    assert.strictEqual(args[2].argv[0], "--staged");
    assert.deepStrictEqual(args[3].argv, ["--source"]);
    assert.deepStrictEqual(args[4].argv, ["--staged"]);
    assert.deepStrictEqual(args[5].argv, ["--staged"]);
  });
  test("rc 1 and rc 2 block: output, empty line, 'Commit blocked: <what> (checker rc=N).', 'See <doc>.'", async () => {
    for (const rc of [1, 2]) {
      const cfg = stubCfg(F, [0, 0, 0, 0, 0, rc]);
      const { r, log } = await runGates(F, stagedRepo(F), cfg);
      assert.strictEqual(r.verdict, "block");
      const out = r.messages.filter((m) => m.stream === "stdout").map((m) => m.text).join("\n");
      const iOut = out.indexOf("gate-out-5");
      const iBlk = out.indexOf(`Commit blocked: root-name violations (checker rc=${rc}).`);
      const iSee = out.indexOf("See docs/architecture/claude-code/root-names.md.");
      assert.ok(iOut >= 0 && iBlk > iOut && iSee > iBlk, out);
      assert.match(out.slice(iOut, iBlk), /\n\s*\n/, "an empty line precedes the block line");
      assert.strictEqual(markers(log).slice(-1)[0], GATES[5][1]);
    }
    const noDoc = await runGates(F, stagedRepo(F), stubCfg(F, [0, 0, 1]));
    assert.ok(F.messageOf(noDoc.r, "Commit blocked: migration block format violations (checker rc=1)."));
    assert.doesNotMatch(F.texts(noDoc.r), /See \./);
    assert.strictEqual(markers(noDoc.log).slice(-1)[0], GATES[2][1], "no gate runs after a block");
  });
  test("another rc fails closed with 'is not a verdict' on stderr", async () => {
    const { r } = await runGates(F, stagedRepo(F), stubCfg(F, [0, 3]));
    assert.strictEqual(r.verdict, "block");
    const err = r.messages.filter((m) => m.stream === "stderr").map((m) => m.text).join("\n");
    assert.match(err, /gate-out-1/);
    assert.match(err, /pre-commit: \S*check-session-id-ssot\S* rc=3 is not a verdict \(0 clean, 1 or 2 violation\)\./);
    assert.ok(err.includes(FAIL_CLOSED));
  });
  test("a missing module, a module without run, or a throwing run fails closed", async () => {
    for (const b of ["missing", "norun", "throw"]) {
      const { r, log } = await runGates(F, stagedRepo(F), stubCfg(F, [0, 0, 0, 0, b]));
      assert.strictEqual(r.verdict, "block", b);
      const err = r.messages.filter((m) => m.stream === "stderr").map((m) => m.text).join("\n");
      assert.ok(err.includes(FAIL_CLOSED), `${b}: ${err}`);
      if (b !== "throw") assert.match(err, /pre-commit: \S*check-plans-dir-isolation\S* missing or not runnable \(.*\) at .+\./, b);
      assert.strictEqual(markers(log).slice(-1)[0], GATES[4][1], b);
    }
  });
  test("outside the agents repo the gates do not run; only the section marker is written", async () => {
    const cfg = stubCfg(F);
    const { value, log } = await F.runEntry("agents-repo-gates", { repoTop: stagedRepo(F), cfgDir: cfg.dir, env: F.cleanEnv(), isAgentsRepo: false });
    assert.strictEqual(value, 0);
    assert.deepStrictEqual(markers(log), ["agents-repo-gates"]);
    for (let i = 0; i < 6; i += 1) assert.strictEqual(cfg.called(i), null);
  });
}

module.exports = { agentsRepoGates, stubCfg, GATES };

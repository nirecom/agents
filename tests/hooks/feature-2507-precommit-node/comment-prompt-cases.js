"use strict";
// comment-block-size and prompt-extraction part of tests/hooks/feature-2507-precommit-node.js
// (#2507). The comment-block CLI module, the prompt-extraction CLI module and the session marker
// modules are stubbed in a temp cfgDir; expected text is the current hooks/pre-commit wording.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const CB_MODULE = "bin/review-comment-block-size.d/cli.js";
const PE_MODULE = "bin/lib/prompt-extraction/cli.js";

// cliStub(F, dir, rel, rc, out) — a run(o) stub that records its call and returns rc.
function cliStub(F, dir, rel, rc, out) {
  const flag = path.join(dir, `${path.basename(rel)}.called`);
  const body = rc === "throw" ? "throw new Error(\"fixture-cli-throw\");" : `o.stdout.write(${JSON.stringify(out)}); return ${rc};`;
  F.write(dir, rel, `"use strict";\nmodule.exports = { run(o) { require("fs").writeFileSync(${JSON.stringify(flag)}, JSON.stringify(o.argv || [])); ${body} } };\n`);
  return () => fs.existsSync(flag);
}

function stagedRepo(F, { allowlist = false } = {}) {
  const dir = F.repo("cbpe");
  F.write(dir, "a.js", "// c\n");
  F.stage(dir, "a.js");
  if (allowlist) F.write(dir, ".prompt-extraction-allowlist", "");
  return dir;
}
const linesOf = (F, r) => F.texts(r).split("\n");
const errOf = (r) => r.messages.filter((m) => m.stream === "stderr").map((m) => m.text).join("\n");
const outOf = (r) => r.messages.filter((m) => m.stream === "stdout").map((m) => m.text).join("\n");

function commentBlockSize(F) {
  const setup = (rc, out = "", envBody) => {
    const cfgDir = F.tmp("cb-cfg");
    const called = cliStub(F, cfgDir, CB_MODULE, rc, out);
    if (envBody !== undefined) F.write(cfgDir, ".env", envBody);
    return { cfgDir, called };
  };
  const run = (s, env = F.cleanEnv()) => F.runCheck("comment-block-size", { repoTop: stagedRepo(F), cfgDir: s.cfgDir, env });
  test("rc 1 blocks: scanner output, empty line, then the two bash lines on stdout", async () => {
    const r = await run(setup(1, "fixture-cb-report\n"));
    assert.strictEqual(r.verdict, "block");
    const out = outOf(r);
    const i = out.indexOf("fixture-cb-report");
    const j = out.indexOf("Commit blocked: staged code carries over-threshold comment blocks.");
    assert.ok(i >= 0 && j > i, out);
    assert.match(out.slice(i, j), /\n\s*\n/);
    assert.ok(out.includes("Compress them, or see rules/coding/file-split.md (Pattern A)."));
  });
  test("another rc: diagnostic plus scanner output on stderr, the commit continues", async () => {
    const r = await run(setup(3, "fixture-cb-partial\n"));
    assert.notStrictEqual(r.verdict, "block");
    assert.ok(errOf(r).includes("pre-commit: review-comment-block-size rc=3 — comment-block check incomplete (commit continues)"), errOf(r));
    assert.ok(errOf(r).includes("fixture-cb-partial"));
  });
  test("rc 0 with ': SKIPPED' prints the SKIPPED notice; a clean rc 0 prints nothing", async () => {
    const r = await run(setup(0, "scan: SKIPPED (node unavailable)\n"));
    assert.notStrictEqual(r.verdict, "block");
    assert.ok(errOf(r).includes("pre-commit: comment-block size check SKIPPED — scanner did not run (commit continues)"));
    const clean = await run(setup(0, "ok\n"));
    assert.notStrictEqual(clean.verdict, "block");
    assert.strictEqual(F.texts(clean), "");
  });
  test("COMMENT_BLOCK_ENFORCE is read only from <cfgDir>/.env; the ambient value is ignored", async () => {
    const off = setup(1, "x\n", "COMMENT_BLOCK_ENFORCE=off\n");
    const r = await run(off);
    assert.notStrictEqual(r.verdict, "block");
    assert.strictEqual(off.called(), false);
    assert.ok(errOf(r).includes("pre-commit: comment-block size gate disabled by COMMENT_BLOCK_ENFORCE=off"));
    const decoy = F.tmp("cb-decoy");
    F.write(decoy, ".env", "COMMENT_BLOCK_ENFORCE=off\n");
    const ambient = await run(setup(1, "x\n", "COMMENT_BLOCK_ENFORCE=on\n"), F.cleanEnv({ COMMENT_BLOCK_ENFORCE: "off", AGENTS_MAIN_ROOT: decoy }));
    assert.strictEqual(ambient.verdict, "block", "ambient off must not disable the gate");
  });
  test("no CLI module in cfgDir, or not the agents repo: silent pass", async () => {
    const empty = await run({ cfgDir: F.tmp("cb-none") });
    assert.notStrictEqual(empty.verdict, "block");
    assert.strictEqual(F.texts(empty), "");
    const s = setup(1, "x\n");
    const { value, log } = await F.runEntry("comment-block-size", { repoTop: stagedRepo(F), cfgDir: s.cfgDir, env: F.cleanEnv(), isAgentsRepo: false });
    assert.strictEqual(value, 0);
    assert.strictEqual(s.called(), false);
    assert.deepStrictEqual(log.map((x) => x.text), ["pre-commit-section: comment-block-size\n"]);
  });
}

function promptExtraction(F) {
  const setup = (rc, { marker = "none", out = "fixture-pe-report\n" } = {}) => {
    const cfgDir = F.tmp("pe-cfg");
    const called = rc === "missing" ? () => false : cliStub(F, cfgDir, PE_MODULE, rc, out);
    const resolve = marker === "throw" ? "() => { throw new Error(\"x\"); }" : "() => \"fixture-sid\"";
    F.write(cfgDir, "hooks/workflow-state.js", `"use strict";\nmodule.exports = { resolveSessionId: ${resolve} };\n`);
    F.write(cfgDir, "hooks/lib/session-markers.js", `"use strict";\nmodule.exports = { isWorkflowOff: () => ${marker === "off"}, isWorktreeOff: () => false };\n`);
    return { cfgDir, called };
  };
  const run = (s, repoTop = stagedRepo(F, { allowlist: true })) => F.runCheck("prompt-extraction", { repoTop, cfgDir: s.cfgDir, env: F.cleanEnv() });
  test("an off session marker skips the backstop; a marker probe error warns and continues", async () => {
    const off = setup(1, { marker: "off" });
    assert.strictEqual((await run(off)).verdict, "pass");
    assert.strictEqual(off.called(), false);
    const err = setup(0, { marker: "throw" });
    const r = await run(err);
    assert.strictEqual(err.called(), true);
    assert.ok(errOf(r).includes("pre-commit: _session_marker_off rc=3 — prompt-extraction backstop check continues"), errOf(r));
  });
  test("rc 1 blocks on stdout; rc 2 blocks on stderr as misinstalled", async () => {
    const r1 = await run(setup(1));
    assert.strictEqual(r1.verdict, "block");
    const o = outOf(r1);
    assert.ok(o.indexOf("fixture-pe-report") < o.indexOf("Commit blocked: prompt extraction violations in staged files."), o);
    assert.ok(o.includes("Extract the content (rules/prompt.md §1.3 / §1.5), or unstage the file."));
    const r2 = await run(setup(2));
    assert.strictEqual(r2.verdict, "block");
    assert.ok(errOf(r2).includes("Commit blocked: check-prompt-extraction usage error (rc=2)."));
    assert.ok(errOf(r2).includes("The prompt-extraction backstop is misinstalled — fix the invocation before committing."));
  });
  test("a missing CLI module blocks as not found; another rc fails open with the skip line", async () => {
    const gone = await run(setup("missing"));
    assert.strictEqual(gone.verdict, "block");
    assert.ok(errOf(gone).includes("Commit blocked: check-prompt-extraction not found or not executable (rc="), errOf(gone));
    assert.ok(errOf(gone).includes("Expected at: "));
    const r3 = await run(setup(3));
    assert.notStrictEqual(r3.verdict, "block");
    assert.ok(errOf(r3).includes("pre-commit: check-prompt-extraction rc=3 — prompt-extraction backstop skipped"));
  });
  test("no allowlist at the repo top, or not the agents repo even with one: the CLI never runs", async () => {
    const s = setup(1);
    const r = await run(s, stagedRepo(F));
    assert.strictEqual(r.verdict, "pass");
    assert.deepStrictEqual(linesOf(F, r).filter(Boolean), []);
    assert.strictEqual(s.called(), false);
    const { value } = await F.runEntry("prompt-extraction", { repoTop: stagedRepo(F, { allowlist: true }), cfgDir: s.cfgDir, env: F.cleanEnv(), isAgentsRepo: false });
    assert.strictEqual(value, 0);
    assert.strictEqual(s.called(), false);
  });
}

module.exports = { commentBlockSize, promptExtraction };

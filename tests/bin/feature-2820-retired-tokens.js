"use strict";
// Tests: bin/lib/check-migration-blocks.js, bin/lib/check-migration-blocks/retired-tokens.js
// Tags: TL2, bin, migration-blocks, retired-tokens, lint, pre-commit, scope:issue-specific, self-application, real-registry
// #2820 Steps 1-3: a retired token is an error outside its migration's temporary block, and a
// registered block without added / deletion-condition is an error. Every case runs the PR's
// checker as a subprocess on a fixture repo, in --staged and --all alike.
// TL3 gap: pre-commit runs the main checkout's checker, so a real commit is not exercised here;
// the self-application cases at the end and the CI migration-blocks-audit job cover that seam.
const { caseBegin, caseEnd } = require("../lib/harness");
const { after, test } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const F = require("./feature-2820-retired-tokens/fixture");

after(() => F.finish());

function expectBoth(res, rc, label) {
  assert.strictEqual(res.staged.rc, rc, `${label} --staged: ${F.show(res.staged)}`);
  assert.strictEqual(res.all.rc, rc, `${label} --all: ${F.show(res.all)}`);
}

caseBegin("token outside its block fails with id, token, path and line", "bin/lib/check-migration-blocks.js");
test("token outside its block fails with id, token, path and line", () => {
  const dir = F.makeRepo({ "hooks/a.js": "'use strict';\nconst x = OLD_TOKEN;\n", "hooks/b.js": "old_call(1);\n" });
  const res = F.both(dir);
  expectBoth(res, 1, "outside");
  for (const r of [res.staged, res.all]) {
    const line = r.stdout.split("\n").find((l) => /hooks\/a\.js:2\b/.test(l));
    assert.ok(line, `no violation line for hooks/a.js:2: ${F.show(r)}`);
    assert.match(line, new RegExp(F.DEMO_ID));
    assert.match(line, /OLD_TOKEN/);
    assert.match(r.stdout, /hooks\/b\.js:1\b/, `re token not reported: ${F.show(r)}`);
  }
});
caseEnd();

caseBegin("token inside a complete registered block passes", "bin/lib/check-migration-blocks/retired-tokens.js");
test("token inside a complete registered block passes", () => {
  const dir = F.makeRepo({ "hooks/a.js": F.block(["const x = OLD_TOKEN;", "old_call(1);"]) });
  expectBoth(F.both(dir), 0, "inside complete");
});
caseEnd();

caseBegin("token inside another migration's block still fails", "bin/lib/check-migration-blocks/retired-tokens.js");
test("token inside another migration's block still fails", () => {
  const dir = F.makeRepo({ "hooks/a.js": F.block(["const x = OLD_TOKEN;"], { desc: "foo old -> foo new migration" }) });
  expectBoth(F.both(dir), 1, "other block");
});
caseEnd();

caseBegin("registered block without deletion-condition fails", "bin/lib/check-migration-blocks.js");
test("registered block without deletion-condition fails", () => {
  const dir = F.makeRepo({ "hooks/a.js": F.block(["const x = OLD_TOKEN;"], { cond: false }) });
  expectBoth(F.both(dir), 1, "no deletion-condition");
});
caseEnd();

caseBegin("registered block without added fails in --all too", "bin/lib/check-migration-blocks.js");
test("registered block without added fails in --all too", () => {
  const dir = F.makeRepo({ "hooks/a.js": F.block(["const x = OLD_TOKEN;"], { added: false }) });
  expectBoth(F.both(dir), 1, "no added");
});
caseEnd();

caseBegin("unregistered block without fields stays a warning", "bin/lib/check-migration-blocks.js");
test("unregistered block without fields stays a warning", () => {
  const dir = F.makeRepo({ "hooks/c.js": F.block(["const y = 1;"], { desc: "foo old -> foo new migration", added: false, cond: false }) });
  const res = F.both(dir);
  expectBoth(res, 0, "unregistered");
  assert.match(res.staged.stderr, /warning:/, F.show(res.staged));
});
caseEnd();

caseBegin("except with a reason skips the path and prints EXCEPTED", "bin/lib/check-migration-blocks/retired-tokens.js");
test("except with a reason skips the path and prints EXCEPTED", () => {
  const reg = F.demoRegistry([`# except ${F.DEMO_ID} hooks/a.js legacy caller kept`]);
  const dir = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\n" }, { registry: reg });
  const res = F.both(dir);
  expectBoth(res, 0, "excepted");
  for (const r of [res.staged, res.all]) assert.match(r.stdout, /^EXCEPTED hooks\/a\.js: legacy caller kept$/m, F.show(r));
  const other = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\n", "hooks/b.js": "const y = OLD_TOKEN;\n" }, { registry: reg });
  expectBoth(F.both(other), 1, "except covers only its path");
});
caseEnd();

caseBegin("except without a reason is a usage error", "bin/lib/check-migration-blocks/retired-tokens.js");
test("except without a reason is a usage error", () => {
  const reg = F.demoRegistry([`# except ${F.DEMO_ID} hooks/a.js`]);
  const dir = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\n" }, { registry: reg });
  expectBoth(F.both(dir), 2, "except no reason");
});
caseEnd();

caseBegin("malformed registry line is a usage error", "bin/lib/check-migration-blocks/retired-tokens.js");
test("malformed registry line is a usage error", () => {
  for (const bad of [`# bogus ${F.DEMO_ID} x`, `# word ${F.DEMO_ID}`]) {
    const dir = F.makeRepo({ "hooks/a.js": "const x = 1;\n" }, { registry: F.demoRegistry([bad]) });
    const res = F.both(dir);
    expectBoth(res, 2, `malformed '${bad}'`);
    assert.notStrictEqual(res.all.stderr.trim(), "", F.show(res.all));
  }
});
caseEnd();

caseBegin("empty registry flags nothing and does not fall through", "bin/lib/check-migration-blocks/retired-tokens.js");
test("empty registry flags nothing and does not fall through", () => {
  const dir = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\nconst y = PLAN_STAGE_TABLE;\n" }, { registry: F.registry([]) });
  expectBoth(F.both(dir), 0, "empty registry");
});
caseEnd();

caseBegin("registry file itself is not inspected", "bin/lib/check-migration-blocks/retired-tokens.js");
test("registry file itself is not inspected", () => {
  // The demo scope holds bin/**, which holds the registry and its OLD_TOKEN line.
  const dir = F.makeRepo({ "bin/tool.js": "const ok = 1;\n" });
  expectBoth(F.both(dir), 0, "registry self");
});
caseEnd();

caseBegin("word matches on word boundaries only", "bin/lib/check-migration-blocks/retired-tokens.js");
test("word matches on word boundaries only", () => {
  const dir = F.makeRepo({ "hooks/a.js": "const a = OLD_TOKENS;\nconst b = MY_OLD_TOKEN;\nconst c = OLD_TOKEN2;\nnew_old_call(1);\n" });
  expectBoth(F.both(dir), 0, "partial words");
});
caseEnd();

caseBegin("at-glob narrows a word and a re to their range", "bin/lib/check-migration-blocks/retired-tokens.js");
test("at-glob narrows a word and a re to their range", () => {
  const reg = F.demoRegistry([`# word ${F.DEMO_ID} NARROW_TOKEN@hooks/only.js`, `# re ${F.DEMO_ID} \\bnarrow_call\\(@hooks/only.js`]);
  const outside = F.makeRepo({ "hooks/other.js": "const a = NARROW_TOKEN;\nnarrow_call(1);\n" }, { registry: reg });
  expectBoth(F.both(outside), 0, "narrowed out of range");
  const word = F.makeRepo({ "hooks/only.js": "const a = NARROW_TOKEN;\n" }, { registry: reg });
  expectBoth(F.both(word), 1, "narrowed word in range");
  const re = F.makeRepo({ "hooks/only.js": "narrow_call(1);\n" }, { registry: reg });
  expectBoth(F.both(re), 1, "narrowed re in range");
});
caseEnd();

caseBegin("scope globs are anchored to the repo-relative path", "bin/lib/check-migration-blocks/retired-tokens.js");
test("scope globs are anchored to the repo-relative path", () => {
  const dir = F.makeRepo({
    ".claude/worktrees/x/hooks/a.js": "const x = OLD_TOKEN;\n",
    "lib/hooks/a.js": "const x = OLD_TOKEN;\n",
    "xhooks/a.js": "const x = OLD_TOKEN;\n",
  });
  expectBoth(F.both(dir), 0, "nested and prefixed paths");
});
caseEnd();

caseBegin("rules files are inspected by scope", "bin/lib/check-migration-blocks/retired-tokens.js");
test("rules files are inspected by scope", () => {
  const dir = F.makeRepo({ "rules/x.md": "Use OLD_TOKEN here.\n" });
  expectBoth(F.both(dir), 1, "rules/**");
});
caseEnd();

caseBegin("retired-tokens-from overrides the repo registry", "bin/lib/check-migration-blocks.js");
test("retired-tokens-from overrides the repo registry", () => {
  const ext = F.writeOutside("ext-registry.txt", F.registry([`# migration ext-tok ext old -> ext new migration`, "# scope ext-tok hooks/**", "# word ext-tok EXT_TOKEN"]));
  const dir = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\nconst y = EXT_TOKEN;\n" });
  const flag = ["--retired-tokens-from", ext];
  const withFlag = F.both(dir, flag);
  expectBoth(withFlag, 1, "flag registry");
  for (const r of [withFlag.staged, withFlag.all]) {
    assert.match(r.stdout, /EXT_TOKEN/, F.show(r));
    assert.doesNotMatch(r.stdout, /OLD_TOKEN/, `repo registry used despite the flag: ${F.show(r)}`);
  }
  const clean = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\n" });
  expectBoth(F.both(clean, flag), 0, "flag registry lacks OLD_TOKEN");
});
caseEnd();

caseBegin("repo registry wins over the checker's own and staged reads the index", "bin/lib/check-migration-blocks/retired-tokens.js");
test("repo registry wins over the checker's own and staged reads the index", () => {
  // The demo registry lacks PLAN_STAGE_TABLE, which the checker's own registry retires.
  const repo = F.makeRepo({ "hooks/a.js": "const y = PLAN_STAGE_TABLE;\n" });
  expectBoth(F.both(repo), 0, "repo registry chosen");
  const idx = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\n" });
  fs.writeFileSync(path.join(idx, F.REG_REL), F.registry([]));
  const r = F.runStaged(idx);
  assert.strictEqual(r.rc, 1, `--staged must read the staged registry: ${F.show(r)}`);
});
caseEnd();

caseBegin("without a repo registry the checker's own registry applies", "bin/lib/check-migration-blocks/retired-tokens.js");
test("without a repo registry the checker's own registry applies", () => {
  const hit = F.makeRepo({ "hooks/x.js": "const t = PLAN_STAGE_TABLE;\n" }, { registry: null });
  expectBoth(F.both(hit), 1, "own registry word");
  const inBlock = F.makeRepo({ "hooks/lib/m.js": F.block(["const t = PLAN_STAGE_TABLE;"], { desc: F.REAL_DESC }) }, { registry: null });
  expectBoth(F.both(inBlock), 0, "own registry block");
  const narrowed = F.makeRepo({ "hooks/lib/plan-link.js": "const STAGES = [];\n", "hooks/other.js": "const STAGES = [];\n" }, { registry: null });
  const res = F.both(narrowed);
  expectBoth(res, 1, "STAGES narrowed to plan-link.js");
  assert.doesNotMatch(res.all.stdout, /hooks\/other\.js/, F.show(res.all));
});
caseEnd();

caseBegin("B words and out-of-scope trees pass under the checker's own registry", "bin/lib/check-migration-blocks/retired-tokens.js");
test("B words and out-of-scope trees pass under the checker's own registry", () => {
  const dir = F.makeRepo({
    "bin/sync.sh": "git ls-files --stage -- x\n",
    "skills/issue-close-stage/SKILL.md": "Run /issue-close-stage after merge.\n",
    "hooks/lib/jev/call.js": "run(\"jev-judge --stage outline\");\nconst ticket = { stage: \"outline\" };\n",
    "tests/bin/x.js": "const t = PLAN_STAGE_TABLE;\n",
    "history.md": "PLAN_STAGE_TABLE was renamed.\n",
    "CHANGELOG.md": "PLAN_STAGE_TABLE was renamed.\n",
    "docs/history.md": "PLAN_STAGE_TABLE was renamed.\n",
  }, { registry: null });
  expectBoth(F.both(dir), 0, "B words and out-of-scope");
});
caseEnd();

caseBegin("lines just outside the block boundary are outside it", "bin/lib/check-migration-blocks/retired-tokens.js");
test("lines just outside the block boundary are outside it", () => {
  const before = F.makeRepo({ "hooks/a.js": "const x = OLD_TOKEN;\n" + F.block(["const y = 1;"]) });
  const rb = F.both(before);
  expectBoth(rb, 1, "line right before BEGIN");
  for (const r of [rb.staged, rb.all]) assert.match(r.stdout, /hooks\/a\.js:1\b/, F.show(r));
  const body = F.block(["const y = OLD_TOKEN;"]);
  const endLine = body.split("\n").length - 1;
  const afterEnd = F.makeRepo({ "hooks/a.js": body + "old_call(2);\n" });
  const ra = F.both(afterEnd);
  expectBoth(ra, 1, "line right after END");
  for (const r of [ra.staged, ra.all]) {
    assert.match(r.stdout, new RegExp(`hooks/a\\.js:${endLine + 1}\\b`), F.show(r));
    assert.doesNotMatch(r.stdout, new RegExp(`hooks/a\\.js:${endLine - 1}\\b`), `the in-block line is not a violation: ${F.show(r)}`);
  }
});
caseEnd();

// The checker's own registry (no repo registry): its re lines, positive and negative per shape.
function ownRegistry(files) {
  return F.both(F.makeRepo(files, { registry: null }));
}
function expectHit(files, rel, label) {
  const res = ownRegistry(files);
  expectBoth(res, 1, label);
  for (const r of [res.staged, res.all]) assert.match(r.stdout, new RegExp(`${rel.replace(/[.]/g, "\\.")}:\\d+.*stage-to-step|stage-to-step.*${rel.replace(/[.]/g, "\\.")}:\\d+`), F.show(r));
}

caseBegin("own registry re: --stage narrowed to the CLIs and their consumers", "bin/lib/check-migration-blocks/retired-tokens.js");
test("own registry re: --stage narrowed to the CLIs and their consumers", () => {
  for (const rel of ["bin/plan-artifact-path", "bin/plan-link", "bin/check-glossary-drift", "hooks/lib/plan-link.js", "hooks/confirm-checkpoint.js"]) {
    expectHit({ [rel]: "if (a === \"--stage\") v = next();\n" }, rel, `--stage in ${rel}`);
  }
  expectBoth(ownRegistry({ "hooks/other.js": "if (a === \"--stage\") v = next();\n" }), 0, "--stage outside the narrowed range");
  expectBoth(ownRegistry({ "bin/plan-link": "if (a === \"--stages\" || a === \"--stage-dir\") v = next();\nif (a === \"--step\") v = next();\n" }), 0, "--stages, --stage-dir, --step");
});
caseEnd();

caseBegin("own registry re: a CLI called with --stage anywhere in scope", "bin/lib/check-migration-blocks/retired-tokens.js");
test("own registry re: a CLI called with --stage anywhere in scope", () => {
  expectHit({ "skills/x/SKILL.md": "Run `bin/plan-link --session S --stage outline`.\n" }, "skills/x/SKILL.md", "plan-link --stage");
  expectHit({ "docs/architecture/x.md": "node bin/check-glossary-drift --stage tests --record\n" }, "docs/architecture/x.md", "check-glossary-drift --stage");
  expectHit({ "agents/x.md": "plan-artifact-path --stage intent\n" }, "agents/x.md", "plan-artifact-path --stage");
  expectBoth(ownRegistry({
    "skills/x/SKILL.md": "Run `bin/plan-link --session S --step outline`.\nRun jev-judge --stage outline.\n",
    "agents/x.md": "plan-artifact-path --step clarify_intent\nplan-link\n--stage on its own line\n",
  }), 0, "--step callers, other tools, --stage on another line");
});
caseEnd();

caseBegin("own registry re: stage= discriminator in the sentinel owners", "bin/lib/check-migration-blocks/retired-tokens.js");
test("own registry re: stage= discriminator in the sentinel owners", () => {
  expectHit({ "hooks/lib/sentinel-patterns.js": "const D = /(?:op|cat|stage)=[a-z_-]+/;\n" }, "hooks/lib/sentinel-patterns.js", "|stage)=");
  expectHit({ "hooks/workflow-state/glossary-check/record.js": "const hint = \" stage=\" + s;\n" }, "hooks/workflow-state/glossary-check/record.js", "stage= in record.js");
  expectHit({ "hooks/workflow-mark/glossary-accept-handler.js": "const FORM = \"[stage=<stage>]\";\n" }, "hooks/workflow-mark/glossary-accept-handler.js", "stage= in the accept handler");
  expectBoth(ownRegistry({
    "hooks/other.js": "const hint = \" stage=\" + s;\n",
    "hooks/lib/sentinel-patterns.js": "const D = /(?:op|cat|step)=[a-z_-]+/;\nconst backstage= 1;\n",
  }), 0, "stage= elsewhere, step=, backstage=");
});
caseEnd();

caseBegin("own registry re: legacy literals in the consumer files", "bin/lib/check-migration-blocks/retired-tokens.js");
test("own registry re: legacy literals in the consumer files", () => {
  expectHit({ "hooks/lib/plan-confirm-flag.js": "if (s === \"tests\") return 1;\n" }, "hooks/lib/plan-confirm-flag.js", "=== tests");
  expectHit({ "hooks/workflow-state/plan-skip-allowance.js": "switch (s) { case 'docs': return 1; }\n" }, "hooks/workflow-state/plan-skip-allowance.js", "case docs");
  expectHit({ "hooks/lib/presentation-receipt.js": "if (s !== \"code\") return 1;\n" }, "hooks/lib/presentation-receipt.js", "!== code");
  expectHit({ "hooks/workflow-state/glossary-check/scope.js": "const T = { tests: \"review_tests\" };\n" }, "hooks/workflow-state/glossary-check/scope.js", "old table row");
  expectBoth(ownRegistry({
    "hooks/other.js": "if (s === \"tests\") return 1;\n",
    "hooks/lib/plan-confirm-flag.js": "if (s === \"outline\" || s === \"intent\" || s === \"detail\") return 1;\nif (p === \"tests/x\") return 2;\nconst t = \"tests\";\n",
  }), 0, "literals outside consumers, plan artifact names, non-comparison uses");
});
caseEnd();

// Self-application: the PR's checker over this checkout. pre-commit runs the main checkout's checker,
// so these cases (with the CI migration-blocks-audit job) hold this PR to its own registry.
const MODULE = path.join(F.ROOT, "bin", "lib", "check-migration-blocks", "retired-tokens.js");
const REGISTRY = path.join(F.ROOT, F.REG_REL);

caseBegin("registry declares the stage-to-step migration", "bin/lib/check-migration-blocks/retired-tokens.js");
test("registry declares the stage-to-step migration", () => {
  // Without this, an absent registry would make the scan below pass for nothing.
  assert.ok(fs.existsSync(REGISTRY), `registry missing: ${REGISTRY}`);
  const text = fs.readFileSync(REGISTRY, "utf8");
  assert.match(text, /^# migration stage-to-step workflow stage -> workflow step migration$/m);
  const { parseRegistry } = require(MODULE);
  assert.strictEqual(typeof parseRegistry, "function");
  parseRegistry(text);
});
caseEnd();

caseBegin("this checkout has no retired-token violation", "bin/lib/check-migration-blocks.js");
test("this checkout has no retired-token violation", { timeout: 120000 }, () => {
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  const done = spawnSync(process.execPath, [F.CHECKER, "--all", F.ROOT], { cwd: os.tmpdir(), env, encoding: "utf8", timeout: 110000 });
  assert.ifError(done.error);
  const hits = (done.stdout || "").split("\n").filter((l) => l.includes("stage-to-step"));
  assert.deepStrictEqual(hits, [], `retired-token violations:\n${hits.join("\n")}`);
  assert.strictEqual(done.status, 0, `stdout=${done.stdout}\nstderr=${done.stderr}`);
});
caseEnd();

"use strict";
// lang-check: ignore — a CJK fixture string is staged on purpose.
// Merge narrowing of the file-reading checks, part of tests/hooks/feature-2507-precommit-node.js
// (#2507). During a merge the orchestrator hands a mergeNarrowable check only the staged files the
// user changed; files whose staged state equals MERGE_HEAD (merge-incoming) are not the user's to
// fix. code-lang, prompt-extraction and comment-block-size scanned the whole index on their own
// and so still blocked on merge-incoming files. One shared merging repo carries an incoming and a
// user-made violation for each check; the real checker modules run behind a temp cfgDir.
const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const CJK = "あ";
const FENCE = "# Rule\n\n~~~\nstep one\nstep two\nstep three\nstep four\n~~~\n";
const commentRun = (n) => `${Array.from({ length: n }, (_, i) => `// note ${i + 1}`).join("\n")}\nmodule.exports = 1;\n`;

// The incoming (in-*) and user-made (my-*) file of each check.
const PAIRS = {
  "code-lang": { incoming: "in-lang.txt", mine: "my-lang.txt" },
  "sh-exec-bit": { incoming: "in-x.sh", mine: "my-x.sh" },
  "prompt-extraction": { incoming: "rules/in-pe.md", mine: "rules/my-pe.md" },
  "comment-block-size": { incoming: "grow.js", mine: "my-cb.js" },
};

// The user's staged files: "dirty" carries a violation per check, "clean" breaks no check, so in the
// clean repo every violation sits in a merge-incoming file.
const MINE = {
  dirty: {
    "my-lang.txt": `mine ${CJK}\n`,
    "my-x.sh": "echo mine\n",
    "rules/my-pe.md": FENCE,
    "my-cb.js": commentRun(5),
  },
  clean: {
    "my-lang.txt": "mine plain\n",
    "my-x.sh": "echo mine\n",
    "rules/my-pe.md": "# Rule\n\nplain prose only.\n",
    "my-cb.js": commentRun(2),
  },
};

function buildRepo(F, variant) {
  const dir = F.repo(`merge-narrow-${variant}`);
  F.write(dir, "grow.js", commentRun(2));
  F.stage(dir, "grow.js");
  F.git(dir, ["commit", "-q", "-m", "base"]);
  F.git(dir, ["checkout", "-q", "-b", "topic"]);
  F.write(dir, "in-lang.txt", `incoming ${CJK}\n`);
  F.write(dir, "in-x.sh", "echo incoming\n");
  F.write(dir, "rules/in-pe.md", FENCE);
  F.write(dir, "grow.js", commentRun(5));
  F.stage(dir, "in-lang.txt", "in-x.sh", "rules/in-pe.md", "grow.js");
  F.git(dir, ["update-index", "--chmod=-x", "in-x.sh"]);
  F.git(dir, ["commit", "-q", "-m", "topic"]);
  F.git(dir, ["checkout", "-q", "main"]);
  F.write(dir, "seed.txt", "seed\nmain side\n");
  F.stage(dir, "seed.txt");
  F.git(dir, ["commit", "-q", "-m", "main side"]);
  F.git(dir, ["merge", "--no-commit", "--no-ff", "-q", "topic"]);
  for (const [rel, body] of Object.entries(MINE[variant])) F.write(dir, rel, body);
  F.stage(dir, ...Object.keys(MINE[variant]));
  F.git(dir, ["update-index", `--chmod=${variant === "dirty" ? "-x" : "+x"}`, "my-x.sh"]);
  F.write(dir, ".prompt-extraction-allowlist", "");
  return dir;
}

// cfgDir whose checker modules are the real ones, a session resolver that finds no session, and a
// comment-block threshold of 3 lines.
function buildCfg(F) {
  const cfg = F.tmp("merge-narrow-cfg");
  const reexport = (rel) => F.write(cfg, rel, `"use strict";\nmodule.exports = require(${JSON.stringify(path.join(F.REPO, rel))});\n`);
  reexport("hooks/lib/lint-commit-lang.js");
  reexport("bin/lib/prompt-extraction/cli.js");
  reexport("bin/review-comment-block-size.d/cli.js");
  F.write(cfg, "hooks/workflow-state.js", "\"use strict\";\nmodule.exports = { resolveSessionId: () => null };\n");
  F.write(cfg, "hooks/lib/session-markers.js", "\"use strict\";\nmodule.exports = { isWorkflowOff: () => false, isWorktreeOff: () => false };\n");
  F.write(cfg, ".env", "COMMENT_BLOCK_MAX_LINES=3\n");
  return cfg;
}

// One merging repo per fixture surface and variant, built on first use inside a test.
const SHARED = new WeakMap();
function sharedFor(F, variant) {
  if (!SHARED.has(F)) SHARED.set(F, {});
  const byVariant = SHARED.get(F);
  if (!byVariant[variant]) {
    let memo = null;
    byVariant[variant] = () => {
      if (!memo) memo = { repoTop: buildRepo(F, variant), cfgDir: buildCfg(F) };
      return memo;
    };
  }
  return byVariant[variant];
}

// The registry entry <name> through orchestrator.run with a real merge state (merging) or with
// not-merging, from the repo top with CODE_LANG=english; resolves to { rc, text, merge }.
async function runNarrowed(F, shared, name, { merging }) {
  const { repoTop, cfgDir } = shared();
  const env = F.envWith({ CODE_LANG: "english", CODE_LANG_EXCLUDE: undefined });
  const saved = { cwd: process.cwd(), CODE_LANG: process.env.CODE_LANG, CODE_LANG_EXCLUDE: process.env.CODE_LANG_EXCLUDE };
  process.chdir(repoTop);
  process.env.CODE_LANG = "english";
  delete process.env.CODE_LANG_EXCLUDE;
  try {
    const entry = F.fresh("registry.js").CHECKS.find((c) => c.name === name);
    assert.ok(entry && entry.mergeNarrowable, `${name}: a mergeNarrowable registry entry`);
    const snapshot = await F.fresh("snapshot.js").createSnapshot({ repoTop, env });
    const files = await snapshot.files();
    const merge = merging ? require(path.join(F.REPO, "hooks", "lib", "merge-incoming.js")).detectMergeIncoming(repoTop, files) : { state: "not-merging" };
    const context = { repoTop, cfgDir, env, isTTY: false, isAgentsRepo: true, merge, visibility: { kill() {} } };
    const orch = F.fresh("orchestrator.js");
    const check = require(path.join(F.PCD, "checks", `${name}.js`));
    const { value, log } = await F.capture(() => orch.run({ entries: [entry], context, snapshot, loadCheck: () => check }));
    return { rc: value, text: log.map((x) => x.text).join(""), merge };
  } finally {
    process.chdir(saved.cwd);
    for (const k of ["CODE_LANG", "CODE_LANG_EXCLUDE"]) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}

function mergeNarrowCases(F, name) {
  const shared = sharedFor(F, "dirty");
  const clean = sharedFor(F, "clean");
  const { incoming, mine } = PAIRS[name];
  test(`${name}: the fixture is merging, ${incoming} is merge-incoming, ${mine} is the user's`, async () => {
    const { merge } = await runNarrowed(F, shared, name, { merging: true });
    assert.strictEqual(merge.state, "merging", JSON.stringify(merge));
    assert.ok(merge.paths.has(incoming), `${incoming} in merge.paths`);
    assert.ok(!merge.paths.has(mine), `${mine} not in merge.paths`);
  });
  test(`${name}: during a merge the user's ${mine} blocks and the merge-incoming ${incoming} is not reported`, async () => {
    const r = await runNarrowed(F, shared, name, { merging: true });
    assert.strictEqual(r.rc, 1, `the user's violation blocks:\n${r.text}`);
    assert.ok(r.text.includes(mine), `${mine} reported:\n${r.text}`);
    assert.ok(!r.text.includes(incoming), `merge-incoming ${incoming} must not be reported:\n${r.text}`);
  });
  test(`${name}: outside a merge both ${incoming} and ${mine} are reported`, async () => {
    const r = await runNarrowed(F, shared, name, { merging: false });
    assert.strictEqual(r.rc, 1, r.text);
    assert.ok(r.text.includes(mine), `${mine} reported:\n${r.text}`);
    assert.ok(r.text.includes(incoming), `${incoming} reported:\n${r.text}`);
  });
  test(`${name}: during a merge whose only violation is the merge-incoming ${incoming}, the check passes`, async () => {
    const r = await runNarrowed(F, clean, name, { merging: true });
    assert.strictEqual(r.merge.state, "merging", JSON.stringify(r.merge));
    assert.ok(r.merge.paths.has(incoming) && !r.merge.paths.has(mine), `${incoming} incoming, ${mine} the user's`);
    assert.strictEqual(r.rc, 0, `the commit is not blocked:\n${r.text}`);
    assert.ok(!r.text.includes(incoming), `merge-incoming ${incoming} must not be reported:\n${r.text}`);
    assert.ok(!r.text.includes("Commit blocked"), `no block message:\n${r.text}`);
  });
  test(`${name}: outside a merge the same clean-user fixture blocks on ${incoming} alone`, async () => {
    const r = await runNarrowed(F, clean, name, { merging: false });
    assert.strictEqual(r.rc, 1, r.text);
    assert.ok(r.text.includes(incoming), `${incoming} reported:\n${r.text}`);
    assert.ok(!r.text.includes(mine), `the clean ${mine} is not reported:\n${r.text}`);
  });
}

module.exports = { mergeNarrowCases };

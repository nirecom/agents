"use strict";
// Tests: bin/lib/eslint-node-scripts.js
// Tags: TL2, bin, eslint, lint, shebang, glob-escape, node-scripts, fixtures, scope:issue-specific
// #2739: eslint.config.js lists the extensionless node-shebang scripts of hooks/bin/tests as
// escaped glob strings. Assumed interface: module.exports = { nodeShebangGlobs } where
// nodeShebangGlobs(root, dirs) returns "/"-separated root-relative paths with every glob special
// character (*?[]{}()!+@\) backslash-escaped; node_modules and dot-directories are not entered.
// The module needs only Node built-ins, so this test runs without ESLint installed.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const MODULE = path.join(REPO, "bin", "lib", "eslint-node-scripts.js");
const DIRS = ["hooks", "bin", "tests"];
const NODE_SHEBANG = /^#!.*\bnode\b/;

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2739-node-scripts-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

// Loaded per test, so a missing module fails each test with its own message.
const load = () => require(MODULE).nodeShebangGlobs;
const escapeGlob = (p) => p.replace(/[*?[\]{}()!+@\\]/g, (c) => `\\${c}`);

function put(root, rel, body) {
  const file = path.join(root, ...rel.split("/"));
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
}

caseBegin("collects-only-extensionless-node-shebang-files", "bin/lib/eslint-node-scripts.js");
test("fixture tree: node-shebang extensionless files are returned, everything else is not", () => {
  const root = path.join(TMP, "tree");
  const included = {
    "bin/node-tool": "#!/usr/bin/env node\nconsole.log(1);\n",
    "hooks/sub/deep-node": "#!/usr/bin/node\nmodule.exports = 1;\n",
    "tests/runner": "#!/usr/bin/env -S node --no-warnings\n",
  };
  const excluded = {
    "bin/bash-tool": "#!/bin/bash\necho node\n",
    "bin/env-bash": "#!/usr/bin/env bash\n# node is mentioned here\n",
    "bin/plain": "node without a shebang\n",
    "bin/empty": "",
    "bin/second-line": "\n#!/usr/bin/env node\n",
    "bin/nodejs-word": "#!/usr/bin/env nodejs\n",
    "bin/script.js": "#!/usr/bin/env node\n",
    "bin/script.cjs": "#!/usr/bin/env node\n",
    "bin/node_modules/pkg/cli": "#!/usr/bin/env node\n",
    "hooks/.hidden/tool": "#!/usr/bin/env node\n",
    "tests/.cache/deep/tool": "#!/usr/bin/env node\n",
    "other/node-tool": "#!/usr/bin/env node\n",
  };
  for (const [rel, body] of Object.entries({ ...included, ...excluded })) put(root, rel, body);
  fs.mkdirSync(path.join(root, "bin", "extensionless-dir"), { recursive: true });

  const got = load()(root, DIRS);
  assert.ok(Array.isArray(got), "nodeShebangGlobs returns an array");
  assert.deepStrictEqual([...got].sort(), Object.keys(included).sort());
});
test("every returned entry is a forward-slash root-relative path", () => {
  const root = path.join(TMP, "tree");
  for (const entry of load()(root, DIRS)) {
    assert.ok(!entry.includes("\\"), `no backslash separator: ${entry}`);
    assert.ok(!path.isAbsolute(entry) && !entry.startsWith("/"), `relative: ${entry}`);
  }
});
test("only the listed dirs are scanned", () => {
  const root = path.join(TMP, "tree");
  assert.deepStrictEqual(load()(root, ["bin"]), ["bin/node-tool"]);
});
test("a second call over the same tree returns the same set", () => {
  const root = path.join(TMP, "tree");
  const fn = load();
  assert.deepStrictEqual([...fn(root, DIRS)].sort(), [...fn(root, DIRS)].sort());
});
caseEnd();

caseBegin("escapes-glob-special-characters", "bin/lib/eslint-node-scripts.js");
test("names with glob special characters come back escaped; plain names stay as they are", () => {
  const root = path.join(TMP, "special");
  const names = ["a[b]{c}(d)!e+f@g", "plain-name"];
  // * ? and \ cannot appear in a Windows file name.
  if (process.platform !== "win32") names.push("s*t?r", "back\\slash");
  for (const name of names) put(root, `bin/${name}`, "#!/usr/bin/env node\n");

  const got = [...load()(root, DIRS)].sort();
  const want = names.map((n) => escapeGlob(`bin/${n}`)).sort();
  assert.deepStrictEqual(got, want);
  assert.ok(got.includes("bin/a\\[b\\]\\{c\\}\\(d\\)\\!e\\+f\\@g"), "literal spelling of the escaped name");
  assert.ok(got.includes("bin/plain-name"), "a name without special characters is unchanged");
});
caseEnd();

caseBegin("matches-the-tracked-repo-scripts", "bin/lib/eslint-node-scripts.js");
// Independent count: tracked, regular (not symlink), extensionless, outside node_modules and
// dot-dirs (the scan never enters them), first line of the first 128 bytes classified.
function trackedScripts() {
  const done = spawnSync("git", ["-C", REPO, "ls-files", "-s", "-z", ...DIRS], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  assert.strictEqual(done.status, 0, `git ls-files failed: ${done.stderr}`);
  const node = [];
  const bash = [];
  for (const rec of done.stdout.split("\0")) {
    const m = /^(\d+) [0-9a-f]+ \d+\t(.+)$/.exec(rec);
    if (!m || m[1] === "120000") continue;
    const rel = m[2];
    const parts = rel.split("/");
    if (parts.slice(0, -1).some((p) => p === "node_modules" || p.startsWith("."))) continue;
    if (path.extname(parts[parts.length - 1]) !== "") continue;
    let head;
    try {
      const fd = fs.openSync(path.join(REPO, rel), "r");
      const buf = Buffer.alloc(128);
      const n = fs.readSync(fd, buf, 0, 128, 0);
      fs.closeSync(fd);
      head = buf.subarray(0, n).toString("utf8").split(/\r?\n/)[0];
    } catch {
      continue;
    }
    if (NODE_SHEBANG.test(head)) node.push(rel);
    else if (/^#!.*\b(ba)?sh\b/.test(head)) bash.push(rel);
  }
  return { node, bash };
}
test("every tracked node-shebang script is returned and no bash-shebang script is", () => {
  const { node, bash } = trackedScripts();
  assert.ok(node.length > 0, "premise: the repo tracks extensionless node scripts");
  assert.ok(bash.length > 0, "premise: the repo tracks extensionless bash scripts");
  const got = new Set(load()(REPO, DIRS));
  const missing = node.filter((rel) => !got.has(escapeGlob(rel)));
  assert.deepStrictEqual(missing, [], "tracked node-shebang scripts missing from nodeShebangGlobs");
  const leaked = bash.filter((rel) => got.has(escapeGlob(rel)));
  assert.deepStrictEqual(leaked, [], "bash-shebang scripts must not be returned");
});
caseEnd();

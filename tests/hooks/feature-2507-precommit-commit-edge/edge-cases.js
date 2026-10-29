"use strict";
// lang-check: ignore — a CJK fixture string is staged on purpose.
// Cases 20-25 of tests/hooks/feature-2507-precommit-commit-edge.js (#2507): node absent from
// PATH, the warn-only auto-block without a TTY, an initial commit, binary and empty files, a
// merge commit, a new test missing a frontmatter line, `git commit <paths>` over git's temporary
// index, the .env-over-ambient
// precedence of COMMENT_BLOCK_ENFORCE, and a merge whose only violation is merge-incoming. No case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { AGENTS_SEQUENCE, HARD_TERM, WARN_TERM, show } = require("../feature-2507-precommit-node/commit-template");

const exe = process.platform === "win32" ? ["node.exe", "node"] : ["node"];
// pathWithoutNode() — PATH with every directory that holds a node executable removed.
function pathWithoutNode() {
  const sep = path.delimiter;
  return (process.env.PATH || "").split(sep).filter((d) => d && !exe.some((n) => fs.existsSync(path.join(d, n)))).join(sep);
}

function nodeMissing(X) {
  test("node absent from PATH: the hook refuses the commit and names node as the reason", () => {
    const hook = X.agents("no-node-hook");
    const dir = X.foreign("no-node", hook);
    X.write(dir, "app.txt", "x\n");
    X.stage(dir, ["app.txt"]);
    const env = { PATH: pathWithoutNode() };
    if (process.platform === "win32") env.Path = undefined;
    const r = X.commit(dir, { hookRepo: hook, env });
    assert.notStrictEqual(r.status, 0, `the commit must be refused without node\n${show(r)}`);
    assert.strictEqual(X.headCount(dir), 1);
    assert.match(r.stderr, /\bnode\b/i, show(r));
  });
}

function warnNoTty(X) {
  test("a warn-only hit with no TTY is auto-blocked with the bash wording", () => {
    const dir = X.agents("warn-notty");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    X.write(dir, "soft.txt", `value ${WARN_TERM}\n`);
    X.stage(dir, ["soft.txt"]);
    const r = X.commit(dir, { timeout: 60000 });
    assert.ok(!r.error, `the commit did not finish (a /dev/tty prompt may be waiting)\n${show(r)}`);
    assert.notStrictEqual(r.status, 0, show(r));
    assert.ok(r.stderr.includes("Commit blocked: warn-only patterns detected (no TTY available — auto-blocked)."), show(r));
    assert.ok(r.stderr.includes("Re-run interactively or add an exception to .private-info-allowlist."), show(r));
    assert.strictEqual(r.markers[r.markers.length - 1], "outbound-scan");
  });
}

function initialCommit(X) {
  test("an initial commit: outbound-scan scans nothing", () => {
    const hook = X.agents("initial-hook");
    const dir = X.foreign("initial", hook, { seed: false });
    X.write(dir, "leak.txt", `value ${HARD_TERM}\n`);
    X.stage(dir, ["leak.txt"]);
    const r = X.commit(dir, { hookRepo: hook });
    assert.strictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 1);
    assert.strictEqual(r.markers[r.markers.length - 1], "outbound-scan");
  });
  test("an initial commit: env-file-block still refuses a staged .env", () => {
    const hook = X.agents("initial-env-hook");
    const dir = X.foreign("initial-env", hook, { seed: false });
    X.write(dir, "sub/.env", "K=v\n");
    X.stage(dir, ["sub/.env"], { force: true });
    const r = X.commit(dir, { hookRepo: hook });
    assert.notStrictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 0);
    assert.ok(r.stderr.includes("pre-commit: .env file(s) staged for commit:"), show(r));
    assert.strictEqual(r.markers[r.markers.length - 1], "env-file-block");
  });
}

function binaryAndEmpty(X) {
  test("a binary (NUL) file and an empty file are not scanned", () => {
    const dir = X.agents("binary-empty");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    fs.writeFileSync(path.join(dir, "blob.dat"), Buffer.concat([Buffer.from(`${HARD_TERM}\n`), Buffer.from([0, 1, 2, 0]), Buffer.from(`${HARD_TERM}\n`)]));
    X.write(dir, "empty.txt", "");
    X.stage(dir, ["blob.dat", "empty.txt"]);
    const r = X.commit(dir);
    assert.strictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 2);
    assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE);
  });
}

// merging(X, name, rel, body, exec) — an agents repo stopped inside `git merge --no-commit` of a
// side branch that adds <rel>; both parents diverge so the merge is a real two-parent commit.
function merging(X, name, rel, body, exec) {
  const dir = X.agents(name);
  X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
  const quiet = ["-c", "core.hooksPath=/dev/null"];
  X.git(dir, ["switch", "-q", "-c", "side"]);
  X.write(dir, rel, body);
  X.stage(dir, [rel], { exec });
  X.git(dir, [...quiet, "commit", "-q", "-m", "side"]);
  X.git(dir, ["switch", "-q", "main"]);
  X.write(dir, "main-only.txt", "m\n");
  X.stage(dir, ["main-only.txt"]);
  X.git(dir, [...quiet, "commit", "-q", "-m", "main"]);
  X.git(dir, [...quiet, "merge", "-q", "--no-commit", "--no-ff", "side"]);
  return dir;
}

function mergeNarrowing(X) {
  test("merge: a file identical to MERGE_HEAD leaves the quality checks (sh-exec-bit does not stop it)", () => {
    const dir = merging(X, "merge-quality", "incoming.sh", "#!/bin/bash\necho x\n", false);
    const r = X.commit(dir, { args: ["--no-edit"] });
    assert.strictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 4);
    assert.ok(!r.stderr.includes(".sh files lacking execute permission"), show(r));
  });
  test("merge: a file identical to MERGE_HEAD is still scanned by outbound-scan", () => {
    const dir = merging(X, "merge-scan", "incoming.txt", `value ${HARD_TERM}\n`, undefined);
    const r = X.commit(dir, { args: ["--no-edit"] });
    assert.notStrictEqual(r.status, 0, show(r));
    assert.ok(r.stderr.includes("Commit blocked: private information detected in staged files."), show(r));
    assert.strictEqual(r.markers[r.markers.length - 1], "outbound-scan");
  });
  test("merge: a file changed and re-staged during the merge stays in the quality checks and blocks", () => {
    const dir = merging(X, "merge-edited", "incoming.sh", "#!/bin/bash\necho x\n", false);
    X.write(dir, "incoming.sh", "#!/bin/bash\necho edited-during-merge\n");
    X.stage(dir, ["incoming.sh"], { exec: false });
    const r = X.commit(dir, { args: ["--no-edit"] });
    assert.notStrictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 2, "no merge commit was made (template and main only)");
    assert.ok(r.stderr.includes("pre-commit: .sh files lacking execute permission:"), show(r));
    assert.ok(r.stderr.includes("incoming.sh"), show(r));
    assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE.slice(0, AGENTS_SEQUENCE.indexOf("sh-exec-bit") + 1));
  });
}

// New JS tests each missing one frontmatter line; the rest of the file is valid. One agents copy
// serves both commits: the first file leaves the index before the second is staged.
const FM_BODY = ["const { caseBegin, caseEnd } = require(\"../lib/harness\");", "const { test } = require(\"node:test\");",
  "caseBegin(\"one\", \"hooks/workflow-state.js\");", "test(\"fixture case\", () => {});", "caseEnd();", ""];
const FM_CASES = [
  ["no # Tests: line", "tests/hooks/fm-no-tests.js", ["\"use strict\";", "// Tags: TL1, fixture, scope:issue-specific", ...FM_BODY],
    "MISSING_TESTS_HEADER: tests/hooks/fm-no-tests.js"],
  ["no # Tags: line", "tests/hooks/fm-no-tags.js", ["\"use strict\";", "// Tests: hooks/workflow-state.js", ...FM_BODY],
    "MISSING_SCOPE_TAG: tests/hooks/fm-no-tags.js (no # Tags: line)"],
];

function frontmatterMissing(X) {
  test("a new test missing its Tests: or Tags: line is refused at tests-frontmatter with the bash wording", () => {
    const dir = X.agents("fm-missing");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    for (const [label, rel, lines, code] of FM_CASES) {
      X.write(dir, rel, lines.join("\n"));
      X.stage(dir, [rel]);
      const r = X.commit(dir);
      assert.notStrictEqual(r.status, 0, `${label}\n${show(r)}`);
      assert.strictEqual(X.headCount(dir), 1, `${label}: no commit was made`);
      for (const w of [code, "Commit blocked: staged test file(s) fail frontmatter validation.",
        "Each file must have '# Tests: <path>' (comma-separated tokens) and '# Tags: ... scope:...'."]) {
        assert.ok(r.stderr.includes(w), `${label}: missing ${JSON.stringify(w)}\n${show(r)}`);
      }
      assert.deepStrictEqual(r.markers, AGENTS_SEQUENCE.slice(0, AGENTS_SEQUENCE.indexOf("tests-frontmatter") + 1), label);
      X.git(dir, ["rm", "-q", "--cached", "--", rel]);
    }
  });
}

function pathCommit(X) {
  test("`git commit <paths>` is judged on git's temporary index, not the real one", () => {
    const dir = X.agents("path-commit");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    X.write(dir, "a.txt", `value ${HARD_TERM}\n`);
    const r = X.commit(dir, { args: ["--", "a.txt"] });
    assert.notStrictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 1);
    assert.ok(r.stderr.includes("Commit blocked: private information detected in staged files."), show(r));
    assert.ok(r.stderr.includes("a.txt"), show(r));
  });
  test("`git commit <paths>` with a clean path commits while the real index holds an unrelated staged leak", () => {
    const dir = X.agents("path-commit-clean");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    X.write(dir, "leak.txt", `value ${HARD_TERM}\n`);
    X.stage(dir, ["leak.txt"]);
    X.write(dir, "a.txt", "clean change\n");
    const r = X.commit(dir, { args: ["--", "a.txt"] });
    assert.strictEqual(r.status, 0, show(r));
    assert.strictEqual(X.headCount(dir), 2);
  });
}

// COMMENT_BLOCK_ENFORCE is read from <cfgDir>/.env only (the detail plan's comment-block config
// rule; the bash hook's _cb_env_value): when .env and the ambient value disagree, .env wins both ways. The real
// review-comment-block-size scanner runs; one agents copy serves both commits.
function commentBlockEnvPrecedence(X) {
  test("COMMENT_BLOCK_ENFORCE: .env on beats ambient off; .env off beats ambient on", () => {
    const dir = X.agents("cb-precedence");
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    const block = Array.from({ length: 14 }, (_, i) => `// fixture comment line ${i + 1}`).join("\n");
    X.write(dir, "lib/cb-fixture.js", `"use strict";\n${block}\nmodule.exports = 1;\n`);
    X.stage(dir, ["lib/cb-fixture.js"]);
    const cut = "comment-block-size";
    X.write(dir, ".env", "ENFORCE_WORKTREE=off\nCOMMENT_BLOCK_ENFORCE=on\n");
    const on = X.commit(dir, { env: { COMMENT_BLOCK_ENFORCE: "off" } });
    assert.notStrictEqual(on.status, 0, `.env on must keep the gate armed against ambient off\n${show(on)}`);
    assert.strictEqual(X.headCount(dir), 1);
    assert.ok(on.stderr.includes("Commit blocked: staged code carries over-threshold comment blocks."), show(on));
    assert.ok(!on.stderr.includes("comment-block size gate disabled"), show(on));
    assert.deepStrictEqual(on.markers, AGENTS_SEQUENCE.slice(0, AGENTS_SEQUENCE.indexOf(cut) + 1));
    X.write(dir, ".env", "ENFORCE_WORKTREE=off\nCOMMENT_BLOCK_ENFORCE=off\n");
    const off = X.commit(dir, { env: { COMMENT_BLOCK_ENFORCE: "on" } });
    assert.strictEqual(off.status, 0, `.env off must disable the gate against ambient on\n${show(off)}`);
    assert.strictEqual(X.headCount(dir), 2);
    assert.ok(off.stderr.includes("pre-commit: comment-block size gate disabled by COMMENT_BLOCK_ENFORCE=off"), show(off));
    assert.deepStrictEqual(off.markers, AGENTS_SEQUENCE);
  });
}

// The file-reading checks through main's own merge detection: a violation the side branch brings
// in is refused by a plain commit on that branch, yet must not stop the merge commit that only
// carries it. prompt-extraction runs its real CLI in place of the template's stub.
const REPO = path.join(__dirname, "..", "..", "..");
const CJK = "あ";
const cbFile = (n) => `"use strict";\n${Array.from({ length: n }, (_, i) => `// incoming note ${i + 1}`).join("\n")}\nmodule.exports = 1;\n`;
// [check, path, side body, env, block wording, main-side base body]. The comment-block scanner takes a
// path absent from HEAD at its MERGE_HEAD state, so its incoming file grows one that main already has.
const MERGE_CHECKS = [
  ["code-lang", "in-lang.txt", `incoming ${CJK}\n`, { CODE_LANG: "english" }, "Commit blocked: CODE_LANG policy violation in staged files."],
  ["prompt-extraction", "rules/in-pe.md", "# Rule\n\n~~~\nstep one\nstep two\nstep three\nstep four\n~~~\n", {},
    "Commit blocked: prompt extraction violations in staged files."],
  ["comment-block-size", "lib/in-cb.js", cbFile(14), {}, "Commit blocked: staged code carries over-threshold comment blocks.", cbFile(2)],
];

function mergeIncomingOnly(X, name) {
  const [, rel, body, env, blocked, base] = MERGE_CHECKS.find(([n]) => n === name);
  test(`${name}: a violation only in a merge-incoming file blocks a plain commit but not the real merge commit`, () => {
    const dir = X.agents(`merge-only-${name}`);
    X.git(dir, ["remote", "remove", "origin"], { allowFail: true });
    const pe = "bin/lib/prompt-extraction/cli.js";
    if (name === "prompt-extraction") fs.copyFileSync(path.join(REPO, pe), path.join(dir, pe));
    const quiet = ["-c", "core.hooksPath=/dev/null"];
    const before = base === undefined ? 1 : 2;
    if (base !== undefined) {
      X.write(dir, rel, base);
      X.stage(dir, [rel]);
      X.git(dir, [...quiet, "commit", "-q", "-m", "base"]);
    }
    X.git(dir, ["switch", "-q", "-c", "side"]);
    X.write(dir, rel, body);
    X.stage(dir, [rel]);
    const plain = X.commit(dir, { env });
    assert.notStrictEqual(plain.status, 0, `outside a merge the violation blocks\n${show(plain)}`);
    assert.ok(plain.stderr.includes(blocked), show(plain));
    assert.strictEqual(X.headCount(dir), before, "the plain commit was not made");
    assert.strictEqual(plain.markers[plain.markers.length - 1], name, show(plain));
    X.git(dir, [...quiet, "commit", "-q", "-m", "side"]);
    X.git(dir, ["switch", "-q", "main"]);
    X.write(dir, "main-only.txt", "m\n");
    X.stage(dir, ["main-only.txt"]);
    X.git(dir, [...quiet, "commit", "-q", "-m", "main"]);
    X.git(dir, [...quiet, "merge", "-q", "--no-commit", "--no-ff", "side"]);
    assert.strictEqual(X.git(dir, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], { allowFail: true }).status, 0, "MERGE_HEAD exists");
    const r = X.commit(dir, { env, args: ["--no-edit"] });
    assert.strictEqual(r.status, 0, `the merge commit carrying only merge-incoming ${rel} succeeds\n${show(r)}`);
    assert.ok(!r.stderr.includes("Commit blocked"), `no block message\n${show(r)}`);
    assert.strictEqual(X.headCount(dir), before + 3, "the merge commit was made (side, main, merge on top of the base)");
  });
}

module.exports = { nodeMissing, warnNoTty, initialCommit, binaryAndEmpty, mergeNarrowing, frontmatterMissing, pathCommit,
  commentBlockEnvPrecedence, mergeIncomingOnly };

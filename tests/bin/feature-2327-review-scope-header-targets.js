"use strict";
// Tests: bin/review-scope-header-targets.sh, bin/lib/review-scope-header-targets.js
// Tags: TL1, TL2, review-tests, scope-delta, header-targets, nul-output, real-git, scope:issue-specific, test-lang-exception:e2e
// #2327: the staged-test → Tests-header map behind the covering test delta. H cases drive the bash
// output hook directly (byte-exact NUL records, exit codes 0/2/4); J cases drive the JS side, whose
// buildHeaderTargets runs git cat-file and that bash hook in one end-to-end run (hence the e2e
// exception). Modules are required inside each test, so an absent module fails every case.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO_ROOT = path.join(__dirname, "..", "..");
const fwd = (p) => p.replace(/\\/g, "/");
const SCRIPT = fwd(path.join(REPO_ROOT, "bin", "review-scope-header-targets.sh"));
const LIB = path.join(REPO_ROOT, "bin", "lib", "review-scope-header-targets.js");
const lib = () => require(LIB);
const ENV_KEY = "REVIEW_SCOPE_HEADER_TARGETS_BASH";

delete process.env[ENV_KEY];
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2327-header-targets-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

let seq = 0;
// A <root> holding the given { rel: content } files.
function rootWith(files) {
  seq += 1;
  const root = path.join(TMP, `root-${seq}`);
  fs.mkdirSync(root, { recursive: true });
  for (const [rel, body] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), body);
  }
  return fwd(root);
}
const input = (rels) => Buffer.from(rels.map((r) => `${r}\0`).join(""));
function hook(root, rels, extraArgs) {
  const args = root === undefined ? [SCRIPT] : [SCRIPT, root, ...(extraArgs || [])];
  return spawnSync("bash", args, { input: input(rels || []), timeout: 60000, windowsHide: true });
}
const record = (rel, tokens) => Buffer.from(`${rel}\0${tokens.length}\0${tokens.map((t) => `${t}\0`).join("")}`);
const records = (...rs) => Buffer.concat(rs);
function assertOut(res, want) {
  assert.strictEqual(res.status, 0, `exit ${res.status}; stderr=${String(res.stderr)}`);
  assert.ok(Buffer.from(res.stdout).equals(want), `stdout=${JSON.stringify(String(res.stdout))} want=${JSON.stringify(String(want))}`);
}

// Table-driven (skills/_shared/test-design/parser-regex-tests.md): `# Tests:` token parsing.
// files: the <root> contents; rels: the stdin path list; want: [rel, tokens] records in order.
const SH = "#!/usr/bin/env bash\n";
const PARSE_CASES = [
  { name: "H1-two-tokens", files: { "tests/x.sh": `${SH}# Tests: hooks/a.js, bin/b.sh\n# Tags: t\n` },
    rels: ["tests/x.sh"], want: [["tests/x.sh", ["hooks/a.js", "bin/b.sh"]]] },
  { name: "H1-input-order-kept",
    files: { "tests/x.sh": `${SH}# Tests: hooks/a.js, bin/b.sh\n`, "tests/y.sh": `${SH}# Tests: hooks/c.js\n` },
    rels: ["tests/y.sh", "tests/x.sh"], want: [["tests/y.sh", ["hooks/c.js"]], ["tests/x.sh", ["hooks/a.js", "bin/b.sh"]]] },
  { name: "H2-no-header", files: { "tests/x.sh": `${SH}echo hi\n` }, rels: ["tests/x.sh"], want: [["tests/x.sh", []]] },
  { name: "H2-empty-value", files: { "tests/x.sh": `${SH}# Tests:\n` }, rels: ["tests/x.sh"], want: [["tests/x.sh", []]] },
  { name: "H2-blank-value", files: { "tests/x.sh": `${SH}# Tests:    \n` }, rels: ["tests/x.sh"], want: [["tests/x.sh", []]] },
  { name: "H2-no-valid-token", files: { "tests/x.sh": `${SH}# Tests: hooks/a.js (part), /\n` }, rels: ["tests/x.sh"], want: [["tests/x.sh", []]] },
  { name: "H3-js-slash-prefix", files: { "tests/x.test.js": "\"use strict\";\n// Tests: hooks/a.js\n" },
    rels: ["tests/x.test.js"], want: [["tests/x.test.js", ["hooks/a.js"]]] },
  { name: "H3-js-hash-prefix-ignored", files: { "tests/hash.js": "\"use strict\";\n# Tests: hooks/a.js\n" },
    rels: ["tests/hash.js"], want: [["tests/hash.js", []]] },
  { name: "H4-empty-element-dropped", files: { "tests/x.sh": "# Tests: a.js,,b.js\n" }, rels: ["tests/x.sh"], want: [["tests/x.sh", ["a.js", "b.js"]]] },
  { name: "H5-malformed-and-root-dropped", files: { "tests/x.sh": "# Tests: hooks/a.js (part), /, hooks/b.js\n" },
    rels: ["tests/x.sh"], want: [["tests/x.sh", ["hooks/b.js"]]] },
  { name: "H7-crlf-no-trailing-cr", files: { "tests/x.sh": `#!/usr/bin/env bash\r\n# Tests: hooks/a.js, bin/b.sh\r\n` },
    rels: ["tests/x.sh"], want: [["tests/x.sh", ["hooks/a.js", "bin/b.sh"]]] },
  { name: "H8-first-line-only", files: { "tests/x.sh": "# Tests: hooks/first.js\n# Tests: hooks/second.js\n" },
    rels: ["tests/x.sh"], want: [["tests/x.sh", ["hooks/first.js"]]] },
];

caseBegin("H1-H8-tokens-and-records", "bin/review-scope-header-targets.sh");
test("H1-H5, H7, H8: the Tests header parses into byte-exact NUL records", () => {
  for (const { name, files, rels, want } of PARSE_CASES) {
    const res = hook(rootWith(files), rels);
    const exp = records(...want.map(([rel, toks]) => record(rel, toks)));
    assert.strictEqual(res.status, 0, `${name}: exit ${res.status}; stderr=${String(res.stderr)}`);
    assert.ok(Buffer.from(res.stdout).equals(exp), `${name}: stdout=${JSON.stringify(String(res.stdout))} want=${JSON.stringify(String(exp))}`);
  }
});
caseEnd();

caseBegin("H6-H13-path-and-line-edges", "bin/review-scope-header-targets.sh");
test("H6: a path with spaces round-trips unchanged", () => {
  const root = rootWith({ "tests/my dir/a b.sh": "# Tests: hooks/a.js\n" });
  assertOut(hook(root, ["tests/my dir/a b.sh"]), record("tests/my dir/a b.sh", ["hooks/a.js"]));
});
// H12: the SSOT tfm_tests_line_matches (bin/lib/test-frontmatter-fix.sh) scans every line with
// awk and has no first-10-line window, so a header past line 10 is still honoured.
const filler = (n) => Array.from({ length: n }, (_, i) => `# filler ${i + 1}\n`).join("");
const H12_CASES = [
  { name: "header-on-line-2", body: `#!/usr/bin/env bash\n# Tests: hooks/a.js\n`, want: ["hooks/a.js"] },
  { name: "header-on-line-10", body: `${filler(9)}# Tests: hooks/a.js\n`, want: ["hooks/a.js"] },
  { name: "header-on-line-11", body: `${filler(10)}# Tests: hooks/a.js\n`, want: ["hooks/a.js"] },
  { name: "header-on-line-30", body: `${filler(29)}# Tests: hooks/a.js\n`, want: ["hooks/a.js"] },
  { name: "indented-not-a-header", body: `#!/usr/bin/env bash\n  # Tests: hooks/a.js\n`, want: [] },
];
test("H12: the header line window follows the SSOT (no first-10-line limit)", () => {
  for (const { name, body, want } of H12_CASES) {
    const root = rootWith({ "tests/x.sh": body });
    const res = hook(root, ["tests/x.sh"]);
    assert.strictEqual(res.status, 0, `H12/${name}: exit ${res.status}; stderr=${String(res.stderr)}`);
    assert.ok(Buffer.from(res.stdout).equals(record("tests/x.sh", want)), `H12/${name}: stdout=${JSON.stringify(String(res.stdout))}`);
  }
});
// H13: paths with shell metacharacters (Windows-filename-safe) pass through untouched.
const H13_CASES = [
  { name: "dollar", rel: "tests/a$HOME.sh" },
  { name: "single-quote", rel: "tests/it's.sh" },
  { name: "semicolon", rel: "tests/a;b.sh" },
  { name: "ampersand-paren", rel: "tests/a&(b).sh" },
  { name: "backtick-bang", rel: "tests/a`b!c.sh" },
];
test("H13: a path with shell metacharacters round-trips byte-exact", () => {
  const files = Object.fromEntries(H13_CASES.map(({ rel }) => [rel, "# Tests: hooks/a.js\n"]));
  const root = rootWith(files);
  for (const { name, rel } of H13_CASES) {
    const res = hook(root, [rel]);
    assert.strictEqual(res.status, 0, `H13/${name}: exit ${res.status}; stderr=${String(res.stderr)}`);
    assert.ok(Buffer.from(res.stdout).equals(record(rel, ["hooks/a.js"])), `H13/${name}: stdout=${JSON.stringify(String(res.stdout))}`);
  }
});
caseEnd();

caseBegin("H9-H11-exit-codes", "bin/review-scope-header-targets.sh");
test("H9: an unreadable input path exits 4 and names the path on stderr", () => {
  const root = rootWith({ "tests/x.sh": "# Tests: hooks/a.js\n" });
  const res = hook(root, ["tests/x.sh", "tests/missing.sh"]);
  assert.strictEqual(res.status, 4, `stderr=${String(res.stderr)}`);
  assert.ok(String(res.stderr).includes("tests/missing.sh"), String(res.stderr));
});
test("H10: a missing <root>, an absent root dir, or a file as root exits 2", () => {
  const file = path.join(TMP, "not-a-dir.txt");
  fs.writeFileSync(file, "x");
  for (const [name, root] of [["no-arg", undefined], ["absent", fwd(path.join(TMP, "no-such-root"))], ["file", fwd(file)]]) {
    const res = hook(root, []);
    assert.strictEqual(res.status, 2, `${name}: exit ${res.status}; stderr=${String(res.stderr)}`);
  }
});
test("H11: empty stdin exits 0 with empty stdout", () => {
  assertOut(hook(rootWith({}), []), Buffer.alloc(0));
});
caseEnd();

const MAP_PATHS = ["tests/x.sh", "tests/y.js"];
const GOOD = records(record("tests/x.sh", ["hooks/a.js", "bin/b.sh"]), record("tests/y.js", []));

caseBegin("J1-J2-parse-output", "bin/lib/review-scope-header-targets.js");
test("J1: a well-formed buffer parses to the path → tokens map", () => {
  assert.deepStrictEqual(lib().parseHeaderTargetsOutput(GOOD, MAP_PATHS),
    { "tests/x.sh": ["hooks/a.js", "bin/b.sh"], "tests/y.js": [] });
  assert.deepStrictEqual(lib().parseHeaderTargetsOutput(Buffer.alloc(0), []), {});
});
// Table-driven (skills/_shared/test-design/parser-regex-tests.md): every malformed buffer → null.
const J2_CASES = [
  { name: "truncated-last-token", input: GOOD.subarray(0, GOOD.length - 3), want: null },
  { name: "truncated-mid-count", input: Buffer.from("tests/x.sh\0"), want: null },
  { name: "n-not-digits", input: records(Buffer.from("tests/x.sh\0two\0hooks/a.js\0bin/b.sh\0"), record("tests/y.js", [])), want: null },
  { name: "n-negative", input: records(Buffer.from("tests/x.sh\0-1\0"), record("tests/y.js", [])), want: null },
  { name: "n-empty", input: records(Buffer.from("tests/x.sh\0\0"), record("tests/y.js", [])), want: null },
  { name: "n-too-large", input: records(Buffer.from("tests/x.sh\x003\0hooks/a.js\0bin/b.sh\0"), record("tests/y.js", [])), want: null },
  { name: "reordered", input: records(record("tests/y.js", []), record("tests/x.sh", ["hooks/a.js", "bin/b.sh"])), want: null },
  { name: "missing-record", input: record("tests/x.sh", ["hooks/a.js", "bin/b.sh"]), want: null },
  { name: "unexpected-path", input: records(record("tests/x.sh", ["hooks/a.js", "bin/b.sh"]), record("tests/z.sh", [])), want: null },
  { name: "duplicate-record", input: records(GOOD, record("tests/y.js", [])), want: null },
  { name: "trailing-data", input: Buffer.concat([GOOD, Buffer.from("extra\0")]), want: null },
  { name: "trailing-no-nul", input: Buffer.concat([GOOD, Buffer.from("x")]), want: null },
];
test("J2: truncation, a bad n, a reordered or wrong path set, and trailing data give null", () => {
  for (const { name, input, want } of J2_CASES) {
    assert.strictEqual(lib().parseHeaderTargetsOutput(input, MAP_PATHS), want, `J2/${name}`);
  }
});
caseEnd();

// A fixture repo with tests/cover.sh declaring hooks/impl.js, an unrelated test and the impl staged.
function stagedRepo(name) {
  seq += 1;
  const repo = path.join(TMP, `${name}-${seq}`);
  gitInit(repo);
  const git = (...args) => {
    const r = spawnSync("git", ["-C", repo, ...args], { encoding: "utf8", timeout: 30000 });
    if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr || r.error}`);
    return r.stdout;
  };
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "Test");
  git("config", "core.autocrlf", "false");
  const write = (rel, body) => {
    fs.mkdirSync(path.dirname(path.join(repo, rel)), { recursive: true });
    fs.writeFileSync(path.join(repo, rel), body);
  };
  write("tests/cover.sh", "#!/usr/bin/env bash\n# Tests: hooks/impl.js\n");
  write("tests/other.sh", "#!/usr/bin/env bash\n# Tests: bin/other.sh\n");
  write("hooks/impl.js", "module.exports = 1;\n");
  git("add", "tests/cover.sh", "tests/other.sh", "hooks/impl.js");
  return { repo, git, write };
}
const manifestOf = (repo) => {
  const m = require(path.join(REPO_ROOT, "hooks", "workflow-gate", "review-tests-evidence.js")).computeReviewScopeManifest(repo);
  assert.strictEqual(m.ok, true, JSON.stringify(m));
  return m.files;
};

caseBegin("J3-J6-build-header-targets", "bin/lib/review-scope-header-targets.js");
test("J3: a bash run that exits non-zero, cannot spawn, or is killed gives ok:false", () => {
  const { repo } = stagedRepo("j3");
  const files = manifestOf(repo);
  const enoent = Object.assign(new Error("spawnSync bash ENOENT"), { code: "ENOENT" });
  const results = {
    "status-1": { status: 1, signal: null, stdout: Buffer.alloc(0), stderr: Buffer.from("boom") },
    enoent: { status: null, signal: null, error: enoent, stdout: null, stderr: null },
    signal: { status: null, signal: "SIGTERM", stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) },
  };
  for (const [name, res] of Object.entries(results)) {
    let calls = 0;
    const got = lib().buildHeaderTargets(repo, files, { runBash: () => { calls += 1; return res; } });
    assert.strictEqual(got.ok, false, `${name}: ${JSON.stringify(got)}`);
    assert.ok(got.error, `${name}: an error is reported`);
    assert.strictEqual(calls, 1, `${name}: runBash is called once`);
  }
});
test("J4: the map comes from the staged blob, not the edited worktree file", () => {
  const { repo, write } = stagedRepo("j4");
  write("tests/cover.sh", "#!/usr/bin/env bash\n# no header in the worktree copy\n");
  const got = lib().buildHeaderTargets(repo, manifestOf(repo));
  assert.strictEqual(got.ok, true, JSON.stringify(got));
  assert.deepStrictEqual(got.targets, { "tests/cover.sh": ["hooks/impl.js"], "tests/other.sh": ["bin/other.sh"] });
});
test("J5: no staged test gives ok:true and {} without running bash", () => {
  let calls = 0;
  const spy = () => { calls += 1; return { status: 0, signal: null, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) }; };
  for (const files of [{}, { "hooks/impl.js": "0123456789012345678901234567890123456789", "docs/tests/x.sh": "0123456789012345678901234567890123456789" }]) {
    const got = lib().buildHeaderTargets(TMP, files, { runBash: spy });
    assert.deepStrictEqual(got, { ok: true, targets: {} });
  }
  assert.strictEqual(calls, 0, "runBash must not be called");
});
test("J6: the bash override pointing at a nonexistent path gives ok:false naming ENOENT", () => {
  const { repo } = stagedRepo("j6");
  const runner = path.join(TMP, `j6-runner-${seq}.js`);
  fs.writeFileSync(runner, [
    "const [lib, repo, files] = process.argv.slice(2);",
    "const got = require(lib).buildHeaderTargets(repo, JSON.parse(files));",
    "process.stdout.write(JSON.stringify(got));",
  ].join("\n"));
  const env = { ...process.env, [ENV_KEY]: fwd(path.join(TMP, "no-such-dir", "bash")) };
  const res = spawnSync(process.execPath, [runner, LIB, repo, JSON.stringify(manifestOf(repo))], { env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(res.status, 0, res.stderr);
  const got = JSON.parse(res.stdout);
  assert.strictEqual(got.ok, false, res.stdout);
  assert.ok(String(got.error).includes("ENOENT"), res.stdout);
  assert.strictEqual(process.env[ENV_KEY], undefined, "the override never leaks into this process");
});
// J7 (detail plan: `git cat-file --batch` answering `missing` or a non-blob type → ok:false, before
// bash runs). Table-driven over the bad-OID shapes; the other staged test keeps its real OID.
test("J7: a staged test OID that git cat-file reports missing or non-blob gives ok:false without bash", () => {
  const { repo, git } = stagedRepo("j7");
  const files = manifestOf(repo);
  const tree = git("write-tree").trim();
  const J7_CASES = [
    { name: "missing-oid", oid: "1111111111111111111111111111111111111111" },
    { name: "tree-not-blob", oid: tree },
  ];
  for (const { name, oid } of J7_CASES) {
    let calls = 0;
    const spy = () => { calls += 1; return { status: 0, signal: null, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) }; };
    let got;
    assert.doesNotThrow(() => { got = lib().buildHeaderTargets(repo, { ...files, "tests/cover.sh": oid }, { runBash: spy }); }, `J7/${name}: must not throw`);
    assert.strictEqual(got.ok, false, `J7/${name}: ${JSON.stringify(got)}`);
    assert.ok(got.error, `J7/${name}: an error is reported`);
    assert.strictEqual(calls, 0, `J7/${name}: bash must not run on a failed blob read`);
  }
});
caseEnd();

// #2842: the header map's timeout scales with the staged test count (20000 + 100n, capped at
// 300000); REVIEW_SCOPE_HEADER_TARGETS_TIMEOUT_MS, when a positive integer, is used as given.
const TIMEOUT_ENV = "REVIEW_SCOPE_HEADER_TARGETS_TIMEOUT_MS";
caseBegin("J8-J9-header-map-timeout", "bin/lib/review-scope-header-targets.js");
test("J8: headerMapTimeoutMs — scaled default, cap, explicit env, ignored invalid env", () => {
  const fn = lib().headerMapTimeoutMs;
  assert.strictEqual(typeof fn, "function", "headerMapTimeoutMs is exported");
  const CASES = [
    { name: "zero-tests", n: 0, env: {}, want: 20000 },
    { name: "one-test", n: 1, env: {}, want: 20100 },
    { name: "sixty-tests", n: 60, env: {}, want: 26000 },
    { name: "at-cap", n: 2800, env: {}, want: 300000 },
    { name: "over-cap", n: 100000, env: {}, want: 300000 },
    { name: "env-below-cap", n: 60, env: { [TIMEOUT_ENV]: "5000" }, want: 5000 },
    { name: "env-above-cap-is-not-capped", n: 60, env: { [TIMEOUT_ENV]: "900000" }, want: 900000 },
    ...["abc", "0", "-5", "1.5", "", "007"].map((v) => ({ name: `env-invalid-${JSON.stringify(v)}`, n: 60, env: { [TIMEOUT_ENV]: v }, want: 26000 })),
  ];
  for (const { name, n, env, want } of CASES) {
    assert.strictEqual(fn(n, env), want, `J8/${name}`);
  }
});
test("J9: buildHeaderTargets hands the same computed timeout to the git blob read and the bash run", () => {
  const { repo } = stagedRepo("j9");
  const files = manifestOf(repo);
  for (const [name, env, want] of [["scaled", undefined, 20200], ["env", "45000", 45000]]) {
    const seen = {};
    const runGit = (exe, args, options) => { seen.git = options && options.timeout; return spawnSync(exe, args, options); };
    const runBash = (exe, args, options) => { seen.bash = options && options.timeout; return spawnSync(exe, args, options); };
    if (env === undefined) delete process.env[TIMEOUT_ENV];
    else process.env[TIMEOUT_ENV] = env;
    let got;
    try {
      got = lib().buildHeaderTargets(repo, files, { runGit, runBash });
    } finally {
      delete process.env[TIMEOUT_ENV];
    }
    assert.strictEqual(got.ok, true, `J9/${name}: ${JSON.stringify(got)}`);
    assert.strictEqual(seen.git, want, `J9/${name}: the git cat-file timeout (runGit seam)`);
    assert.strictEqual(seen.bash, want, `J9/${name}: the bash timeout`);
  }
});
caseEnd();

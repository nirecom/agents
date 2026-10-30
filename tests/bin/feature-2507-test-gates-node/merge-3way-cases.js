"use strict";
// #2812 on the Node modules: check-self-impl/cli.js run() and self-impl-judge judge() take two heads
// (HEAD, MERGE_HEAD) and a base, and count the existing (kind, detail) keys 3-way as H + M - B
// (clamped at 0); check-test-language-match/cli.js run() takes the same pair and --declaration-only
// alone. The bash entrypoints run the same contracts in tests/bin/feat-2812-tests-gates-merge/cli-args.sh.
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const REL = "tests/bin/s.sh";
// Split so no marker reader takes these fixture strings for markers of this file.
const MB = "case" + "_begin";
const ME = "case" + "_end";
const SRC = 'source "$(dirname "$0")/../../tests/lib/harness.sh"';

let tmp = "";
function dir() {
  if (!tmp) tmp = fs.mkdtempSync(path.join(os.tmpdir(), "t2507-3way-"));
  return tmp;
}
function cleanup() {
  if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
  tmp = "";
}

// body(counters, ...words) — a bash test with <counters> PASS=0 lines and an echo per word.
function body(counters, ...words) {
  const lines = ["#!/usr/bin/env bash", "# Tests: bin/a.sh", "# Tags: scope:issue-specific", SRC];
  for (let i = 0; i < counters; i += 1) lines.push("PASS=0");
  for (const w of words) lines.push(`echo ${w}`);
  lines.push(`${MB} "a" "bin/a.sh"`, "echo a", ME);
  return `${lines.join("\n")}\n`;
}
const BODIES = {
  "c0-b": body(0, "base"), "c1-b": body(1, "base"), "c2-b": body(2, "base"),
  "c1-h": body(1, "h"), "c0-h": body(0, "h"), "c2-h": body(2, "h"),
  "c1-m": body(1, "m"), "c0-m": body(0, "m"),
  "c1-hm": body(1, "h", "m"), "c2-hm": body(2, "h", "m"), "c3-hm": body(3, "h", "m"),
  "c1-new": body(1, "new"),
};
function file(name) {
  const p = path.join(dir(), name);
  if (!fs.existsSync(p)) fs.writeFileSync(p, BODIES[name] || name);
  return p;
}

function sink() {
  let s = "";
  return { write: (c) => { s += String(c); return true; }, text: () => s };
}
// runCli(cli, argv) → { rc, out, err } through the module's run(), cwd = the temp dir.
async function runCli(cli, argv) {
  const { run } = require(path.join(ROOT, "bin", cli, "cli.js"));
  const out = sink();
  const err = sink();
  const rc = await run({ argv, cwd: dir(), env: process.env, stdout: out, stderr: err });
  return { rc, out: out.text(), err: err.text() };
}
const highs = (text) => text.split("\n").filter((l) => l.includes("code=SELF_IMPLEMENTED_HARNESS")).length;

// One staged body against HEAD / MERGE_HEAD / base, through run() and judge(); want = HIGH count.
const SI_TABLE = [
  ["d", "c1-b", "c1-h", "c1-m", "c2-hm", 1],
  ["e", "c0-b", "c1-h", "c1-m", "c2-hm", 0],
  ["f", "c0-b", "c1-h", "c1-m", "c3-hm", 1],
  ["h", "c1-b", "c1-h", "c0-m", "c1-hm", 1],
  ["i", "c1-b", "c0-h", "c1-m", "c1-hm", 1],
  ["clamp-b2-h1-m1", "c2-b", "c1-h", "c1-m", "c1-hm", 1],
  ["clamp-b2-h2-m1", "c2-b", "c2-h", "c1-m", "c1-hm", 0],
];

async function selfImplCli3Way() {
  for (const [id, b, h, m, staged, want] of SI_TABLE) {
    const got = await runCli("check-self-impl", ["--rel", REL, "--head", file(h), "--head", file(m), "--base", file(b), file(staged)]);
    assert.strictEqual(got.rc, want ? 1 : 0, `(${id}) rc: ${got.out}${got.err}`);
    assert.strictEqual(highs(got.out), want, `(${id}) HIGH lines: ${got.out}`);
  }
}

async function selfImplCliTwoHeadsNoBase() {
  // R5: identical heads without a base count as that one parent.
  const same = await runCli("check-self-impl", ["--rel", REL, "--head", file("c1-h"), "--head", file("c1-h"), file("c2-hm")]);
  assert.strictEqual(same.rc, 1, `identical heads, one counter added: ${same.out}${same.err}`);
  assert.strictEqual(highs(same.out), 1);
}

async function selfImplCliEqualToAParent() {
  // A staged blob equal to either head is that parent's file: nothing to judge.
  for (const [label, h, m] of [["HEAD", "c2-hm", "c0-m"], ["MERGE_HEAD", "c0-h", "c2-hm"]]) {
    const got = await runCli("check-self-impl", ["--rel", REL, "--head", file(h), "--head", file(m), "--base", file("c0-b"), file("c2-hm")]);
    assert.deepStrictEqual({ rc: got.rc, highs: highs(got.out) }, { rc: 0, highs: 0 }, `equal to ${label}: ${got.out}${got.err}`);
  }
}

async function selfImplCliArgErrors() {
  const bad = [
    ["--base with one --head", ["--rel", REL, "--head", file("c1-h"), "--base", file("c0-b"), file("c2-hm")]],
    ["--head three times", ["--rel", REL, "--head", file("c1-h"), "--head", file("c1-m"), "--head", file("c0-b"), file("c2-hm")]],
    ["--base missing file", ["--rel", REL, "--head", file("c1-h"), "--head", file("c1-m"), "--base", path.join(dir(), "absent"), file("c2-hm")]],
  ];
  for (const [label, argv] of bad) {
    const got = await runCli("check-self-impl", argv);
    assert.strictEqual(got.rc, 2, `${label}: ${got.out}${got.err}`);
    assert.ok(got.err.length > 0, `${label}: says why on stderr`);
  }
}

async function selfImplCliSingleHeadUnchanged() {
  const got = await runCli("check-self-impl", ["--rel", REL, "--head", file("c1-h"), file("c2-hm")]);
  assert.deepStrictEqual({ rc: got.rc, highs: highs(got.out) }, { rc: 1, highs: 1 }, got.out + got.err);
  const none = await runCli("check-self-impl", ["--rel", REL, file("c1-new")]);
  assert.deepStrictEqual({ rc: none.rc, highs: highs(none.out) }, { rc: 1, highs: 1 }, `a new test is flagged: ${none.out}`);
}

async function selfImplCliManifest5() {
  // Columns: rel, copy, head, merge-head, base; (e) passes, (f) blocks — only tests/bin/t.sh is named.
  const m5 = path.join(dir(), "m5");
  fs.writeFileSync(m5, [
    ["tests/bin/s.sh", file("c2-hm"), file("c1-h"), file("c1-m"), file("c0-b")].join("\t"),
    ["tests/bin/t.sh", file("c3-hm"), file("c1-h"), file("c1-m"), file("c0-b")].join("\t"),
  ].join("\n") + "\n");
  const got = await runCli("check-self-impl", ["--manifest", m5]);
  assert.strictEqual(got.rc, 1, got.out + got.err);
  assert.strictEqual(highs(got.out), 1, got.out);
  assert.ok(got.out.includes("tests/bin/t.sh") && !got.out.includes("tests/bin/s.sh"), got.out);
}

// judge({ name, file, heads: [HEAD, MERGE_HEAD], base }) answers the same table in-process.
function judge3Way() {
  const { judge } = require(path.join(ROOT, "hooks", "lib", "test-gates", "self-impl-judge.js"));
  for (const [id, b, h, m, staged, want] of SI_TABLE) {
    const j = judge({ name: REL, file: file(staged), heads: [file(h), file(m)], base: file(b) });
    const n = j.lines.filter((l) => l.text.includes("code=SELF_IMPLEMENTED_HARNESS")).length;
    assert.deepStrictEqual({ high: j.high, n }, { high: want > 0, n: want }, `judge (${id})`);
  }
  const eq = judge({ name: REL, file: file("c2-hm"), heads: [file("c0-h"), file("c2-hm")], base: file("c0-b") });
  assert.deepStrictEqual({ high: eq.high, lines: eq.lines.length }, { high: false, lines: 0 }, "judge: equal to MERGE_HEAD skips");
  const one = judge({ name: REL, file: file("c2-hm"), head: file("c1-h") });
  assert.strictEqual(one.high, true, "judge: the single head form is unchanged");
}

async function langMatchArgs() {
  const lm = (argv) => runCli("check-test-language-match", argv);
  for (const [label, argv] of [
    ["--base with one --head", ["--rel", REL, "--head", file("c1-h"), "--base", file("c0-b"), file("c2-hm")]],
    ["--head three times", ["--rel", REL, "--head", file("c1-h"), "--head", file("c1-m"), "--head", file("c0-b"), file("c2-hm")]],
    ["--declaration-only with --head", ["--declaration-only", "--rel", REL, "--head", file("c1-h"), file("c2-hm")]],
  ]) {
    const got = await lm(argv);
    assert.strictEqual(got.rc, 2, `${label}: ${got.out}${got.err}`);
  }
  const ok = await lm(["--rel", REL, "--head", file("c1-h"), "--head", file("c1-m"), "--base", file("c0-b"), file("c2-hm")]);
  assert.strictEqual(ok.rc, 0, `two heads and a base, no mismatch: ${ok.out}${ok.err}`);
  const decl = await lm(["--declaration-only", "--rel", REL, file("c2-hm")]);
  assert.strictEqual(decl.rc, 0, `--declaration-only on a plain file: ${decl.out}${decl.err}`);
}

module.exports = {
  cleanup, selfImplCli3Way, selfImplCliTwoHeadsNoBase, selfImplCliEqualToAParent, selfImplCliArgErrors,
  selfImplCliSingleHeadUnchanged, selfImplCliManifest5, judge3Way, langMatchArgs,
};

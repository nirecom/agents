"use strict";
// lang-check: ignore — the \w rows probe CJK letters on purpose.
// Cases 1-2 (TL1): the POSIX ERE -> JS RegExp layer against golden/ere-table.json, which holds
// what bash `[[ s =~ p ]]` did under the hook's C.UTF-8 locale (match text / no match / rc 2).

const assert = require("node:assert");
const { load, golden } = require("./common");
const { UNTRANSLATABLE } = require("./probe-corpus");

// The patterns scan_line hard-codes; D6 builds them through the same translation layer.
const BS = "\\";
const BUILTIN_ERES = [
  `10${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}`,
  `172${BS}.(1[6-9]|2[0-9]|3[01])${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}`,
  `192${BS}.168${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}`,
  `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+${BS}.[a-zA-Z]{2,}`,
  "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}",
  "/Users/[a-zA-Z][a-zA-Z0-9_.-]*",
  `[A-Z]:${BS}${BS}Users${BS}${BS}[a-zA-Z][a-zA-Z0-9_.-]*`,
  "(^|[^[:alnum:]_/])/[a-z]/[[:alnum:]_.-]",
  "(^|[^[:alnum:]_/])/mnt/[a-z]/[[:alnum:]_.-]",
];

function runTranslate() {
  const { translateEre } = load("translate");
  const g = golden("ere-table");
  for (const [name, c] of Object.entries(g.cases)) {
    const r = translateEre(c.ere);
    if (c.status === "invalid") {
      assert.strictEqual(r.status, "invalid", `${name}: bash rejects ${JSON.stringify(c.ere)} (rc 2), want status invalid`);
      continue;
    }
    assert.strictEqual(r.status, "ok", `${name}: ${JSON.stringify(c.ere)} is a valid ERE, want status ok (got ${JSON.stringify(r)})`);
    assert.ok(r.regex instanceof RegExp, `${name}: ok carries a RegExp`);
    assert.ok(r.regex.flags.includes("u"), `${name}: u flag (char-wise like C.UTF-8)`);
    assert.ok(!r.regex.flags.includes("i"), `${name}: no i flag (=~ is case-sensitive)`);
    r.regex.lastIndex = 0;
    assert.strictEqual(r.regex.test(c.subject), c.status === "match", `${name}: ${JSON.stringify(c.ere)} on ${JSON.stringify(c.subject)} want ${c.status}`);
  }
  for (const ere of UNTRANSLATABLE) {
    assert.strictEqual(g.untranslatable[ere], "valid-in-bash", `${ere}: the golden must show bash accepts it`);
    const r = translateEre(ere);
    assert.strictEqual(r.status, "untranslatable", `${ere}: valid ERE with no JS form, want status untranslatable`);
    assert.ok(typeof r.reason === "string" && r.reason.length > 0, `${ere}: untranslatable carries a reason`);
  }
  for (const p of [...BUILTIN_ERES, ...golden("hard-secret-patterns").patterns.map((h) => h.ere)]) {
    assert.strictEqual(translateEre(p).status, "ok", `built-in ${JSON.stringify(p)} translates`);
  }
}

function runLongest() {
  const { translateEre } = load("translate");
  const { leftmostLongest } = load("longest");
  for (const [name, c] of Object.entries(golden("ere-table").cases)) {
    if (c.status === "invalid") continue;
    const r = translateEre(c.ere);
    assert.strictEqual(r.status, "ok", `${name}: translates`);
    const m = leftmostLongest(r.regex, c.subject);
    if (c.status === "nomatch") {
      assert.strictEqual(m, null, `${name}: no match, want null`);
      continue;
    }
    assert.ok(m !== null, `${name}: want a match`);
    assert.strictEqual(m.text, c.text, `${name}: ${JSON.stringify(c.ere)} on ${JSON.stringify(c.subject)} want BASH_REMATCH[0] ${JSON.stringify(c.text)}`);
    assert.strictEqual(c.subject.slice(m.index, m.index + m.text.length), m.text, `${name}: index points at the match`);
  }
}

// #2507 C1: \w follows GNU regex ([_[:alnum:]]), not the Windows Git Bash libc that left "_" out;
// \W is its exact complement and agrees with the \b / \< / \> word class.
const WORD_CASES = [
  { name: "\\w underscore", ere: `^${BS}w$`, subject: "_", want: "_" },
  { name: "\\w ascii letter", ere: `^${BS}w$`, subject: "a", want: "a" },
  { name: "\\w digit", ere: `^${BS}w$`, subject: "7", want: "7" },
  { name: "\\w latin letter", ere: `^${BS}w$`, subject: "é", want: "é" },
  { name: "\\w kana letter", ere: `^${BS}w$`, subject: "あ", want: "あ" },
  { name: "\\w hyphen", ere: `^${BS}w$`, subject: "-", want: null },
  { name: "\\w space", ere: `^${BS}w$`, subject: " ", want: null },
  { name: "\\W underscore", ere: `^${BS}W$`, subject: "_", want: null },
  { name: "\\W space", ere: `^${BS}W$`, subject: " ", want: " " },
  { name: "\\W hyphen", ere: `^${BS}W$`, subject: "-", want: "-" },
  { name: "\\W letter", ere: `^${BS}W$`, subject: "a", want: null },
  { name: "a\\w on a_", ere: `a${BS}w`, subject: "a_", want: "a_" },
  { name: "a\\W on a_", ere: `a${BS}W`, subject: "a_", want: null },
  { name: "\\w+ spans _", ere: `${BS}w+`, subject: "foo_bar baz", want: "foo_bar" },
  { name: "\\w+\\b agrees with \\b", ere: `${BS}w+${BS}b`, subject: "foo_bar", want: "foo_bar" },
  { name: "\\b..\\b around _", ere: `${BS}bfoo_bar${BS}b`, subject: "x foo_bar y", want: "foo_bar" },
  { name: "\\<\\w+\\> agrees with \\< \\>", ere: `${BS}<${BS}w+${BS}>`, subject: " foo_bar ", want: "foo_bar" },
  { name: "\\w in alternation under +", ere: `(${BS}w|-)+`, subject: "a_b-c", want: "a_b-c" },
  { name: "\\w as an alternative", ere: `(x|${BS}w)$`, subject: "_", want: "_" },
  { name: "\\w{3} bound", ere: `${BS}w{3}`, subject: "a_b", want: "a_b" },
  { name: "^\\w*$ on _x", ere: `^${BS}w*$`, subject: "_x", want: "_x" },
];

const COMPLEMENT_CHARS = ["_", "a", "Z", "0", "é", "あ", " ", "-", ".", "\t", "!"];

function runWordShorthand() {
  const { translateEre } = load("translate");
  const { leftmostLongest } = load("longest");
  const compile = (ere) => {
    const r = translateEre(ere);
    assert.strictEqual(r.status, "ok", `${JSON.stringify(ere)} translates (got ${JSON.stringify(r)})`);
    return r.regex;
  };
  for (const { name, ere, subject, want } of WORD_CASES) {
    const m = leftmostLongest(compile(ere), subject);
    assert.strictEqual(m === null ? null : m.text, want, `${name}: ${JSON.stringify(ere)} on ${JSON.stringify(subject)} want ${JSON.stringify(want)}`);
  }
  const w = compile(`^${BS}w$`);
  const W = compile(`^${BS}W$`);
  for (const ch of COMPLEMENT_CHARS) {
    w.lastIndex = 0;
    W.lastIndex = 0;
    const inW = w.test(ch);
    const inNotW = W.test(ch);
    assert.notStrictEqual(inW, inNotW, `${JSON.stringify(ch)}: exactly one of \\w / \\W matches (\\w=${inW}, \\W=${inNotW})`);
  }
}

// #2507 C1 through the real scanner: \w / \W in synthetic list files, read by bin/scan-outbound.sh.
const WORD_LIST_CASES = [
  { name: "blocklist \\w spans _", lists: { blocklist: `fixture-wsh-${BS}w+\n`, allowlist: "" }, input: "fixture-wsh-a_b\n", rc: 1, hit: "fixture-wsh-a_b" },
  { name: "blocklist \\W skips _", lists: { blocklist: `fixture-nsh${BS}W[a-z]+\n`, allowlist: "" }, input: "fixture-nsh_tail\n", rc: 0, hit: null },
  { name: "blocklist \\W takes -", lists: { blocklist: `fixture-nsh${BS}W[a-z]+\n`, allowlist: "" }, input: "fixture-nsh-tail\n", rc: 1, hit: "fixture-nsh-tail" },
  { name: "allowlist \\w admits _", lists: { blocklist: "fixture-wal-[a-z_]+\n", allowlist: `^fixture-wal-${BS}w+$\n` }, input: "fixture-wal-a_b\n", rc: 0, hit: null },
  { name: "allowlist \\W admits -", lists: { blocklist: "fixture-nal[-_][a-z]+\n", allowlist: `^fixture-nal${BS}W[a-z]+$\n` }, input: "fixture-nal-tail\n", rc: 0, hit: null },
  { name: "allowlist \\W rejects _", lists: { blocklist: "fixture-nal[-_][a-z]+\n", allowlist: `^fixture-nal${BS}W[a-z]+$\n` }, input: "fixture-nal_tail\n", rc: 1, hit: "fixture-nal_tail" },
];

function runWordShorthandScanner(root) {
  const SB = require("./sandbox");
  try {
    for (const c of WORD_LIST_CASES) {
      SB.setLists(root, c.lists);
      const r = SB.runCli(root, { argv: ["--stdin", "w.txt"], stdin: Buffer.from(c.input, "utf8") });
      assert.strictEqual(r.error, undefined, `${c.name}: spawn error ${r.error}`);
      assert.strictEqual(r.rc, c.rc, `${c.name}: rc ${c.rc} (got ${r.rc}; stdout ${JSON.stringify(r.stdout)}; stderr ${JSON.stringify(r.stderr)})`);
      const hits = r.stdout.split("\n").filter((l) => l.startsWith("w.txt:"));
      assert.deepStrictEqual(hits, c.hit === null ? [] : [`w.txt:1: [blocklist] ${c.hit}`], `${c.name}: findings`);
    }
  } finally {
    SB.setLists(root, { blocklist: null, allowlist: null });
  }
}

module.exports = { runTranslate, runLongest, runWordShorthand, runWordShorthandScanner };

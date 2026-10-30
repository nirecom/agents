"use strict";
// lang-check: ignore — a class fixture carries a CJK letter on purpose.
// Synthetic corpus of tests/bin/feature-2507-scan-outbound-node.js (#2507 D6), shared by the golden
// generator and the test. Every value a scanner would flag (address, path, key shape, hidden
// character) is assembled at run time so this source never trips the commit-time scan. Changing a
// value here changes the inputs the golden was made from: regenerate the golden (generate-golden.js).

const SL = "/";
const BS = "\\";
const AT = "@";
const ip = (...o) => o.join(".");
const cp = (...c) => String.fromCodePoint(...c);
const rep = (ch, n) => ch.repeat(n);

// Hard-secret shapes: obviously synthetic filler (F...) after the provider prefix.
const SECRETS = {
  anthropic: ["sk", "ant", "api03", rep("F", 24)].join("-"),
  openai: ["sk", "proj", rep("F", 24)].join("-"),
  github: ["gh", "p_", rep("F", 36)].join(""),
  aws: ["AK", "IA", rep("F", 16)].join(""),
  pem: [rep("-", 5), "BEGIN RSA PRIVATE KEY", rep("-", 5)].join(""),
};

// One row per sample line: every HARD_SECRET_PATTERNS label has a value it detects (-hit) and a
// near shape it does not (-near-*). want = the labels bash reports for that line, in order
// (golden/hard-secret-shapes.json records bash's actual result; case 6c holds the two equal).
const HS = (name, label, text, want) => ({ name, label, text, want });
const F = (n) => rep("F", n);
const HARD_SECRET_SHAPES = [
  HS("anthropic-hit", "anthropic-key", SECRETS.anthropic, ["anthropic-key"]),
  HS("anthropic-near-short", "anthropic-key", ["sk", "ant", "api03", F(9)].join("-"), []),
  // Too short for anthropic, long enough for the openai entry tested after it in group sk.
  HS("anthropic-near-falls-to-openai", "anthropic-key", ["sk", "ant", "api03", F(19)].join("-"), ["openai-key"]),
  HS("openai-hit", "openai-key", SECRETS.openai, ["openai-key"]),
  HS("openai-near-short", "openai-key", ["sk", F(19)].join("-"), []),
  HS("aws-hit", "aws-key", SECRETS.aws, ["aws-key"]),
  HS("aws-near-short", "aws-key", ["AK", "IA", F(15)].join(""), []),
  HS("private-key-hit", "private-key", SECRETS.pem, ["private-key"]),
  HS("private-key-near-four-dashes", "private-key", [rep("-", 5), "BEGIN RSA PRIVATE KEY", rep("-", 4)].join(""), []),
  HS("github-hit", "github-token", SECRETS.github, ["github-token"]),
  HS("github-near-short", "github-token", ["gh", "p_", F(35)].join(""), []),
  HS("slack-hit", "slack-token", ["xo", "xb-", "12-34-", F(8)].join(""), ["slack-token"]),
  HS("slack-near-type-c", "slack-token", ["xo", "xc-", "12-34-", F(8)].join(""), []),
  HS("google-hit", "google-key", ["AI", "za", F(35)].join(""), ["google-key"]),
  HS("google-near-short", "google-key", ["AI", "za", F(34)].join(""), []),
  HS("huggingface-hit", "huggingface-token", ["h", "f_", F(34)].join(""), ["huggingface-token"]),
  HS("huggingface-near-short", "huggingface-token", ["h", "f_", F(33)].join(""), []),
  HS("groq-hit", "groq-key", ["gs", "k_", F(20)].join(""), ["groq-key"]),
  HS("groq-near-short", "groq-key", ["gs", "k_", F(19)].join(""), []),
  HS("replicate-hit", "replicate-token", ["r", "8_", F(37)].join(""), ["replicate-token"]),
  HS("replicate-near-short", "replicate-token", ["r", "8_", F(36)].join(""), []),
  HS("cohere-hit", "cohere-key", ["c", "o_", F(40)].join(""), ["cohere-key"]),
  HS("cohere-near-short", "cohere-key", ["c", "o_", F(39)].join(""), []),
];
// The --stdin input of the table: row i is line i + 1.
const hardSecretShapesInput = () => Buffer.from(HARD_SECRET_SHAPES.map((s) => `v ${s.text}\n`).join(""), "utf8");

const BLOCKLIST_MAIN = [
  "# synthetic fixture blocklist",
  "fixture-term-alpha[-a-z]*",
  "fixture-cls-[[:alpha:]]+-beta",
  "fixture-upper-[[:upper:]]{2}",
  "fixture-space[[:space:]]tab",
  `fixture-bs[${BS}]x`,
  `${BS}<fixdelta${BS}>`,
  `fixture-dig${BS}d`,
  "fixture-lm-(a|ab)",
  "fixture-lm2-(a|ab)",
  "fixture-astral-.z",
  "fixture-inv-a{2,1}",
  "(fixture-unclosed",
  "fixture-crlf-term\r",
  "fixture-fileglob-[0-9]+",
  "fixture-qmark-[0-9]+",
  "fixture-brk-[0-9]+",
  "fixture-end-anchor$",
  "fixture-mixed-hard",
  "",
  "warn:fixture-warn-[a-z]+",
  "fixture-lastline-term",
].join("\n");

const ALLOWLIST_MAIN = [
  "# synthetic fixture allowlist",
  "^fixture-term-alpha-ok$",
  "^fixture-lm-a$",
  "^fixture-lm2-ab$",
  "docs/*.md:fixture-fileglob-[0-9]+",
  "notes/?.txt:fixture-qmark-[0-9]+",
  "[ab]/x.txt:fixture-brk-[0-9]+",
  "fixture-warn-allowed",
  `${BS}.example${BS}.com$`,
  "keep-this-msys-line",
  "",
].join("\n");

// lists: name -> { blocklist, allowlist }; null leaves that file out of the sandbox.
const LISTS = {
  main: { blocklist: BLOCKLIST_MAIN, allowlist: ALLOWLIST_MAIN },
  "no-allowlist": { blocklist: "fixture-term-alpha[-a-z]*\n", allowlist: null },
  "no-blocklist": { blocklist: null, allowlist: ALLOWLIST_MAIN },
  "warn-empty": { blocklist: "fixture-term-alpha[-a-z]*\nwarn:\nwarn:fixture-warn-[a-z]+\n", allowlist: "" },
  empty: { blocklist: "", allowlist: "" },
};

const lines = (...l) => l.join("\n");

const TEXT = {
  blocklist: lines(
    "plain line nothing here",
    "fixture-term-alpha-ok",
    "fixture-term-alpha-bad here",
    "x fixture-cls-é-beta y",
    "fixture-cls-あ-beta",
    "fixture-cls-1-beta",
    "fixture-upper-ÀB",
    "fixture-space\ttab fixture-space tab",
    `fixture-bs${BS}x`,
    "a fixdelta b",
    "xfixdeltay",
    "fixture-digd fixture-dig5",
    "fixture-lm-ab",
    "fixture-lm2-ab",
    `fixture-astral-${cp(0x1f600)}z`,
    "fixture-inv-aa (fixture-unclosed",
    "fixture-crlf-term",
    "fixture-end-anchor",
    "fixture-lastline-term",
    "",
  ),
  crlf: "fixture-end-anchor\r\nfixture-term-alpha-ok\r\nfixture-term-alpha-crlf\r\n",
  noTrailingNewline: "first clean line\nfixture-term-alpha-tail",
  warnOnly: "fixture-warn-alpha\nfixture-warn-allowed\n",
  mixed: "fixture-mixed-hard fixture-warn-mixed\nfixture-warn-second\n",
  builtins: lines(
    `hosts ${ip(10, 1, 2, 3)} and ${ip(192, 168, 0, 1)} and ${ip(10, 1, 2, 3)} and ${ip(172, 16, 5, 4)} public ${ip(8, 8, 8, 8)}`,
    `also ${ip(172, 15, 0, 1)} and ${ip(172, 31, 9, 9)}`,
    `mail fixture.user${AT}example.org`,
    `mail fixture.user${AT}mail.example.com`,
    `mac ${["aa", "bb", "cc", "dd", "ee", "ff"].join(":")} and ${["00", "11", "22", "33", "44", "55"].join("-")}`,
    `p ${SL}Users${SL}fixtureuser${SL}x`,
    `p ${SL}home${SL}fixtureuser`,
    `p ${SL}home${SL}linuxbrew${SL}.linuxbrew`,
    `p C:${BS}Users${BS}fixtureuser`,
    `p C:${SL}Users${SL}fixtureuser`,
    `m ${SL}c${SL}fixture`,
    `w ${SL}mnt${SL}c${SL}fixture`,
    `keep-this-msys-line ${SL}d${SL}fixture`,
    "",
  ),
  secrets: lines(
    `a ${SECRETS.anthropic}`,
    `o ${SECRETS.openai}`,
    `both ${SECRETS.anthropic} ${SECRETS.openai}`,
    `g ${SECRETS.github}`,
    `k ${SECRETS.aws}`,
    SECRETS.pem,
    "",
  ),
  hidden: lines(
    `zw${cp(0x200b)}x`,
    `zj${cp(0x200d)}x`,
    `bom${cp(0xfeff)}x`,
    `rlo${cp(0x202e)}x`,
    `pdi${cp(0x2069)}x`,
    `near${cp(0x200a)}${cp(0x200e)}${cp(0x202c)}${cp(0x206a)}x`,
    "",
  ),
  fileglob: "fixture-fileglob-42\nfixture-qmark-7\nfixture-brk-9\n",
  clean: "nothing to report here\n",
};

const RS = "\u001e";
function manifest(frames) {
  const parts = [];
  for (const [p, body] of frames) {
    const bytes = Buffer.from(body, "utf8");
    parts.push(Buffer.from(`${RS}${p}${RS}${bytes.length}\n`, "utf8"), bytes);
  }
  return Buffer.concat(parts);
}

const u = (s) => Buffer.from(s, "utf8");

// CLI cases. lists: a LISTS key; argv: scanner arguments (cwd is the sandbox root); stdin: Buffer
// or null; files: sandbox-relative path -> Buffer written before the run.
const CLI_CASES = [
  { name: "stdin-blocklist-corpus", lists: "main", argv: ["--stdin", "corpus.txt"], stdin: u(TEXT.blocklist) },
  { name: "stdin-default-label", lists: "main", argv: ["--stdin"], stdin: u("fixture-term-alpha-bad\n") },
  { name: "stdin-crlf", lists: "main", argv: ["--stdin", "crlf.txt"], stdin: u(TEXT.crlf) },
  { name: "stdin-no-trailing-newline", lists: "main", argv: ["--stdin", "tail.txt"], stdin: u(TEXT.noTrailingNewline) },
  { name: "stdin-warn-only", lists: "main", argv: ["--stdin", "warn.txt"], stdin: u(TEXT.warnOnly) },
  { name: "stdin-hard-and-warn", lists: "main", argv: ["--stdin", "mixed.txt"], stdin: u(TEXT.mixed) },
  { name: "stdin-builtin-patterns", lists: "main", argv: ["--stdin", "builtins.txt"], stdin: u(TEXT.builtins) },
  { name: "stdin-hard-secrets", lists: "empty", argv: ["--stdin", "secrets.txt"], stdin: u(TEXT.secrets) },
  // Under the hook's C.UTF-8 the bash byte-sequence regexes for zero-width / bidi fail to compile
  // (rc 2) and detect nothing; only byte-wise C shows the intended detection, so this one case is
  // recorded under LC_ALL=C. The Node port must detect (D6: no silent narrowing of detection).
  { name: "stdin-zero-width-and-bidi", lists: "main", argv: ["--stdin", "hidden.txt"], stdin: u(TEXT.hidden), locale: "C" },
  { name: "file-allow-star-crosses-slash", lists: "main", argv: ["--stdin", "docs/sub/readme.md"], stdin: u(TEXT.fileglob) },
  { name: "file-allow-other-dir", lists: "main", argv: ["--stdin", "other/readme.md"], stdin: u(TEXT.fileglob) },
  { name: "file-allow-qmark-and-bracket", lists: "main", argv: ["--stdin", "notes/a.txt"], stdin: u(TEXT.fileglob) },
  { name: "file-allow-bracket-hit", lists: "main", argv: ["--stdin", "a/x.txt"], stdin: u(TEXT.fileglob) },
  { name: "file-allow-qmark-two-chars", lists: "main", argv: ["--stdin", "notes/ab.txt"], stdin: u(TEXT.fileglob) },
  { name: "stdin-clean", lists: "main", argv: ["--stdin", "clean.txt"], stdin: u(TEXT.clean) },
  { name: "stdin-empty-input", lists: "main", argv: ["--stdin", "empty.txt"], stdin: u("") },
  {
    name: "manifest-two-frames",
    lists: "main",
    argv: ["--manifest"],
    stdin: manifest([["docs/m1.md", "fixture-fileglob-1\nfixture-term-alpha-m1\n"], ["src/m2.txt", `fixture-cls-é-beta\nfixture-warn-frame`]]),
  },
  {
    name: "files-mode-with-missing",
    lists: "main",
    argv: ["inputs/f1.txt", "inputs/missing.txt", "inputs/f2.txt"],
    stdin: null,
    files: { "inputs/f1.txt": u("fixture-term-alpha-f1\nclean\n"), "inputs/f2.txt": u("fixture-warn-ftwo\r\nfixture-term-alpha-f2") },
  },
  { name: "usage-no-arguments", lists: "main", argv: [], stdin: null },
  { name: "blocklist-missing", lists: "no-blocklist", argv: ["--stdin", "x.txt"], stdin: u("fixture-term-alpha-bad\n") },
  { name: "allowlist-missing", lists: "no-allowlist", argv: ["--stdin", "x.txt"], stdin: u("fixture-term-alpha-bad\n") },
  { name: "empty-warn-pattern", lists: "warn-empty", argv: ["--stdin", "x.txt"], stdin: u("fixture-warn-alpha\n") },
];

module.exports = { SECRETS, LISTS, TEXT, CLI_CASES, HARD_SECRET_SHAPES, hardSecretShapesInput, manifest };

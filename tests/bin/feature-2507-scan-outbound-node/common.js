"use strict";
// Shared helpers of the #2507 scan-outbound parts: module paths under test, golden access, and a
// loader that requires a module fresh inside each test so a missing module fails only that case.

const path = require("node:path");

const REPO = path.resolve(__dirname, "..", "..", "..");

// Module under test -> the contract the cases assume (written before the modules exist).
const MOD = {
  // translateEre(ere) -> {status:"ok",regex} | {status:"invalid"} | {status:"untranslatable",reason}
  translate: "hooks/lib/ere/translate.js",
  // leftmostLongest(regex, text) -> {index, text} | null
  longest: "hooks/lib/ere/longest.js",
  // globMatch(glob, subject) -> boolean
  glob: "hooks/lib/outbound-scan/glob.js",
  // HARD_SECRET_PATTERNS: [{label, group, ere}]
  hardSecret: "hooks/lib/outbound-scan/hard-secret-patterns.js",
  // scanText(text, {file, lists:{allow, blockHard, blockWarn}}) -> {verdict, messages, details:{findings, incomplete}}
  scanText: "hooks/lib/outbound-scan/scan-text.js",
  // isBinary({mode, content: Buffer|null}) -> boolean
  binary: "hooks/pre-commit.d/checks/outbound-scan/binary.js",
  // isSkippedPath(path) -> boolean; scanStaged({files:[{path,mode,content}], lists}) -> D5 result
  precommitCheck: "hooks/pre-commit.d/checks/outbound-scan.js",
  // run({argv, stdin, cwd, env, stdout, stderr}) -> rc or Promise<rc>
  cli: "bin/scan-outbound.d/cli.js",
  // isSecretShaped(text) -> boolean; throws when the pattern source is empty or unreadable
  secretShape: "hooks/workflow-state/complexity-routing/secret-shape.js",
};

// The new modules the self-scan (case 5) walks: every source file the port adds.
const NEW_MODULE_FILES = [
  MOD.translate,
  MOD.longest,
  MOD.glob,
  MOD.hardSecret,
  "hooks/lib/outbound-scan/lists.js",
  "hooks/lib/outbound-scan/scan-line.js",
  MOD.scanText,
  "hooks/lib/outbound-scan/format.js",
  MOD.cli,
  MOD.precommitCheck,
  MOD.binary,
];

const abs = (rel) => path.join(REPO, rel);

// Drops every cached module of the port (and secret-shape) so the next require re-reads them;
// `keep` survives (a stub injected into require.cache).
function dropPortCache(keep) {
  const roots = [abs("hooks/lib/ere"), abs("hooks/lib/outbound-scan"), abs("hooks/pre-commit.d"), abs("bin/scan-outbound.d"), abs(MOD.secretShape)];
  for (const key of Object.keys(require.cache)) {
    if (key === keep) continue;
    if (roots.some((r) => key === r || key.startsWith(r + path.sep))) delete require.cache[key];
  }
}

function load(key) {
  return require(abs(MOD[key]));
}

function golden(name) {
  return require(path.join(__dirname, "golden", `${name}.json`));
}

const unb64 = (s) => Buffer.from(s, "base64").toString("utf8");

// Fixture lists in the shape scanText takes, parsed the way bash loads them (CR stripped,
// comments and empty lines dropped, `warn:` split off, empty warn patterns skipped).
function parseLists({ blocklist, allowlist }) {
  const rows = (t) => (t || "").split("\n").map((l) => l.replace(/\r$/, "")).filter((l) => l !== "" && !l.startsWith("#"));
  const block = rows(blocklist);
  return {
    allow: rows(allowlist),
    blockHard: block.filter((l) => !l.startsWith("warn:")),
    blockWarn: block.filter((l) => l.startsWith("warn:")).map((l) => l.slice(5)).filter((l) => l !== ""),
  };
}

module.exports = { REPO, MOD, NEW_MODULE_FILES, abs, dropPortCache, load, golden, unb64, parseLists };

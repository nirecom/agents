"use strict";
// Regenerates golden/*.json for tests/bin/feature-2507-scan-outbound-node.js (#2507 D6) from the
// bash implementation that the Node port replaces. Run it only against the pre-port tree (the
// golden is "what bash did"): `node tests/bin/feature-2507-scan-outbound-node/generate-golden.js`.
// Every list it feeds the scanner is a synthetic fixture (corpus.js); the real lists are never read.
// Outputs are stored base64 so synthetic secrets / addresses in them never meet the commit scan.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const C = require("./corpus");
const P = require("./probe-corpus");
const { BINARY_CASES, WINDOW } = require("./binary-corpus");
const SB = require("./sandbox");
const { MANIFEST_CASES } = require("./manifest-corpus");
const MC = require("./manifest-cases");
const { shapeRowsFromStdout } = require("./ssot-skip");

const OUT = path.join(__dirname, "golden");
const b64 = (s) => Buffer.from(s, "utf8").toString("base64");
const one = (cmd, args) => (spawnSync(cmd, args, { encoding: "utf8" }).stdout || "").split("\n")[0].trim();

// Operands travel NUL-separated on stdin into $1 $2: a Windows process spawning MSYS bash has
// its argv globbed and backslash-mangled by the MSYS runtime, which would corrupt the probes.
function bashProbe(script, args) {
  const reader = `set --; while IFS= read -r -d '' _a; do set -- "$@" "$_a"; done; ${script}`;
  const input = Buffer.from(args.map((a) => `${a}\0`).join(""), "utf8");
  const r = spawnSync("bash", ["-c", reader], { env: SB.baseEnv(), input, encoding: "utf8" });
  return r.stdout;
}

function meta() {
  return {
    generator: "tests/bin/feature-2507-scan-outbound-node/generate-golden.js",
    // The probe subjects include CJK on purpose; this keeps the commit-time CODE_LANG check off.
    langCheck: "lang-check: ignore",
    locale: { LANG: null, LC_ALL: null, ...SB.LOCALE },
    bash: one("bash", ["--version"]),
    git: one("git", ["--version"]),
    node: process.version,
    file: one("file", ["--version"]),
    platform: process.platform,
  };
}

function writeJson(name, data) {
  fs.writeFileSync(path.join(OUT, name), `${JSON.stringify({ meta: meta(), ...data }, null, 2)}\n`);
}

function genCli() {
  const root = SB.createSandbox();
  try {
    const cases = {};
    for (const c of C.CLI_CASES) {
      SB.setLists(root, C.LISTS[c.lists]);
      const r = SB.runCli(root, c);
      cases[c.name] = { locale: c.locale || SB.LOCALE.LC_CTYPE, rc: r.rc, stdoutB64: b64(r.stdout), stderrB64: b64(r.stderr) };
    }
    writeJson("cli.json", { cases });
  } finally {
    SB.removeSandbox(root);
  }
}

// Malformed --manifest streams: bash's result for every row, matched text only as a sha256
// (manifest-cases.js record()). Rows with expect "rc4" keep it as a record, not as the expectation.
function genManifest() {
  const root = SB.createSandbox();
  try {
    const cases = {};
    for (const c of MANIFEST_CASES) cases[c.name] = { expect: c.expect, ...MC.record(MC.runOne(root, c)) };
    writeJson("manifest.json", { cases });
  } finally {
    SB.removeSandbox(root);
  }
}

// The hard-secret shape table (corpus.js) through bash --stdin: labels per row, match as a sha256.
function genHardSecretShapes() {
  const root = SB.createSandbox();
  try {
    SB.setLists(root, C.LISTS.empty);
    const r = SB.runCli(root, { argv: ["--stdin", "shapes.txt"], stdin: C.hardSecretShapesInput() });
    writeJson("hard-secret-shapes.json", { rc: r.rc, cases: shapeRowsFromStdout(r.stdout) });
  } finally {
    SB.removeSandbox(root);
  }
}

// rc 2 from [[ =~ ]] means the ERE failed to compile.
const ERE_SCRIPT = 'if [[ "$1" =~ $2 ]]; then printf "M%s" "${BASH_REMATCH[0]}"; else printf "R%s" "$?"; fi';
function genEre() {
  const cases = {};
  for (const [name, ere, subject] of P.ERE_CASES) {
    const out = bashProbe(ERE_SCRIPT, [subject, ere]);
    const want = out[0] === "M" ? { status: "match", text: out.slice(1) } : out === "R1" ? { status: "nomatch" } : { status: "invalid" };
    cases[name] = { ere, subject, ...(P.GNU_OVERRIDES[name] || want) };
  }
  const untranslatable = {};
  for (const ere of P.UNTRANSLATABLE) untranslatable[ere] = bashProbe('[[ "x" =~ $1 ]]; printf "%s" "$?"', [ere]) === "2" ? "invalid-in-bash" : "valid-in-bash";
  writeJson("ere-table.json", { overrides: { note: P.GNU_OVERRIDE_NOTE, cases: Object.keys(P.GNU_OVERRIDES) }, cases, untranslatable });
}

function genGlob() {
  const cases = {};
  for (const [name, glob, subject] of P.GLOB_CASES) {
    cases[name] = { glob, subject, match: bashProbe('if [[ "$1" == $2 ]]; then printf 1; else printf 0; fi', [subject, glob]) === "1" };
  }
  writeJson("glob.json", { cases });
}

function genSkip() {
  const src = fs.readFileSync(path.join(SB.REPO, "hooks", "pre-commit"), "utf8");
  const skip = /^SKIP_PATTERNS="([^"]*)"$/m.exec(src)[1];
  const cases = {};
  for (const p of P.SKIP_PATHS) cases[p] = bashProbe('if echo "$1" | grep -qE "$2"; then printf 1; else printf 0; fi', [p, skip]) === "1";
  writeJson("skip-patterns.json", { skipPatterns: skip, cases });
}

function genHardSecret() {
  const src = fs.readFileSync(path.join(SB.REPO, "bin", "scan-outbound.sh"), "utf8");
  const block = /# BEGIN hard-secret-patterns\n([\s\S]*?)# END hard-secret-patterns/.exec(src)[1];
  const patterns = [...block.matchAll(/^\s*'(\S+) (\S+) (.+)'\s*$/gm)].map((m) => ({ label: m[1], group: m[2], ere: m[3] }));
  writeJson("hard-secret-patterns.json", { patterns });
}

// The exact pre-commit pipeline, run against a fixture index entry per corpus blob.
function genBinary() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "t2507-bin-"));
  const git = (...a) => spawnSync("git", ["-C", dir, ...a], { encoding: "utf8" });
  try {
    git("init", "-q");
    git("config", "core.hooksPath", "/dev/null");
    const cases = {};
    for (const c of BINARY_CASES) {
      let sha = "1".repeat(40);
      if (c.content) {
        const p = path.join(dir, "blob.tmp");
        fs.writeFileSync(p, c.content);
        sha = git("hash-object", "-w", p).stdout.trim();
      }
      git("update-index", "--add", "--cacheinfo", `${c.mode},${sha},${c.name}`);
      const mime = bashProbe('git -C "$1" show ":$2" 2>/dev/null | file --mime - 2>/dev/null', [dir, c.name]).trim();
      cases[c.name] = { mode: c.mode, size: c.content ? c.content.length : null, mime, binary: mime.includes("binary") };
    }
    const params = one("file", ["--help"]);
    writeJson("binary.json", { fileParams: { encoding: WINDOW, bytes: 7340032, helpFirstLine: params }, cases });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

fs.mkdirSync(OUT, { recursive: true });
genCli();
genManifest();
genEre();
genGlob();
genSkip();
genHardSecret();
genHardSecretShapes();
genBinary();
process.stdout.write(`golden written to ${OUT}\n`);

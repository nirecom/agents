"use strict";
// CLI of the outbound scanner, behind bin/scan-outbound.sh (#2507 D5/D6).
// Usage: scan-outbound.sh [--stdin [label]] [--manifest] [file ...]
// Exit: 0 clean, 1 hard violation, 2 warn only, 3 usage error, 4 cannot scan (no blocklist,
// a broken hard-secret source, an ERE with no JS form, a broken --manifest frame).

const fs = require("fs");
const path = require("path");
const { listPaths, loadLists } = require("../../hooks/lib/outbound-scan/lists");
const { prepareScan, scanLines, hardSecrets } = require("../../hooks/lib/outbound-scan/scan-text");
const F = require("../../hooks/lib/outbound-scan/format");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");
const { parseManifest } = require("./manifest");

const USAGE = "Usage: scan-outbound.sh [--stdin [label]] [--manifest] [file ...]";
const BIN_DIR = path.dirname(__dirname);

function parseArgs(argv) {
  if (argv[0] === "--stdin") return { mode: "stdin", label: argv.length > 1 ? argv[1] : "stdin" };
  if (argv[0] === "--manifest") return { mode: "manifest" };
  return { mode: "files", files: argv };
}

const readStdin = (stdin) => {
  if (typeof stdin === "function") return stdin();
  if (stdin === undefined || stdin === null) return fs.readFileSync(0);
  return Buffer.isBuffer(stdin) ? stdin : Buffer.from(String(stdin), "utf8");
};

// [{ label, text }] of the selected mode, or { broken } for a --manifest stream that cannot be read.
function inputsOf(args, { stdin, cwd }, warn) {
  if (args.mode === "stdin") return [{ label: args.label, text: readStdin(stdin).toString("utf8") }];
  if (args.mode === "manifest") {
    const m = parseManifest(readStdin(stdin));
    if (m.broken) return { broken: m.broken };
    return m.frames.map((f) => ({ label: f.path, text: f.body.toString("utf8") }));
  }
  return args.files.flatMap((f) => {
    const abs = path.resolve(toWindowsPath(cwd || process.cwd()), toWindowsPath(f));
    const st = fs.statSync(abs, { throwIfNoEntry: false });
    if (!st || !st.isFile()) {
      warn(`Warning: ${f} not found, skipping`);
      return [];
    }
    return [{ label: f, text: fs.readFileSync(abs).toString("utf8") }];
  });
}

function run({ argv, stdin, cwd, env, stdout, stderr }) {
  const out = (l) => stdout.write(`${l}\n`);
  const err = (l) => stderr.write(`${l}\n`);
  const hs = hardSecrets();
  if (hs.error) {
    err(F.incompleteLine(hs.error));
    return 4;
  }
  const paths = listPaths(BIN_DIR, env);
  if (!argv || argv.length === 0) {
    err(USAGE);
    return 3;
  }
  const args = parseArgs(argv);
  const loaded = loadLists(paths);
  loaded.warnings.forEach(err);
  if (loaded.error) {
    err(loaded.error);
    return 4;
  }
  const scanner = prepareScan(loaded.lists);
  if (scanner.incomplete) {
    err(F.incompleteLine(scanner.incomplete.reason));
    return 4;
  }
  const inputs = inputsOf(args, { stdin, cwd }, err);
  if (inputs.broken) {
    err(F.incompleteLine(`broken --manifest stream: ${inputs.broken}`));
    return 4;
  }
  const findings = [];
  for (const input of inputs) {
    const found = scanLines(scanner, input.text, input.label);
    found.forEach((f) => out(F.findingLine(f)));
    findings.push(...found);
  }
  const c = F.counts(findings);
  F.summaryLines(c).forEach(out);
  return F.rcOf(c);
}

if (require.main === module) {
  process.exitCode = run({ argv: process.argv.slice(2), cwd: process.cwd(), env: process.env, stdout: process.stdout, stderr: process.stderr });
}

module.exports = { run };

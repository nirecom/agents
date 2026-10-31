"use strict";
// The outbound scan of the staged A/C/M blobs, with the output and verdicts of the bash hook:
// per-file scanner output, hard files then warn files, and the "Commit blocked" wording.

const path = require("path");
const { listPaths, loadLists } = require("../../../lib/outbound-scan/lists");
const { prepareScan, scanLines } = require("../../../lib/outbound-scan/scan-text");
const F = require("../../../lib/outbound-scan/format");
const { out, err } = require("../../output");
const { isBinary } = require("./binary");

// Unchanged from the bash hook: a substring ERE over the staged path (its first `.` is any char).
const SKIP_PATTERNS = /bin\/scan-outbound.sh|\.private-info-allowlist|\.offensive-content-blocklist\.example/;
const SCANNED_STATUS = new Set(["A", "C", "M"]);
const RC4_TEXT = "pre-commit: private-info blocklist unresolved (rc=4) — cannot scan, commit blocked";

const isSkippedPath = (p) => SKIP_PATTERNS.test(p);
const rc4 = (incomplete) => ({ verdict: "block", messages: [err(RC4_TEXT)], details: { findings: [], incomplete } });

// scanStaged({files:[{path,mode,content}], lists, warnings}) -> D5 result over the staged blobs.
function scanStaged({ files, lists, warnings = [] }) {
  const scanner = prepareScan(lists);
  if (scanner.incomplete) return rc4(scanner.incomplete);
  const hard = [];
  const warn = [];
  const findings = [];
  for (const f of files) {
    if (isSkippedPath(f.path) || isBinary(f)) continue;
    const found = scanLines(scanner, f.content.toString("utf8"), f.path);
    const c = F.counts(found);
    if (c.hard + c.warn === 0) continue;
    findings.push(...found);
    (c.hard > 0 ? hard : warn).push(...warnings, ...found.map(F.findingLine), ...F.summaryLines(c));
  }
  const details = { findings, incomplete: null };
  if (hard.length > 0) {
    const lines = ["", ...hard, ...(warn.length > 0 ? ["", ...warn] : []), "",
      "Commit blocked: private information detected in staged files.", "Fix the issues above, or add exceptions to .private-info-allowlist"];
    return { verdict: "block", messages: lines.map(out), details };
  }
  if (warn.length > 0) return { verdict: "confirm-warn", messages: ["", ...warn, ""].map(out), details };
  return { verdict: "pass", messages: [], details };
}

// The bash hook resolved the lists through $_cfg_dir/bin/scan-outbound.sh.
function binDirOf(context) {
  const cfgDir = context && context.cfgDir ? context.cfgDir : path.resolve(__dirname, "..", "..", "..", "..");
  return path.join(cfgDir, "bin");
}

async function run({ context, snapshot, files }) {
  if (!snapshot.hasHead()) return { verdict: "pass", messages: [] };
  const staged = files.filter((p) => SCANNED_STATUS.has(snapshot.status(p)));
  if (staged.length === 0) return { verdict: "pass", messages: [] };
  const loaded = loadLists(listPaths(binDirOf(context), context && context.env));
  if (loaded.error) return rc4({ reason: loaded.error });
  const blobs = staged.map((p) => ({ path: p, mode: snapshot.mode(p), content: snapshot.content(p) }));
  return scanStaged({ files: blobs, lists: loaded.lists, warnings: loaded.warnings });
}

module.exports = { run, scanStaged, isSkippedPath, SKIP_PATTERNS };

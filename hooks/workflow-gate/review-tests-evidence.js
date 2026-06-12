"use strict";
// Issue #833 — compute a deterministic fingerprint of staged tests/ files.
//
// Used by:
//   - workflow-gate.js: stale-token detection. Compares the live computed token
//     against the token recorded by the review-tests sentinel handler. Mismatch
//     means tests were re-edited after a passing review — the gate re-blocks
//     until /review-tests runs again.
//
// Inputs:  blob OID of each staged tests/** (or test/**) path, sorted by path.
// Output:  16-hex-char SHA-256 prefix (content-addressed; deterministic).
//          Returns null on:
//            - non-git directory / git failure
//            - no tests/** staged
//          The null result is the fail-open convention used elsewhere in
//          workflow-gate (the caller treats null as "no evidence").

const { execFileSync } = require("child_process");
const crypto = require("crypto");

function computeStagedTestsToken(repoDir) {
  let output;
  try {
    output = execFileSync("git", ["diff", "--cached", "--name-only", "-z"], {
      cwd: repoDir,
      encoding: "buffer",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (e) {
    return null;
  }

  const paths = Buffer.from(output)
    .toString("utf8")
    .split("\0")
    .filter((p) => p && (p.startsWith("tests/") || p.startsWith("test/")));

  if (paths.length === 0) return null;

  const rows = [];
  for (const p of paths) {
    let oid;
    try {
      oid = execFileSync("git", ["rev-parse", `:${p}`], {
        cwd: repoDir,
        encoding: "utf8",
        timeout: 5000,
        stdio: ["pipe", "pipe", "pipe"],
      }).trim();
    } catch (e) {
      // Fail-safe: any single path failure → no token.
      return null;
    }
    rows.push(`${p}\t${oid}`);
  }

  rows.sort();
  const content = rows.join("\n");
  return crypto.createHash("sha256").update(content).digest("hex").slice(0, 16);
}

module.exports = { computeStagedTestsToken };

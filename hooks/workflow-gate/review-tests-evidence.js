"use strict";
// Review-scope evidence for review_tests (#833, #2327): the staged review scope
// (tests plus implementation files) as a per-file { path: blobOid } manifest and
// its 16-hex digest. Shared by the commit gate, the review-tests sentinel handler,
// the write_code completion reopen and the re-review scope selector.
//
// Scope: every staged path (`--diff-filter=d`, so deletions never reach the OID
// lookup — issue #1068) for which isReviewScopeExcludedPath is false.

const { execFileSync } = require("child_process");
const crypto = require("crypto");

function toSlash(p) {
  return String(p || "").replace(/\\/g, "/").replace(/^\.\//, "");
}

// SSOT for paths outside the review scope: docs/, the append-only record set
// (isProtectedPath owns its patterns — never duplicated here), and the root README.md.
// isProtectedPath is required lazily and only for .md paths (the record set is .md-only),
// so the review loop can load this file standalone for the common non-.md scope.
function isReviewScopeExcludedPath(p) {
  const norm = toSlash(p);
  if (!norm) return true;
  if (norm.startsWith("docs/") || norm === "README.md") return true;
  if (!/\.md$/i.test(norm)) return false;
  return require("../lib/history-path-check").isProtectedPath(norm);
}

function isReviewScopeTestPath(p) {
  const norm = toSlash(p);
  return norm.startsWith("tests/") || norm.startsWith("test/");
}

function git(repoDir, args) {
  return execFileSync("git", args, {
    cwd: repoDir,
    encoding: "buffer",
    timeout: 5000,
    stdio: ["pipe", "pipe", "pipe"],
  });
}

// { ok: true, files } (files may be empty) or { ok: false, error } on a git failure,
// so "nothing staged" and "cannot tell" stay distinguishable.
function computeReviewScopeManifest(repoDir) {
  if (!repoDir) return { ok: false, error: "no repository directory" };
  try {
    const out = git(repoDir, ["diff", "--cached", "--name-only", "--diff-filter=d", "-z"]);
    const paths = Buffer.from(out).toString("utf8").split("\0")
      .filter((p) => p && !isReviewScopeExcludedPath(p));
    const files = {};
    if (paths.length === 0) return { ok: true, files };
    // One whole-index read (no per-path argv, so no command-line length limit);
    // -z keeps non-ASCII paths unquoted. Stage 0 only: a conflicted path has no OID.
    const index = new Map();
    const ls = git(repoDir, ["ls-files", "-s", "-z"]);
    for (const row of Buffer.from(ls).toString("utf8").split("\0")) {
      const m = row.match(/^\d+ ([0-9a-f]+) 0\t(.+)$/);
      if (m) index.set(m[2], m[1]);
    }
    for (const p of paths) {
      if (!index.has(p)) return { ok: false, error: `no index entry for ${p}` };
      files[p] = index.get(p);
    }
    return { ok: true, files };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e).split("\n")[0] };
  }
}

function fingerprintOfManifest(files) {
  const rows = Object.keys(files || {}).map((p) => `${p}\t${files[p]}`);
  rows.sort();
  return crypto.createHash("sha256").update(rows.join("\n")).digest("hex").slice(0, 16);
}

// { ok, fingerprint, testCount, files } — fingerprint is null when the scope is empty.
function computeReviewScopeFingerprint(repoDir) {
  const m = computeReviewScopeManifest(repoDir);
  if (!m.ok) return { ok: false, error: m.error, fingerprint: null, testCount: 0 };
  const paths = Object.keys(m.files);
  return {
    ok: true,
    fingerprint: paths.length > 0 ? fingerprintOfManifest(m.files) : null,
    testCount: paths.filter(isReviewScopeTestPath).length,
    files: m.files,
  };
}

function isValidRecordedManifest(rec) {
  return !!rec && typeof rec === "object" && rec.v === 1 &&
    !!rec.files && typeof rec.files === "object" && !Array.isArray(rec.files);
}

// Freshness SSOT shared by the commit gate and the write_code completion reopen.
// Order: unavailable → no-tests → missing → match | stale.
function evaluateReviewScopeFreshness(stepState, current) {
  if (!current || current.ok !== true) return { fresh: false, reason: "unavailable" };
  if (current.testCount === 0) return { fresh: true, reason: "no-tests" };
  const rec = stepState && stepState.review_scope_manifest;
  if (!isValidRecordedManifest(rec)) return { fresh: false, reason: "missing" };
  const currentFp = current.fingerprint || fingerprintOfManifest(current.files || {});
  return fingerprintOfManifest(rec.files) === currentFp
    ? { fresh: true, reason: "match" }
    : { fresh: false, reason: "stale" };
}

module.exports = {
  isReviewScopeExcludedPath,
  isReviewScopeTestPath,
  computeReviewScopeManifest,
  fingerprintOfManifest,
  computeReviewScopeFingerprint,
  evaluateReviewScopeFreshness,
};

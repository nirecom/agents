"use strict";
// The files bin/check-test-language-match.sh judges for hooks/block-case-markers.js (#2502 S4-7):
// every tests/ file this call writes outside tests/_archive/ and tests/lib/, new or existing,
// whatever its language (an unregistered one gets the CLI's TEST_LANGUAGE_UNSUPPORTED notice).
// A file HEAD has carries its HEAD blob, so the CLI blocks only a mismatch HEAD did not have.

const { spawnSync } = require("child_process");
const { resolveTargetPath, groupEditTargets } = require("../post-edit-content");

const HEAD_BLOB_MAX_BYTES = 16 * 1024 * 1024;

// headBlobOf — the HEAD blob of rel as a Buffer, or null when git cannot give it.
function headBlobOf(top, rel) {
  const r = spawnSync("git", ["show", `HEAD:${rel}`], {
    cwd: top,
    timeout: 5000,
    maxBuffer: HEAD_BLOB_MAX_BYTES,
  });
  if (r.error || r.status !== 0 || !Buffer.isBuffer(r.stdout)) return null;
  return r.stdout;
}

// collectLanguageMatchCandidates — [{rel, top, post, head}] (head: the HEAD blob, null for a new
// file). helpers: {repoRelOf, isInHead, postContentOf} of the hook. A file HEAD has whose blob
// git cannot give is left out: judging it as new could block a mismatch HEAD already had.
function collectLanguageMatchCandidates(input, toolName, toolInput, helpers) {
  const out = [];
  for (const group of groupEditTargets(toolName, toolInput, input)) {
    const absPath = resolveTargetPath(input, group.rawPath);
    if (!absPath) continue;
    const loc = helpers.repoRelOf(absPath);
    if (!loc || !loc.rel.startsWith("tests/") || /^tests\/(_archive|lib)\//.test(loc.rel)) continue;
    let head = null;
    if (helpers.isInHead(loc.top, loc.rel)) {
      head = headBlobOf(loc.top, loc.rel);
      if (head === null) continue;
    }
    const post = helpers.postContentOf(group, absPath);
    if (typeof post !== "string") continue;
    out.push({ rel: loc.rel, top: loc.top, post, head });
  }
  return out;
}

module.exports = { collectLanguageMatchCandidates, headBlobOf };

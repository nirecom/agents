"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/scan.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Recursion-depth cutoff (pathological nesting fails closed instead of being
// walked) and timeout-budget stress cases (large/long input must still
// resolve fast). Split into its own file since these two blocks use raw
// check() calls rather than runTable() tables — see ./harness.js.

const { check, pass, fail, scan } = require("./harness");

// --- Depth cutoff — pathological nesting fails closed instead of recursing on ---
{
  let nested = "echo hi";
  for (let i = 0; i < 9; i++) {
    nested = 'bash -c "' + nested.replace(/(["\\])/g, "\\$1") + '"';
  }
  check("depth: 9-deep bash -c nesting → fail-closed cutoff", scan(nested), true);
  check("depth: 2-deep bash -c nesting with harmless body stays false", scan("bash -c \"bash -c 'echo hi'\""), false);

  // MEDIUM: exact boundary. depth reaches 9 only on the 9th peel (cutoff is
  // `depth > 8`), so 8 layers must still evaluate real content instead of
  // being forced true by the cutoff — proven with both a harmless and a
  // recursive core at the SAME depth.
  let nested8 = "echo hi";
  for (let i = 0; i < 8; i++) {
    nested8 = 'bash -c "' + nested8.replace(/(["\\])/g, "\\$1") + '"';
  }
  check("depth: 8-deep nesting with a harmless core stays false (boundary, not over it)", scan(nested8), false);

  let nested8r = "rm -rf x";
  for (let i = 0; i < 8; i++) {
    nested8r = 'bash -c "' + nested8r.replace(/(["\\])/g, "\\$1") + '"';
  }
  check("depth: 8-deep nesting with a recursive-delete core still blocks on CONTENT, not the cutoff", scan(nested8r), true);
}

// --- LOW: timeout-budget stress — large/long input must still resolve fast ---
{
  const lines = [];
  for (let i = 0; i < 500; i++) lines.push("echo line" + i);
  lines.push("rm -rf x");
  const manyLines = lines.join("\n");
  const t0 = Date.now();
  const manyLinesResult = scan(manyLines);
  const manyLinesMs = Date.now() - t0;
  check("stress: 500 harmless lines + 1 real recursive delete still resolves true", manyLinesResult, true);
  if (manyLinesMs < 5000) pass("stress: 501-line command text scanned in " + manyLinesMs + "ms (well under the 60s suite timeout)");
  else fail("stress: 501-line scan took " + manyLinesMs + "ms", "<5000ms", manyLinesMs + "ms");

  const longPathCmd = "rm -rf " + "x".repeat(20000);
  const t1 = Date.now();
  const longPathResult = scan(longPathCmd);
  const longPathMs = Date.now() - t1;
  check("stress: rm -rf with a 20000-char path argument still blocks", longPathResult, true);
  if (longPathMs < 5000) pass("stress: 20000-char single-line command scanned in " + longPathMs + "ms");
  else fail("stress: 20000-char scan took " + longPathMs + "ms", "<5000ms", longPathMs + "ms");
}

"use strict";
// Test-only helper (#3138): measures whether the file system holding the OS temp area folds
// letter case. Not a test on its own (a .js file is a test only directly under tests/<category>/).
// The implementation decides folding by platform alone (foldsCase); a test whose expected value
// depends on the real file system uses this measurement to skip the combinations where the
// platform rule and the file system disagree (darwin on case-sensitive APFS, linux on a
// case-insensitive mount), and prints why.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

let cached = null;

// -> true when an entry created lower-case can be lstat-ed by its upper-case spelling.
function fsFoldsCase(dir = os.tmpdir()) {
  if (cached !== null && dir === os.tmpdir()) return cached;
  const root = fs.mkdtempSync(path.join(dir, "fs-case-probe-"));
  try {
    fs.writeFileSync(path.join(root, "probe-entry"), "");
    let folds;
    try {
      fs.lstatSync(path.join(root, "PROBE-ENTRY"));
      folds = true;
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
      folds = false;
    }
    if (dir === os.tmpdir()) cached = folds;
    return folds;
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

// -> a skip reason when the platform rule (win32 / darwin fold) disagrees with the measured
//    file system, else false. Usable directly as node:test's `{ skip }` option.
function platformRuleMismatch(platform = process.platform) {
  const ruleFolds = platform === "win32" || platform === "darwin";
  const measured = fsFoldsCase();
  if (ruleFolds === measured) return false;
  return `platform rule for ${platform} says fold=${ruleFolds}, but the temp file system measures fold=${measured}`;
}

module.exports = { fsFoldsCase, platformRuleMismatch };

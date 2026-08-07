// SSOT (CPR-SSOT) for single-use consumption of a state file whose removal is the
// authorization event (OFF-clearance `.claimed`, EMERGENCY-OFF provenance marker).
// Keyed on the claim file's exclusive-create ("wx"), not rename — rename is not a
// mutual-exclusion primitive on Windows (measured: N concurrent renameSync calls to
// distinct destinations all report success). Exclusion is content-keyed, not just
// path-keyed, so a new record at the same path is never blocked by a stale one.
// Returns "consumed" (this call removed exactly the inspected bytes) | "lost"
// (another consumer owns it, or it's gone/changed) | "failed" (I/O fault).
// Residual window: the identity re-read and unlink are two syscalls, so a writer
// that replaces the file between them can still lose its record — fail-open by
// design; closing it needs OS-level locking.
"use strict";

const fs = require("fs");
const crypto = require("crypto");

function claimPathFor(filePath, expectedRaw) {
  const id = crypto.createHash("sha256").update(String(expectedRaw)).digest("hex").slice(0, 16);
  return `${filePath}.consuming-${id}.tmp`;
}

function consumeExactFile(filePath, expectedRaw) {
  if (typeof expectedRaw !== "string") return "failed";
  const claimPath = claimPathFor(filePath, expectedRaw);
  let fd = null;
  try {
    fd = fs.openSync(claimPath, "wx", 0o600);
  } catch (e) {
    // EEXIST: another consumer is already consuming exactly these bytes.
    return e && e.code === "EEXIST" ? "lost" : "failed";
  }
  try {
    // Identity check INSIDE the exclusive window: only the exact bytes the caller
    // inspected may be removed, so a pathname recycled since the caller's read
    // (stale claim swept -> new claim minted and claimed) is left alone.
    let current = null;
    try {
      current = fs.readFileSync(filePath, "utf8");
    } catch (e) {
      if (!e || e.code !== "ENOENT") return "failed";
      current = null; // already gone — someone else consumed it
    }
    if (current !== expectedRaw) return "lost";
    try {
      fs.unlinkSync(filePath);
    } catch (e) {
      return e && e.code === "ENOENT" ? "lost" : "failed";
    }
    return "consumed";
  } finally {
    try { fs.closeSync(fd); } catch (_e) {}
    try { fs.unlinkSync(claimPath); } catch (_e) {}
  }
}

module.exports = { consumeExactFile };

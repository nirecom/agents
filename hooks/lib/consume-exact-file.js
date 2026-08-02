// hooks/lib/consume-exact-file.js
// SSOT (CPR-2) for SINGLE-USE consumption of a state file whose removal is the
// authorization event: the OFF-clearance `.claimed` file and the EMERGENCY-OFF
// provenance marker. Both are consumed by more than one entrypoint
// (hooks/workflow-mark/enforce-override-handlers/off-clearance.js and
// bin/request-off-clearance), so per rules/coding/file-split.md the primitive
// lives in the shared hooks/lib/ layer rather than being copied into each.
//
// THE PROBLEM IT SOLVES (#1780 round-5 M-2/M-3)
//   `read the file -> decide -> unlink the path` races on the PATHNAME, not on
//   identity. Between the read and the unlink another consumer can remove the
//   file and a writer can create a DIFFERENT file at the same path, so the
//   unlink destroys a live record that was never inspected — and, worse, N
//   consumers can all read the one file and all treat their unlink as "I
//   consumed it" (ENOENT read as "already gone, counts as mine"). One grant, or
//   one human invocation, then vouches for N activations.
//
// WHY `wx` AND NOT `rename` (measured on this platform, not assumed)
//   The obvious fix — rename the file to a private name so only one racer can
//   take it — DOES NOT HOLD ON WINDOWS. Measured with 6 concurrent Node
//   processes renaming one source file to 6 distinct destinations: ALL SIX
//   fs.renameSync() calls returned success and exactly one destination existed
//   afterwards (libuv opens the source with FILE_SHARE_DELETE and renames by
//   handle, so several processes hold the same file object and each rename moves
//   that same object again). rename is therefore NOT a mutual-exclusion
//   primitive here. Exclusive create is: the same harness with 8 concurrent
//   fs.openSync(path, "wx") calls produced exactly ONE winner and 7 EEXIST, in
//   every round, which is also why the claim in hooks/supervisor-off-proposal-shim.js
//   is a `wx` open (CPR-8: one rule that holds on POSIX and Windows alike).
//
// THE CONTRACT
//   consumeExactFile(filePath, expectedRaw) -> "consumed" | "lost" | "failed"
//     "consumed" — THIS call removed exactly the bytes the caller inspected. It
//                  is the only outcome that may be attributed/audited as a use.
//     "lost"     — another consumer owns those bytes (EEXIST on the claim), or
//                  the file is gone, or the pathname now holds different bytes.
//                  Nothing was removed by this call; attribute nothing.
//     "failed"   — a real I/O fault. Nothing was reliably removed; the caller
//                  should surface it (under-attribution, never over-attribution).
//
//   Exclusion is keyed to the CONTENT, not just the path: two consumers racing on
//   the same bytes are mutually exclusive, while a genuinely new record written at
//   the same path is a new event and is not blocked by a leftover from the old one.
//   The claim file is deleted on the way out; a crash leaves a `.tmp` file that the
//   existing 24h transient sweep in hooks/workflow-state/state-io/zombie-cleanup.js
//   reaps, and until then the only effect is under-attribution of that exact record.
//
//   RESIDUAL WINDOW (stated honestly): the identity re-read and the unlink are two
//   syscalls, so a writer that replaces the file between them can still lose its
//   record. Closing that would need OS-level file locking; every consumer of this
//   module is fail-open by design, and the window is microseconds against events
//   (a Phase1 examination, a user prompt) that are orders of magnitude slower.
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

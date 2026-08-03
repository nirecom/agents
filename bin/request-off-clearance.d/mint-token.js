#!/usr/bin/env node
"use strict";
// Mints the OFF-clearance token and clears any stale claim for this SID, inside the
// SID-scoped exclusive mint lock (hooks/lib/off-clearance-mint-lock.js). Reads TOKEN_*
// env vars from the caller. Exit 0 on success, exit 3 on lock timeout (caller reports
// UNAVAILABLE), nonzero otherwise. Mint + stale-claim clear run as one process — splitting
// them across a process boundary is what opened the race this closes.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const now = Date.now();
// mint_nonce identifies THIS grant; the shim copies it into the claim it writes, so a
// claim is attributable back to the exact grant it belongs to.
const token = {
  target: process.env.TOKEN_TARGET,
  category: process.env.TOKEN_CATEGORY,
  urgency: process.env.TOKEN_URGENCY,
  minted_at: new Date(now).toISOString(),
  expires_at: new Date(now + 15 * 60 * 1000).toISOString(),
  verdict_reason: process.env.TOKEN_REASON,
  detail: process.env.TOKEN_DETAIL,
  mint_nonce: crypto.randomBytes(16).toString("hex"),
};
const p = process.env.TOKEN_PATH;

// SID-scoped mint lock: serializes mint+rename+stale-claim-clear as one exclusive window
// (also acquired by the shim's claim lifecycle), closing a race where two concurrent
// actors could publish under different nonces while a stale-claim-clear reads the wrong
// one and deletes a live claim. Exclusive-create ("wx"), not rename — rename is not a
// mutual-exclusion primitive on Windows. Fails closed (exit 3) on timeout.
//
// Lock basename ends in ".tmp" so the existing 24h zombie sweep reaps an orphaned lock
// after a hard crash; protected-basenames.js blocks tool-issued writes/deletes of it too.
const { acquireMintLock, releaseMintLock } = require(
  process.env.AGENTS_CONFIG_DIR + "/hooks/lib/off-clearance-mint-lock.js"
);
const LOCK_WAIT_BUDGET_MS = 5000;
const LOCK_POLL_MS = 25;
const lock = acquireMintLock(p, LOCK_WAIT_BUDGET_MS, LOCK_POLL_MS);
if (!lock) process.exit(3);
try {
  // Per-process-unique temp path (pid+random): a shared temp name let two concurrent
  // mints for the same SID cross-contaminate each other's token before renaming. Kept
  // as defense-in-depth even though the SID lock above now serializes whole mints.
  const mintTmp = p + ".mint." + process.pid + "." + crypto.randomBytes(6).toString("hex") + ".tmp";
  const mintFd = fs.openSync(mintTmp, "w", 0o600);
  try {
    fs.writeFileSync(mintFd, JSON.stringify(token));
    // fsync before rename: without it, a crash right after rename can leave the renamed
    // target zero-length/truncated on some filesystems.
    fs.fsyncSync(mintFd);
  } finally {
    fs.closeSync(mintFd);
  }
  fs.renameSync(mintTmp, p);

  // A fresh grant supersedes any stale claim from an older grant (without this, a
  // declined proposal would deadlock this SID until zombie cleanup). Only a claim that
  // does NOT carry this grant's mint_nonce is stale — a claim with a different/missing
  // nonce is removed via consumeExactFile(), which re-verifies content under an
  // exclusive window before deleting (a plain read-then-unlink raced a second remover).
  const { consumeExactFile } = require(
    process.env.AGENTS_CONFIG_DIR + "/hooks/lib/consume-exact-file.js"
  );
  const claimed = p + ".claimed";
  let priorRaw = null;
  try {
    priorRaw = fs.readFileSync(claimed, "utf8");
  } catch (e) {
    priorRaw = null; // ENOENT: nothing to clear. Any other error: leave it untouched.
  }
  if (priorRaw !== null) {
    let belongsToThisGrant = false;
    try {
      const prior = JSON.parse(priorRaw);
      belongsToThisGrant =
        !!prior && typeof prior === "object" && prior.mint_nonce === token.mint_nonce;
    } catch (e) {
      belongsToThisGrant = false; // unparseable: cannot prove it's this grant's, so stale
    }
    if (!belongsToThisGrant) consumeExactFile(claimed, priorRaw);
  }

  // Directory-entry fsync: renameSync/claim-removal are directory mutations that can be
  // lost on crash even though file content was fsynced. Best-effort only — opening a
  // directory to fsync it throws on Windows/MSYS, so failure here must never fail the mint.
  try {
    const dirFd = fs.openSync(path.dirname(p), "r");
    try { fs.fsyncSync(dirFd); } finally { fs.closeSync(dirFd); }
  } catch (_e) { /* directory fsync unsupported on this platform/filesystem */ }
} finally {
  // Always release so a crash mid-mint doesn't wedge future mints for this SID.
  releaseMintLock(lock);
}

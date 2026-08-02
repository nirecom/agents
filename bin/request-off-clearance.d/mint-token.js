#!/usr/bin/env node
"use strict";
// bin/request-off-clearance.d/mint-token.js — extracted from bin/request-off-clearance
// under the file-split HARD limit (rules/coding/file-split.md); see the sibling-folder
// naming note in ./parse-verdict.js's header.
//
// Mints the OFF-clearance token and clears any stale claim for the same SID, inside the
// SID-scoped exclusive mint lock (hooks/lib/off-clearance-mint-lock.js). Reads TOKEN_*
// env vars set by the caller; exit 0 on success, exit 3 when the mint lock could not be
// acquired (reported by the caller as an UNAVAILABLE examination), any other nonzero on
// a mint failure.
//
// The mint and the stale-claim clear are ONE process (#1780 M-3): they are two steps of
// a single transition, and splitting them across a process boundary is what opened the
// race the clear step now closes by content.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const now = Date.now();
// mint_nonce identifies THIS grant. The shim spreads the whole token into the .claimed
// file it writes, so the nonce travels into the claim and makes a claim attributable to
// the exact grant it belongs to.
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

// #1780 round-13 HIGH-1 — SID-SCOPED MINT LOCK.
//
// Per-process-unique temp paths (see the codex HIGH-1 note below) stopped two
// concurrent mints from cross-contaminating each other's TEMP file, but they do not
// serialize the three-step transition as a whole. The surviving race: process A renames
// its token to the shared path `p` (nonce nA); process B then renames its token to the
// same `p` (nonce nB) — that second rename is what makes the published grant B's; the
// shim claims the now-B-owned token, writing `p + ".claimed"` with nonce nB; A's
// stale-claim-clear finally runs, reads that claim, sees nB != its own in-memory nA, and
// deletes B's LIVE single-use record — destroying both the single-use lock and the only
// audit evidence of the claim. The steps race because they interleave, so the fix is to
// stop them interleaving: mint + rename + clear all happen inside one exclusive window.
//
// #1780 round-14 HIGH: this lock is no longer mint-vs-mint only. The shim's
// claim-lifecycle (validate + claim + unlink) in hooks/supervisor-off-proposal-shim.js
// acquires the SAME lock, keyed off the same bare-token path, before touching the bare
// token / claim pair — see hooks/lib/off-clearance-mint-lock.js for the full race this
// closes and why the acquire/release primitive is shared (CPR-2) rather than duplicated.
//
// The mutex primitive is an exclusive-create (`wx`) open, NOT a rename — see the header
// of hooks/lib/consume-exact-file.js for the measurement showing rename is not a
// mutual-exclusion primitive on Windows (CPR-8: one rule that holds on POSIX and Windows
// alike). This lock is coarse (whole transition, one SID) and short-lived (a CLI
// invocation), so a busy-retry poll is adequate; it is not a server lock and no fairness
// is required.
//
// FAIL CLOSED on timeout: exit 3, which the bash caller reports as an UNAVAILABLE
// examination plus the standard emergency_hint — proceeding without the lock would
// reinstate exactly the race above.
//
// ZOMBIE-CLEANUP COVERAGE: the lock basename ends in `.tmp` deliberately, so the
// existing 24h transient sweep in hooks/workflow-state/state-io/zombie-cleanup.js
// already reaps a lock orphaned by a hard crash (it unlinks every `*.tmp` under the
// workflow dir older than 24h) — no new sweep rule is needed. The protected-basename
// SSOT in hooks/lib/protected-basenames.js now also lists
// `.off-clearance.mint.lock.tmp` in OFF_CLEARANCE_TOKEN_SUFFIXES (#1780 round-14
// HIGH-2), so a tool-issued write can no longer pre-create or delete this lock to
// wedge/hijack mints for this SID.
const { acquireMintLock, releaseMintLock } = require(
  process.env.AGENTS_CONFIG_DIR + "/hooks/lib/off-clearance-mint-lock.js"
);
const LOCK_WAIT_BUDGET_MS = 5000;
const LOCK_POLL_MS = 25;
const lock = acquireMintLock(p, LOCK_WAIT_BUDGET_MS, LOCK_POLL_MS);
if (!lock) process.exit(3);
try {
  // codex HIGH-1: the temp path used to be the bare `p + ".mint.tmp"` — shared by
  // every invocation for this SID. Two `request-off-clearance` runs for the SAME
  // session racing this node process (a retried CLI call, two subagents sharing a
  // session id) could each write that one pathname before either renamed it, so one
  // process's rename could publish the OTHER's token under its own mint_nonce while
  // this process still holds its own (now-stale) `token.mint_nonce` in memory — the
  // stale-claim-clear below would then judge a live claim (matching what is actually
  // on disk) as belonging to a different grant and delete it. A per-process-unique
  // suffix (pid + random) makes the two writes land on different paths, so the race
  // can no longer cross-contaminate; the final `p` is still reached only via each
  // process's own `renameSync`, which is atomic per POSIX/NTFS rename semantics.
  // (Retained even though the SID lock above now serializes whole mints: it is the
  // only thing that still holds if the lock is ever bypassed or removed.)
  const mintTmp = p + ".mint." + process.pid + "." + crypto.randomBytes(6).toString("hex") + ".tmp";
  // codex MEDIUM-2: writeFileSync alone leaves the token in the OS page cache; a
  // crash between this write and the rename below could lose it while the
  // stale-claim-clear step (which runs only after the rename) never even starts — so
  // that failure mode is safe on its own. The fsync here closes the narrower window
  // where the rename itself succeeds but the file's content was never flushed before
  // an immediate crash, which on some filesystems can surface the renamed target as
  // zero-length or truncated.
  const mintFd = fs.openSync(mintTmp, "w", 0o600);
  try {
    fs.writeFileSync(mintFd, JSON.stringify(token));
    fs.fsyncSync(mintFd);
  } finally {
    fs.closeSync(mintFd);
  }
  fs.renameSync(mintTmp, p);

  // A fresh, examiner-approved grant supersedes any leftover claim (#1626): the claim
  // file is what makes a token single-use, so only a new Phase1 examination may clear
  // it. Without this, a declined "ask" dialog would deadlock this sid until zombie
  // cleanup (7d). Cleared ONLY after the new bare token is durably minted above (codex
  // round-4 HIGH): clearing it first would, on a later mint failure, leave the OLD bare
  // token in place with its single-use lock removed — making an already-spent grant
  // replayable within its original expiry window.
  //
  // #1780 M-3: the clear used to be an unconditional `rm -f`, which cannot tell an OLD
  // grant's claim from a claim for the token minted microseconds earlier on this very
  // line. A concurrent proposal that claimed the NEW token in that window had its claim
  // deleted — destroying the single-use record of a live grant and the audit trail's
  // only evidence of the claim.
  //
  // THE GUARANTEE, EXACTLY: a claim is removed only when its contents prove it belongs
  // to a DIFFERENT grant than the one just minted (a different mint_nonce, or none at
  // all — a pre-#1780 claim, necessarily older). A claim carrying this grant's nonce is
  // never removed.
  //
  // #1780 round-5 M-2: that guarantee used to be enforced by a read-then-unlink pair
  // whose comment claimed no lock was needed, because only the shim's exclusive `wx`
  // open can create .claimed and the stale file occupies the path until then. That
  // reasoning omitted the SECOND remover — consumeOffClearance() in
  // hooks/workflow-mark/enforce-override-handlers/off-clearance.js, which removes the
  // claim on OFF activation. It can delete the stale claim mid-window, the shim can then
  // create a NEW claim at the freed pathname, and the unlink would delete a live claim
  // whose contents were never inspected. The pair raced on the PATHNAME, not on identity.
  //
  // Removal is now IDENTITY-BOUND: consumeExactFile() re-verifies, inside an exclusive
  // window, that the pathname still holds the exact bytes judged stale here, and removes
  // nothing otherwise. See hooks/lib/consume-exact-file.js for the primitive and why it
  // is an exclusive create rather than a rename.
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
      // Unreadable/unparseable: it cannot prove it belongs to this grant, so it is
      // stale by the same rule (workflow-mark audits the malformed-claim sweep).
      belongsToThisGrant = false;
    }
    // A claim carrying THIS grant's nonce is a concurrent proposal that claimed the
    // token minted microseconds ago: it is the single-use record of a LIVE grant and
    // must survive untouched. Everything else is a leftover from an older grant.
    if (!belongsToThisGrant) consumeExactFile(claimed, priorRaw);
  }

  // #1780 round-13 MEDIUM-1 — DIRECTORY-ENTRY DURABILITY.
  //
  // The fsync above flushes the token's CONTENT; nothing flushed the DIRECTORY ENTRIES
  // that publish it. `renameSync` and the claim removal are both directory-entry
  // mutations, and on a crash either can be lost while a concurrent reader has already
  // observed and acted on the post-mutation state — the exact symmetric counterpart
  // (CPR-5) of the content risk the codex MEDIUM-2 comment above describes. One fsync of
  // the containing directory after ALL mutating work closes both windows at once.
  //
  // POSIX-ONLY PRIMITIVE: opening a directory to fsync it is not portable —
  // Windows/MSYS filesystems (this repo's dev/CI environment) throw EPERM or EISDIR from
  // fs.openSync on a directory. Best-effort by design: a platform that cannot do this is
  // left exactly where it was before, and the mint must never fail because of it.
  try {
    const dirFd = fs.openSync(path.dirname(p), "r");
    try { fs.fsyncSync(dirFd); } finally { fs.closeSync(dirFd); }
  } catch (_e) { /* directory fsync unsupported on this platform/filesystem */ }
} finally {
  // Always release, so a crash mid-mint cannot permanently wedge future mints for this
  // SID (and see the zombie-cleanup note at the lock acquisition above for the hard-crash
  // case, where no finally runs at all).
  releaseMintLock(lock);
}

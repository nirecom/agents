#!/usr/bin/env node
"use strict";
// run-loop-step.js — phase=loop_step state mutations for the issue-close-finalize worker
// Usage: node run-loop-step.js <state_file_path> <g5_decision> [expected_state_token]
// Env:   FINALIZE_SCRIPTS_DIR
// Stdout: STATUS=<value>\nSUMMARY=<value> — exit 0 always; check STATUS.
// COMPARE-AND-SWAP: the caller validated the state file in another process and one G.5
// pass posts a GitHub comment on the way, so a stale read-modify-write would drop
// g5_3a_completed and re-post it. The token is a digest of the exact bytes read, checked
// on entry against the caller's token, before every write, and before step-g5-loop.sh.
// MUTUAL EXCLUSION: check-then-rename is two syscalls, so an exclusive `wx` lock file
// serializes the whole pass; the token still covers writers that never took the lock.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
// The writer of the state file owns its schema version; this reader accepts exactly that one.
const { SCHEMA_VERSION } = require(
  path.join(SCRIPT_CHECKOUT_ROOT, "bin", "worker-dispatch", "workers", "issue-close-finalize", "state.js"),
);

const [, , stateFilePath, g5Decision, expectedToken] = process.argv;
const finalizeScriptsDir = process.env.FINALIZE_SCRIPTS_DIR;

function out(status, summary) {
  process.stdout.write(`STATUS=${status}\nSUMMARY=${summary}\n`);
}

function tokenOf(raw) {
  return crypto.createHash("sha256").update(String(raw)).digest("hex");
}

function readState(p) {
  try {
    const raw = fs.readFileSync(p, "utf8");
    const s = JSON.parse(raw);
    if (s.schema_version !== SCHEMA_VERSION) {
      throw new Error(`schema_version must be ${SCHEMA_VERSION}, got ${s.schema_version}`);
    }
    return { state: s, token: tokenOf(raw) };
  } catch (e) {
    out("failed", `state file read/parse error: ${e.message}`);
    process.exit(0);
  }
}

// Report whether the file still holds the bytes this pass read: null when
// unchanged, else the reason. Kept separate from the abort so that a caller which
// has ALREADY performed an irreversible action can say something different about
// the same conflict.
function conflictReason(p, token) {
  let raw = null;
  try {
    raw = fs.readFileSync(p, "utf8");
  } catch (e) {
    return `it disappeared after it was read (${e.message})`;
  }
  if (tokenOf(raw) !== token) {
    return "it changed after it was read — another finalize pass is writing it";
  }
  return null;
}

// Abort — never write — when the file is no longer the one this pass read.
function assertUnchanged(p, token) {
  const reason = conflictReason(p, token);
  if (reason === null) return;
  out("failed", `state file conflict: ${reason}; re-run this pass`);
  process.exit(0);
}

// `postedNote`, when given, describes an external action this pass already
// performed and cannot undo. On a conflict the note REPLACES the "re-run this
// pass" advice, because re-running would repeat that action: the write which was
// supposed to record it is the one being refused, so nothing on disk remembers it
// happened. The operator is told to reconcile the state file by hand instead.
//
// The temp name is unique per writer — a fixed `<p>.tmp` is shared between every
// process writing this file, so two passes would interleave their bytes into one
// path and the loser's rename would publish a document neither composed.
function writeState(p, s, token, postedNote) {
  const reason = conflictReason(p, token);
  if (reason !== null) {
    out(
      "failed",
      postedNote
        ? `state file conflict: ${reason}. ${postedNote}`
        : `state file conflict: ${reason}; re-run this pass`,
    );
    process.exit(0);
  }
  const tmp = `${p}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
  fs.renameSync(tmp, p);
}

// --- exclusive lock --------------------------------------------------------
//
// Held for the whole pass, released on ANY exit (`out()` is always followed by
// process.exit(0), so an exit hook — not a finally — is what actually runs).
// A crashed pass would otherwise leave its lock behind forever, so a lock older
// than one pass's budget is treated as abandoned and reclaimed exactly once.
const LOCK_STALE_MS = 30000;

function tryAcquire(lockPath) {
  try {
    fs.writeFileSync(lockPath, String(process.pid), { flag: "wx" });
    return null;
  } catch (e) {
    return e && e.code ? e.code : "UNKNOWN";
  }
}

function acquireLock(p) {
  const lockPath = `${p}.lock`;
  let code = tryAcquire(lockPath);
  if (code === "EEXIST") {
    let ageMs = LOCK_STALE_MS + 1;
    try {
      ageMs = Date.now() - fs.statSync(lockPath).mtimeMs;
    } catch (_e) {
      // It vanished between the failed create and the stat — the owner finished.
      ageMs = LOCK_STALE_MS + 1;
    }
    if (ageMs > LOCK_STALE_MS) {
      try {
        fs.unlinkSync(lockPath);
      } catch (_e) {
        // Another pass reclaimed it first; the retry below decides.
      }
      code = tryAcquire(lockPath);
    }
  }
  if (code === null) {
    process.on("exit", () => {
      try {
        fs.unlinkSync(lockPath);
      } catch (_e) {
        // Already gone — nothing to release.
      }
    });
    return lockPath;
  }
  out(
    "failed",
    code === "EEXIST"
      ? "state file is locked by another finalize pass — retry"
      : `state file lock could not be acquired (${code})`,
  );
  process.exit(0);
}

function runBash(args, env = {}) {
  const result = spawnSync("bash", args, {
    env: { ...process.env, ...env },
    encoding: "utf8",
  });
  return {
    rc: result.status ?? 1,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
  };
}

function parseKV(text) {
  const kv = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) kv[m[1]] = m[2];
  }
  return kv;
}

const { state, token: stateToken } = readState(stateFilePath);

// Taken before any decision is made on what was read, so no other pass can slip
// a write in between this pass's read and its rename.
acquireLock(stateFilePath);

// The caller validated a specific set of bytes; if what this process read is not
// those bytes, the validation does not cover this write.
if (expectedToken !== undefined && expectedToken !== "" && expectedToken !== stateToken) {
  out("failed", "state file conflict: it changed between the caller's validation and this pass");
  process.exit(0);
}

const last = state.g5_history && state.g5_history[state.g5_history.length - 1];

if (!last) {
  out("failed", "g5_history is empty — cannot process loop_step");
  process.exit(0);
}

if (g5Decision === "decline" || g5Decision === "llm_declined") {
  last.user_decision = g5Decision;
  state.proposal_counters = state.proposal_counters || { accepted: 0, declined: 0, skipped: 0 };
  state.proposal_counters.declined = (state.proposal_counters.declined || 0) + 1;
  state.phase = "terminal";
  writeState(stateFilePath, state, stateToken);
  out("terminal", `loop_step ${g5Decision} recorded — phase=terminal`);

} else if (g5Decision === "accept") {
  // Both in-memory mutations that describe a SUCCESSFUL accept are decided up
  // front, so that nothing but the write itself sits between the irreversible
  // comment post and the record of it. `phase` is only ever published by
  // writeState, and every failure path below exits before reaching it.
  state.phase = "awaiting_recursion";
  let postedNote = null;
  if (!last.g5_3a_completed) {
    // The proposal comment cannot be un-posted: check the swap BEFORE it, not
    // only before the write that records it.
    assertUnchanged(stateFilePath, stateToken);
    const res = runBash(
      [path.join(finalizeScriptsDir, "step-g5-loop.sh"), "execute", String(last.proposal_parent), "accept"],
      { OWNER_REPO: state.owner_repo }
    );
    if (res.rc !== 0) {
      out("failed", `step-g5-loop.sh execute failed: ${res.stderr.trim()}`);
      process.exit(0);
    }
    last.g5_3a_completed = true;
    // From here on a conflict is not a "retry me": the comment on
    // #<proposal_parent> is already live and re-running would post it twice.
    postedNote =
      `WARNING: the G.5-3a proposal comment for #${last.proposal_parent} WAS ALREADY POSTED but could not be recorded. Do NOT re-run this pass — reconcile the state file manually (set the last g5_history entry's g5_3a_completed to true) before continuing.`;
  }
  writeState(stateFilePath, state, stateToken, postedNote);
  out("awaiting_recursion", "g5 accept: G.5-3a done, awaiting recursion");

} else if (g5Decision === "recurse_done") {
  last.recursion_completed = true;
  state.proposal_counters = state.proposal_counters || { accepted: 0, declined: 0, skipped: 0 };
  state.proposal_counters.accepted = (state.proposal_counters.accepted || 0) + 1;
  state.current_issue_number = last.proposal_parent;
  state.g5_loop_iteration = (state.g5_loop_iteration || 0) + 1;

  // Run G.5-1 for new current_issue_number
  const res = runBash(
    [path.join(finalizeScriptsDir, "step-g5-loop.sh"), "prepare", String(state.current_issue_number)],
    { OWNER_REPO: state.owner_repo }
  );
  const kv = parseKV(res.stdout);
  const newEntry = {
    iteration: (state.g5_loop_iteration || 1),
    issue_number: String(state.current_issue_number),
    proposal_status: kv.PROPOSAL_STATUS || "skipped",
    proposal_parent: kv.PROPOSAL_PARENT ? parseInt(kv.PROPOSAL_PARENT) : null,
    user_decision: null,
    g5_3a_completed: false,
    recursion_completed: false,
  };
  state.g5_history = state.g5_history || [];
  state.g5_history.push(newEntry);
  state.phase = "init_done";
  writeState(stateFilePath, state, stateToken);
  out("init_done", `recurse_done: advanced to #${state.current_issue_number}`);

} else {
  out("failed", `unknown g5_decision: ${g5Decision}`);
}

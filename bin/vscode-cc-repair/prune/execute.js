// The destructive half of the prune pass, split out of prune.js when that file reached
// the 500-line hard limit. prune.js only READS — it walks the roots, classifies, and
// decides what a deletion would have to be justified by. Everything here acts on that
// plan, and this module holds the ONE place in the repository where a session file is
// displaced.
//
// Nothing is destroyed, and no earlier rescue copy is destroyed either. The stub is
// RENAMED to `<uuid>.jsonl.bak` when that name is free; when a `.bak` is already there it
// is the rescue copy of an EARLIER stub — Claude Code recreates a stub under the same uuid,
// so a second prune of the same session is the ordinary case — and that copy holds a title
// that exists nowhere else, so it is left completely untouched and this run's stub is
// renamed to `<uuid>.jsonl.bak.YYYYMMDD_HHMMSS` beside it. Generations accumulate rather
// than overwrite, which is what rules/coding.md sanctions "when history preservation is
// needed", and it is the same policy the patch path applies to the bundle backup.
//
// Reverting is dropping the suffix: `mv <uuid>.jsonl.bak[.<ts>] <uuid>.jsonl`, choosing the
// generation by its timestamp (the plain `.bak` is the oldest). The `backup=` field on the
// report line names the file this run actually wrote, so the report alone is enough.
// SESSION_FILE_PATTERN is anchored on `.jsonl$`, so neither spelling is a session file to
// this tool nor a session to the VS Code extension — they are inert bytes. That is what
// makes the residual TOCTOU window between the re-verification and the rename survivable.
//
// prune.js and this module reference each other by design (it owns classification, this
// owns execution), so the back-reference is resolved at CALL time rather than at load
// time — by the time any plan is executed, prune.js is fully loaded.
'use strict';

const fs = require('fs');
const path = require('path');

const { verifyCounterpart } = require('./verify');
const { caseFoldPath, realPathKey } = require('../primitives');

// The suffix that makes a displaced stub invisible to both readers of this directory.
const BACKUP_SUFFIX = '.bak';

// prune.js (the reading half) is reached through this rather than through a top-level
// require: the two modules reference each other, and a load-time require would capture
// prune.js's exports before they exist. require() is cached, so this is a Map lookup.
function classifierModule() {
  return require('../prune');
}

function zeroTally() {
  return {
    pruned: 0,
    wouldPrune: 0,
    kept: 0,
    changed: 0,
    unreadable: 0,
    unclassified: 0,
    failed: 0,
  };
}

// State -> tally slot. A Map rather than an object literal, for the same reason
// verify.js's CONTENT_PAYLOAD is one: the state string reaches this lookup from a
// caller-supplied plan, and on an object literal `constructor` / `__proto__` / `toString`
// would each inherit a truthy value from Object.prototype and address a slot that is not
// a slot — writing NaN into the tally every consumer reads as a real counter.
const TALLY_KEY = new Map([
  ['pruned', 'pruned'],
  ['would-prune', 'wouldPrune'],
  ['kept', 'kept'],
  ['changed', 'changed'],
  ['unreadable', 'unreadable'],
  ['unclassified', 'unclassified'],
  ['failed', 'failed'],
]);

// Which state a failed verification maps to at EXECUTE time, where the counterpart DID
// verify during planning. A failure now means the file moved under us: that is a race
// correctly detected and refused, which is a decision reached (exit 0), not a fault.
// EACCES is the exception — it means the copy could not be observed at all, which no
// re-run can be assumed to fix.
function executeFailureState(result) {
  if (result.reason === 'unreadable' && result.code !== 'ENOENT') {
    return { state: 'unreadable', reason: result.code, scope: 'counterpart' };
  }
  if (result.reason === 'verify-truncated') {
    return { state: 'unclassified', reason: 'verify-truncated' };
  }
  return { state: 'changed', reason: 'counterpart-changed' };
}

// The only place in this repository where a session file is displaced.
//
// Every displacement is preceded, in this function and immediately before the syscall, by
// BOTH halves of the original decision being re-established against the live disk: the
// stub must still be a stub carrying exactly the titles it was judged on (I4), and the
// counterpart must still hold this session's transcript (I2). Anything else aborts — a
// refused race is reported as `changed` and costs nothing.
function executePrunePlan(options) {
  const opts = options || {};
  const plan = Array.isArray(opts.plan) ? opts.plan : [];
  const dryRun = opts.dryRun === true;
  const onEntry = typeof opts.onEntry === 'function' ? opts.onEntry : () => {};
  const tally = zeroTally();

  for (const entry of plan) {
    // Array.isArray(opts.plan) guards the CONTAINER and nothing inside it, and the first
    // thing done to an element is `.action`: a null element throws before any outcome
    // exists, out of the whole batch, and a primitive one is quieter but no better —
    // `42..action` is undefined, TALLY_KEY misses, and the entry is reported to onEntry
    // while being counted nowhere, so the tally under-states what the run looked at.
    // The shape is asserted, never the vocabulary: an action name this executor does not
    // know is the planner's business and still reaches the passthrough branch below.
    const malformed = !isPlanEntry(entry);
    const decision = malformed ? {} : entry;
    const outcome = malformed
      ? { state: 'failed', reason: 'not-a-plan-entry' }
      : decision.action === 'prune-candidate'
        ? prunable(decision, dryRun)
        : {
          state: decision.action === 'keep' ? 'kept' : decision.action,
          reason: decision.reason,
          scope: decision.scope,
        };

    const key = TALLY_KEY.get(outcome.state);
    if (key) tally[key] += 1;
    onEntry({
      file: decision.file,
      root: decision.root,
      state: outcome.state,
      reason: outcome.reason,
      scope: outcome.scope,
      via: outcome.via,
      backup: outcome.backup,
      realCopies: decision.realCopies,
    });
  }

  return tally;
}

// Is this element of a caller-supplied plan an entry at all? A plain object carrying a
// non-empty string `action`, because that field is the one the loop reads next and a plan
// entry that cannot name its own verdict can be tallied nowhere. Arrays are objects and are
// excluded for the same reason: they carry no action.
function isPlanEntry(entry) {
  if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) return false;
  return typeof entry.action === 'string' && entry.action !== '';
}

// Is this the I4 evidence, or merely something in its place? A Set of titleKey() strings is
// what the planner produces; an Array is the same claim after a JSON round trip, and
// sameKeys has always accepted any iterable. Nothing else is a claim about the disk.
function isTitleKeySet(value) {
  return value instanceof Set || Array.isArray(value);
}

// Is `file` inside `root`? Decided on CANONICALIZED paths and at a SEGMENT boundary, so
// that `/a/rootlike` is not inside `/a/root` however the two strings compare, while a
// spelling full of `.` and `..` that genuinely resolves inside the root is accepted.
// realPathKey already swallows a canonicalization fault and falls back to the resolved
// spelling, and the whole thing is wrapped besides: this runs before any syscall that
// could displace a file, so it owes an answer rather than an exception.
function isWithinRoot(file, root) {
  if (typeof root !== 'string' || root === '') return false;
  try {
    const rootKey = realPathKey(root);
    const fileKey = realPathKey(file);
    if (fileKey === rootKey) return true;
    return fileKey.startsWith(rootKey.endsWith(path.sep) ? rootKey : rootKey + path.sep);
  } catch { return false; }
}

// Is `decision.via` a file entitled to authorise this deletion? The I2 re-verification
// that follows asks only what a file CONTAINS, so without this the evidence could be any
// path at all — a plain `.txt` holding one line tagged with the session id passes I2 and
// is not a copy of anything. executePrunePlan is a public export, so a caller-supplied
// plan must satisfy the same boundary the evidence was collected under: a counterpart is
// a session file, of the SAME basename (same session, different project directory), never
// the stub itself under any spelling, and both sides live under the roots the plan states
// for them — otherwise `root` could name a harmless directory while `file` names any
// title-only uuid-shaped .jsonl anywhere on disk.
//
// Every condition is answered, never thrown: this is the last gate before the rename, and
// a plan that fails it is a caller error reported as `failed` rather than a crash that
// abandons the rest of the batch half-executed.
function isCounterpartPath(decision) {
  const { SESSION_FILE_PATTERN } = classifierModule();
  const via = decision.via;
  const viaFile = via == null ? null : via.file;
  // Both halves of the plan's path pair are dereferenced by path.relative once this returns
  // true, and path.relative throws on anything that is not a string. The type is therefore
  // part of the boundary, not a separate concern: every comparison below used to reach its
  // answer through String(), so a one-element Array — or any object with a matching
  // toString — satisfied all of them and then threw one line later, out of the whole batch.
  // Coercion did not accept those spellings, it only hid that it was the wrong question.
  if (typeof viaFile !== 'string') return false;
  if (typeof via.root !== 'string') return false;
  // The same rule on the target side, for the same reason (CPR-ORTH): prunable() has already
  // established this, and this function is a public export reached by callers who have not.
  if (typeof decision.file !== 'string') return false;
  const viaBase = path.basename(viaFile);
  if (!SESSION_FILE_PATTERN.test(viaBase)) return false;
  // The platform's own case rule, shared with the duplicate-basename grouping key: folding
  // where the filesystem does not would let two distinct sessions authorise each other.
  if (caseFoldPath(viaBase) !== caseFoldPath(path.basename(decision.file))) return false;
  // Identity, not spelling: a junction, a symlink or a case variant all reach ONE file
  // through two paths, and a file can never be its own surviving copy.
  if (realPathKey(viaFile) === realPathKey(decision.file)) return false;
  if (!isWithinRoot(decision.file, decision.root)) return false;
  return isWithinRoot(viaFile, via.root);
}

// Re-verifies one prune candidate and, unless this is a rehearsal, displaces it.
function prunable(decision, dryRun) {
  const { SESSION_FILE_PATTERN, classifySessionFile, sessionIdOf } = classifierModule();

  // Re-asserts the basename boundary listSessionFiles applies at discovery time, and asserts
  // it BEFORE the file is so much as read. executePrunePlan is a public export — a
  // caller-supplied plan must not be able to reach the syscall below for a file outside
  // SESSION_FILE_PATTERN, and `decision.file` is whatever that caller put there. fs accepts
  // a Buffer path, so reading first would classify a non-string as a stub and only then hand
  // it to path.basename, which throws: the batch would unwind with earlier entries already
  // renamed and no report of them. A malformed plan is a caller error the same way a missing
  // `via` is, so it is `failed` here rather than a disk fault that invites a re-run.
  if (typeof decision.file !== 'string' ||
      !SESSION_FILE_PATTERN.test(path.basename(decision.file))) {
    return { state: 'failed', reason: 'not-a-session-file' };
  }

  // The evidence the I4 comparison further down is made AGAINST, typechecked before the
  // disk is so much as read — the answer is owed without a syscall, the same way the
  // basename boundary above is. sameKeys reaches `new Set(b || [])`, where every truthy
  // non-iterable throws out of the whole batch and every falsy one is rescued into an EMPTY
  // set — and an empty set means "this stub carried no titles", a claim about the DISK that
  // a malformed field must never be able to spell. A caller error, so `failed` like the two
  // boundaries either side of it: `changed` means the file moved under us and would invite
  // a pointless re-run. An explicitly empty Set is a real claim and is left to disagree.
  if (!isTitleKeySet(decision.titleKeys)) {
    return { state: 'failed', reason: 'not-a-title-set' };
  }

  const sessionId = sessionIdOf(decision.file);

  // I4 — the stub itself. A title-only file gaining a real message is exactly how a
  // stub stops being a stub, and it is what Claude Code does to these files all day.
  // The check re-reads the titles rather than comparing size and mtime: a replacement
  // title of the same length with a restored mtime would otherwise pass.
  const fresh = classifySessionFile(decision.file);
  if (fresh.verdict === 'unreadable') {
    if (fresh.reason === 'ENOENT') return { state: 'changed', reason: 'stub-changed' };
    return { state: 'unreadable', reason: fresh.reason, scope: 'self' };
  }
  if (fresh.verdict === 'unclassified') {
    return { state: 'unclassified', reason: 'classify-truncated' };
  }
  if (fresh.verdict !== 'stub' || !sameKeys(fresh.titleKeys, decision.titleKeys)) {
    return { state: 'changed', reason: 'stub-changed' };
  }

  // The same boundary on the other side of the decision: the evidence, not just the
  // target. A malformed plan is a caller error, so it is `failed` rather than an
  // observation failure that invites a re-run.
  if (!isCounterpartPath(decision)) {
    return { state: 'failed', reason: 'not-a-counterpart' };
  }

  const viaRelative = path.relative(decision.via.root, decision.via.file);

  // I2 — the counterpart, re-proven against the live file rather than against the plan.
  const result = verifyCounterpart(decision.via.file, sessionId);
  if (!result.ok) return executeFailureState(result);

  // Resolved here rather than up front so the probe sits as close to the rename as the
  // decision does. A rehearsal answers the same question — the probe reads, it does not
  // write — so --dry-run advertises the exact recovery path a real run would create.
  const backup = backupPathFor(decision.file);
  const backupName = path.basename(backup);

  if (dryRun) return { state: 'would-prune', via: viaRelative, backup: backupName };

  try {
    // Displace, never destroy — and never destroy a PREDECESSOR either. renameSync
    // replaces an existing destination on both POSIX and Windows, so the destination is
    // chosen above to be a name no earlier rescue copy holds.
    fs.renameSync(decision.file, backup);
  } catch (error) {
    return { state: 'failed', reason: error.code || 'EIO' };
  }
  return { state: 'pruned', via: viaRelative, backup: backupName };
}

// Local-time YYYYMMDD_HHMMSS. Local rather than UTC because the only reader is a human
// picking which generation to restore, and they are reading it beside their own clock.
function backupTimestamp(now) {
  const at = now instanceof Date ? now : new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return String(at.getFullYear()) + pad(at.getMonth() + 1) + pad(at.getDate()) + '_' +
    pad(at.getHours()) + pad(at.getMinutes()) + pad(at.getSeconds());
}

// The name this run's rescue copy takes. The plain `.bak` when it is free; otherwise a
// timestamped generation beside it, because the `.bak` already there is the only copy of
// an earlier stub's title. An existence probe only — safe to call from a rehearsal, and
// safe when the parent directory cannot be read at all (an unreadable parent is reported
// through the rename's own errno, not guessed at here).
function backupPathFor(file) {
  const plain = file + BACKUP_SUFFIX;
  if (!isTaken(plain)) return plain;
  // The stamp resolves to the second, and a second holds any number of prunes: a shell
  // loop, a retry, or two roots in one pass all land inside one. A generation already
  // written in THIS second would be silently replaced by renameSync, which is the one thing
  // this whole scheme exists to prevent, so the stamp is a starting point and the name is
  // whatever is still free beside it.
  const stamped = plain + '.' + backupTimestamp();
  if (!isTaken(stamped)) return stamped;
  for (let n = 1; n < 10000; n += 1) {
    const candidate = stamped + '_' + n;
    if (!isTaken(candidate)) return candidate;
  }
  // Unreachable short of ten thousand rescue copies of one session inside one second, and
  // still answered rather than thrown: the pid is unique among the processes that could be
  // racing for this name at this instant.
  return stamped + '_p' + process.pid;
}

// An existence probe that answers rather than throws — an unreadable parent is reported
// through the rename's own errno, not guessed at here.
function isTaken(candidate) {
  try {
    return fs.existsSync(candidate);
  } catch { return false; }
}

// Set equality over the stub's (sessionId, customTitle) keys — the I4 comparison.
function sameKeys(a, b) {
  const left = new Set(a || []);
  const right = new Set(b || []);
  if (left.size !== right.size) return false;
  for (const key of left) {
    if (!right.has(key)) return false;
  }
  return true;
}

module.exports = {
  BACKUP_SUFFIX,
  TALLY_KEY,
  zeroTally,
  executeFailureState,
  backupTimestamp,
  backupPathFor,
  isWithinRoot,
  isPlanEntry,
  isTitleKeySet,
  isCounterpartPath,
  sameKeys,
  prunable,
  executePrunePlan,
};

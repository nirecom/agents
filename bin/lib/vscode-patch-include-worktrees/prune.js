// The prune pass: find title-only stub session files under ~/.claude/projects and
// delete only those whose entire content is provably already carried by a surviving
// real copy of the same session.
//
// The pass is split in two on purpose. planPruneRoots() only READS — it walks the
// roots, classifies, and decides what a deletion would have to be justified by.
// executePrunePlan() is the only function in this repository that destroys a session
// file, and it re-establishes every fact the plan rested on immediately beforehand:
// the tree is live (Claude Code writes to these files while this tool runs), so a
// decision made during the walk is a decision made about a past state of the disk.
//
// No backups are taken. The safety of that tradeoff rests entirely on the two
// verifications below being correct, which is why the re-verification is not optional
// and why a stub with no real counterpart is never deleted under any circumstance.
'use strict';

const fs = require('fs');
const path = require('path');

const { normalizeInputPath, pathKey, realPathKey, isDirectory } = require('./primitives');
const {
  TITLE_RECORD_TYPE,
  VERIFY_MAX_SCAN,
  scanLines,
  parseLine,
  titleKey,
  isKnownTitleRecord,
  isMatchingContentRecord,
  verifyCounterpart,
} = require('./prune/verify');

// Home-relative, no platform branch — the same as the patch path's CANDIDATE_ROOTS.
const DEFAULT_PROJECTS_ROOTS = [['.claude', 'projects']];

// A plain UUID + `.jsonl`, anchored at both ends. This pattern is a safety boundary,
// not a convenience: the same directory holds `agent-<uuid>.jsonl` subagent transcripts
// and `.history.jsonl`, which this tool does not understand. Anything the pattern lets
// through becomes eligible for deletion.
const SESSION_FILE_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$/i;

// Classification only has to answer "is this file nothing but titles?", and the answer
// is settled by the first content record, so the budget is small. A file too large to
// judge within it is an observation failure, never a decision.
const CLASSIFY_MAX_SCAN = 1024 * 1024;

// Severity ladder for aggregating several failed counterparts. An observation that
// failed must never be reported as a decision that was reached: `kept` claims the file
// was examined and consciously retained, which is a lie if a copy was never read.
const SEVERITY = { kept: 0, unclassified: 1, unreadable: 2 };

// `overrides`, when non-empty, REPLACES the default root: the real ~/.claude/projects
// is then not scanned at all. Dedup by normalized path then by realpath, input order
// preserved — same two-stage rule as the patch path's resolveRoots.
function resolvePruneRoots(options) {
  const opts = options || {};
  const overrides = Array.isArray(opts.overrides) ? opts.overrides : [];
  const candidates = [];
  if (overrides.length > 0) {
    for (const override of overrides) candidates.push(normalizeInputPath(String(override)));
  } else {
    const home = normalizeInputPath(String(opts.home == null ? '' : opts.home));
    for (const relative of DEFAULT_PROJECTS_ROOTS) {
      const root = path.join(home, ...relative);
      if (isDirectory(root)) candidates.push(root);
    }
  }
  return dedupRoots(candidates);
}

function dedupRoots(candidates) {
  const roots = [];
  const seenPath = new Set();
  const seenReal = new Set();
  for (const candidate of candidates) {
    const key = pathKey(candidate);
    if (seenPath.has(key)) continue;
    seenPath.add(key);
    const realKey = realPathKey(candidate);
    if (seenReal.has(realKey)) continue;
    seenReal.add(realKey);
    roots.push(candidate);
  }
  return roots;
}

// Recursive walk of one root. Returns { entries, scanErrors } and never throws: a
// directory that cannot be read is recorded and the rest of the tree is still scanned,
// because refusing to prune anything because of one locked folder is its own failure.
// Symlinks — file and directory alike — are skipped outright: following them would let
// a link decide what gets deleted, and a directory link pointing at an ancestor would
// spin the walk forever.
function listSessionFiles(root) {
  const entries = [];
  const scanErrors = [];
  const stack = [String(root)];
  while (stack.length > 0) {
    const dir = stack.pop();
    let dirents;
    try {
      dirents = fs.readdirSync(dir, { withFileTypes: true });
    } catch (error) {
      scanErrors.push({ root, path: dir, code: error.code || 'EIO' });
      continue;
    }
    dirents.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const dirent of dirents) {
      if (dirent.isSymbolicLink()) continue;
      const full = path.join(dir, dirent.name);
      if (dirent.isDirectory()) {
        stack.push(full);
      } else if (dirent.isFile() && SESSION_FILE_PATTERN.test(dirent.name)) {
        entries.push({ file: full, root });
      }
    }
  }
  entries.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : 0));
  return { entries, scanErrors };
}

// The gate every deletion passes through.
//
// Verdicts: `stub` (nothing but well-formed custom-title records — I1), `real` (carries
// at least one content record for its own session — I2), `indeterminate` (read in full,
// but neither), `unclassified` (the read budget ran out first) and `unreadable` (the
// file could not be read at all). The last two are OBSERVATION FAILURES: they say
// nothing about the file, so they can neither justify a deletion nor authorise a keep.
function classifySessionFile(file) {
  const sessionId = path.basename(String(file)).replace(/\.jsonl$/i, '');
  const counts = { titles: 0, blank: 0, content: 0 };
  const titleKeys = new Set();
  let other = 0;
  let scan;
  try {
    scan = scanLines(file, CLASSIFY_MAX_SCAN, (line) => {
      const record = parseLine(line);
      if (record === null) {
        // Blank and malformed are counted apart: a blank line carries no information
        // and must not block `stub`, while a line that cannot be parsed might.
        if (String(line).trim() === '') counts.blank += 1;
        else other += 1;
        return true;
      }
      if (record.type === TITLE_RECORD_TYPE) {
        counts.titles += 1;
        if (isKnownTitleRecord(record)) titleKeys.add(titleKey(record));
        else other += 1;
        return true;
      }
      if (isMatchingContentRecord(record, sessionId)) {
        counts.content += 1;
        // Positive evidence is conclusive, so the scan stops here — which is why the
        // cap costs nothing on the common path (a real transcript opens with content).
        return false;
      }
      // A content record belonging to ANOTHER session, an ai-title, an audit-log line
      // with no `type` at all: real information this tool cannot account for.
      other += 1;
      return true;
    });
  } catch (error) {
    return {
      verdict: 'unreadable',
      reason: error.code || 'EIO',
      counts,
      titleKeys,
      truncated: false,
    };
  }

  let stat = null;
  try {
    stat = fs.statSync(file);
  } catch { /* the verdict does not depend on it; size/mtime are diagnostics only */ }

  let verdict;
  if (counts.content > 0) verdict = 'real';
  else if (scan.truncated) verdict = 'unclassified';
  else if (counts.titles > 0 && other === 0) verdict = 'stub';
  else verdict = 'indeterminate';

  return {
    verdict,
    counts,
    titleKeys,
    truncated: scan.truncated,
    size: stat === null ? -1 : stat.size,
    mtimeMs: stat === null ? -1 : stat.mtimeMs,
  };
}

// Pure decision over one already-classified group (files sharing a basename, i.e. the
// same session copied into several project directories). No I/O: the point is that the
// decision is separable from — and therefore auditable independently of — the reading.
//
// The lone-stub invariant lives here: a stub is a prune CANDIDATE only when the group
// holds at least one file classified `real`. `indeterminate`, `unclassified` and
// `unreadable` members are explicitly NOT surviving copies.
function planPrune(group) {
  const members = Array.isArray(group) ? group : [];
  const reals = members.filter((m) => m.verdict === 'real');
  return members.map((member) => {
    const base = { file: member.file, root: member.root, entry: member };
    if (member.verdict === 'stub') {
      if (reals.length === 0) {
        return Object.assign(base, { action: 'keep', reason: 'no-real-copy', counterparts: [] });
      }
      return Object.assign(base, {
        action: 'prune-candidate',
        counterparts: reals.slice(),
        titleKeys: member.titleKeys,
      });
    }
    if (member.verdict === 'unreadable') {
      return Object.assign(base, {
        action: 'unreadable',
        reason: member.reason,
        scope: 'self',
        counterparts: [],
      });
    }
    if (member.verdict === 'unclassified') {
      return Object.assign(base, { action: 'unclassified', counterparts: [] });
    }
    return Object.assign(base, { action: 'none', counterparts: [] });
  });
}

// Which state a failed verification maps to at PLAN time, where the counterpart never
// verified in the first place — so nothing has "changed", the evidence simply is not
// there. A read fault is an observation failure; a missing or non-covering copy is a
// decision to keep.
function planFailureState(result) {
  if (result.reason === 'unreadable') {
    if (result.code === 'ENOENT') return { state: 'kept', reason: 'no-real-copy' };
    return { state: 'unreadable', reason: result.code, scope: 'counterpart' };
  }
  if (result.reason === 'verify-truncated') {
    return { state: 'unclassified', reason: 'verify-truncated' };
  }
  return { state: 'kept', reason: result.reason };
}

// The same mapping at EXECUTE time, where the counterpart DID verify during planning.
// A failure now means the file moved under us: that is a race correctly detected and
// refused, which is a decision reached (exit 0), not a fault. EACCES is the exception —
// it means the copy could not be observed at all, which no re-run can be assumed to fix.
function executeFailureState(result) {
  if (result.reason === 'unreadable' && result.code !== 'ENOENT') {
    return { state: 'unreadable', reason: result.code, scope: 'counterpart' };
  }
  if (result.reason === 'verify-truncated') {
    return { state: 'unclassified', reason: 'verify-truncated' };
  }
  return { state: 'changed', reason: 'counterpart-changed' };
}

function heavier(a, b) {
  if (a === null) return b;
  return (SEVERITY[b.state] || 0) > (SEVERITY[a.state] || 0) ? b : a;
}

function sessionIdOf(file) {
  return path.basename(String(file)).replace(/\.jsonl$/i, '');
}

function sameKeys(a, b) {
  const left = new Set(a || []);
  const right = new Set(b || []);
  if (left.size !== right.size) return false;
  for (const key of left) {
    if (!right.has(key)) return false;
  }
  return true;
}

// Walks every root, classifies each duplicated basename group, and resolves each prune
// candidate against its counterparts. Read-only from end to end — the returned plan is
// the complete set of intentions, and nothing acts on it until executePrunePlan does.
//
// A candidate that no counterpart can justify is DOWNGRADED here rather than dropped,
// so that the report can say why the file survived.
function planPruneRoots(options) {
  const opts = options || {};
  const roots = dedupRoots((Array.isArray(opts.roots) ? opts.roots : []).map(String));

  const entries = [];
  const scanErrors = [];
  const seen = new Set();
  for (const root of roots) {
    const listed = listSessionFiles(root);
    for (const error of listed.scanErrors) scanErrors.push(error);
    for (const entry of listed.entries) {
      // Realpath dedup across roots. Two overlapping roots (a directory and its own
      // parent) otherwise enumerate the SAME file twice, and it would then appear to
      // have a duplicate of itself — the single most dangerous failure this tool has.
      const key = realPathKey(entry.file);
      if (seen.has(key)) continue;
      seen.add(key);
      entries.push(entry);
    }
  }

  const groups = new Map();
  for (const entry of entries) {
    const name = path.basename(entry.file).toLowerCase();
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(entry);
  }

  const plan = [];
  let groupCount = 0;
  for (const members of groups.values()) {
    // A basename that occurs once has no counterpart by construction, so it is never
    // even read: classification is the expensive half, and it could only ever conclude
    // "keep".
    if (members.length < 2) continue;
    groupCount += 1;
    const classified = members.map((entry) =>
      Object.assign({}, entry, classifySessionFile(entry.file))
    );
    const realCopies = classified.filter((m) => m.verdict === 'real').length;
    for (const decision of planPrune(classified)) {
      decision.realCopies = realCopies;
      if (decision.action === 'prune-candidate') resolveCandidate(decision);
      if (decision.action !== 'none') plan.push(decision);
    }
  }

  return { roots, plan, scanErrors, scanned: entries.length, groups: groupCount };
}

// Picks the counterpart that justifies deleting this stub, trying every candidate in
// turn: the first refusal is not the end of the search, because a group may hold both a
// copy that never carried this title and one that did.
function resolveCandidate(decision) {
  const sessionId = sessionIdOf(decision.file);
  let worst = null;
  for (const counterpart of decision.counterparts) {
    const result = verifyCounterpart(counterpart.file, decision.titleKeys, sessionId);
    if (result.ok) {
      decision.via = counterpart;
      return;
    }
    worst = heavier(worst, planFailureState(result));
  }
  // Nothing justified the deletion. The candidate becomes the failure it ran into,
  // carrying the heaviest of them so an unobserved copy is never reported as a keep.
  const failure = worst === null ? { state: 'kept', reason: 'no-real-copy' } : worst;
  decision.action = failure.state === 'kept' ? 'keep' : failure.state;
  decision.reason = failure.reason;
  if (failure.scope) decision.scope = failure.scope;
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

const TALLY_KEY = {
  pruned: 'pruned',
  'would-prune': 'wouldPrune',
  kept: 'kept',
  changed: 'changed',
  unreadable: 'unreadable',
  unclassified: 'unclassified',
  failed: 'failed',
};

// The only place in this repository where a session file is destroyed.
//
// Every deletion is preceded, in this function and immediately before the syscall, by
// BOTH halves of the original decision being re-established against the live disk:
// the stub must still be a stub carrying exactly the titles it was judged on (I4), and
// the counterpart must still cover them (I3). Anything else aborts the deletion — a
// refused race is reported as `changed` and costs nothing, while a wrong deletion is
// unrecoverable because no backup is taken.
function executePrunePlan(options) {
  const opts = options || {};
  const plan = Array.isArray(opts.plan) ? opts.plan : [];
  const dryRun = opts.dryRun === true;
  const onEntry = typeof opts.onEntry === 'function' ? opts.onEntry : () => {};
  const tally = zeroTally();

  for (const decision of plan) {
    const outcome = decision.action === 'prune-candidate'
      ? prunable(decision, dryRun)
      : {
        state: decision.action === 'keep' ? 'kept' : decision.action,
        reason: decision.reason,
        scope: decision.scope,
      };

    const key = TALLY_KEY[outcome.state];
    if (key) tally[key] += 1;
    onEntry({
      file: decision.file,
      root: decision.root,
      state: outcome.state,
      reason: outcome.reason,
      scope: outcome.scope,
      via: outcome.via,
      realCopies: decision.realCopies,
    });
  }

  return tally;
}

// Re-verifies one prune candidate and, unless this is a rehearsal, deletes it.
function prunable(decision, dryRun) {
  const sessionId = sessionIdOf(decision.file);
  const viaFile = decision.via ? decision.via.file : null;
  const viaRelative = decision.via
    ? path.relative(decision.via.root, decision.via.file)
    : null;

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

  // Re-asserts the basename boundary listSessionFiles applies at discovery time.
  // executePrunePlan is a public export — a caller-supplied plan must not be able to
  // reach the syscall below for a file outside SESSION_FILE_PATTERN.
  if (!SESSION_FILE_PATTERN.test(path.basename(decision.file))) {
    return { state: 'failed', reason: 'not-a-session-file' };
  }

  // I3 — the counterpart, re-proven against the live file rather than against the plan.
  const result = verifyCounterpart(viaFile, fresh.titleKeys, sessionId);
  if (!result.ok) return executeFailureState(result);

  if (dryRun) return { state: 'would-prune', via: viaRelative };

  try {
    fs.unlinkSync(decision.file);
  } catch (error) {
    return { state: 'failed', reason: error.code || 'EIO' };
  }
  return { state: 'pruned', via: viaRelative };
}

// Pure composition of the read-only planner and the executor. It deliberately holds no
// logic of its own: any decision made here would be a decision that never passed
// through the re-verification above.
function pruneRoots(options) {
  const opts = options || {};
  const planned = planPruneRoots(opts);
  const tally = executePrunePlan({
    plan: planned.plan,
    dryRun: opts.dryRun === true,
    onEntry: opts.onEntry,
  });
  return {
    roots: planned.roots,
    scanned: planned.scanned,
    groups: planned.groups,
    scanErrors: planned.scanErrors,
    tally,
  };
}

module.exports = {
  DEFAULT_PROJECTS_ROOTS,
  SESSION_FILE_PATTERN,
  CLASSIFY_MAX_SCAN,
  VERIFY_MAX_SCAN,
  resolvePruneRoots,
  listSessionFiles,
  classifySessionFile,
  planPrune,
  planPruneRoots,
  executePrunePlan,
  pruneRoots,
  verifyCounterpart,
};

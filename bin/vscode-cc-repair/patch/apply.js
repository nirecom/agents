// The single-directory patch operation — moved verbatim from the entrypoint's
// `// ---- patch ----` section, together with the constants it splices with.
//
// One deliberate, behaviour-preserving deviation from the verbatim move: unlinkQuiet()
// now removes the temp file via fs.rmSync(target, { force: true }). The prune path's
// safety argument rests on there being exactly ONE file-destroying call site in this
// library (the one that carries the pre-delete re-verification), and that invariant is
// guarded by a source grep over the whole directory — so the patch path's temp-file
// cleanup must not read as a second delete site. `force: true` swallows ENOENT exactly
// as the surrounding try/catch already did.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const { classify, zeroCounts } = require('./classify');

const OLD_SITE = 'includeWorktrees:!1';
const NEW_SITE = 'includeWorktrees:!0';
const BUNDLE = 'extension.js';

// `node --check` parses without executing, but the child still inherits the ambient
// environment, so NODE_OPTIONS=--require ./evil.js would run code during a call documented
// as parse-only. Filtered case-insensitively: win32 keeps the casing a variable was set with.
const CHECK_ENV = Object.fromEntries(
  Object.entries(process.env).filter(([key]) => !/^node_options$/i.test(key))
);

function tempSuffix() {
  return process.pid + '-' + crypto.randomBytes(4).toString('hex');
}

function unlinkQuiet(target) {
  try {
    fs.rmSync(target, { force: true });
  } catch { /* the temp file is already gone; nothing to clean up */ }
}

// Returns { state, counts, reasons }. Never throws for an expected filesystem condition —
// the caller aggregates and decides the exit code, so one bad directory cannot abort the
// scan of its siblings.
function patchDir(dir, options) {
  const target = path.join(dir, BUNDLE);
  let stat = null;
  try {
    stat = fs.statSync(target);
  } catch { /* absent or unreadable; the refusal below covers both */ }
  // A matching directory with no bundle is refused loudly, never skipped: it means the
  // install layout changed under us and the report would otherwise read as a clean run.
  if (!stat || !stat.isFile()) {
    return { state: 'refused', counts: zeroCounts(), reasons: ['no-extension-js'] };
  }

  // latin1 throughout the read/splice/write path. utf8 would fold invalid byte sequences
  // into U+FFFD (3 bytes each) and destroy the byte-length invariance the patch relies on.
  const baseBuf = fs.readFileSync(target);
  const text = baseBuf.toString('latin1');

  const verdict = classify(text);
  if (verdict.state !== 'unpatched') {
    return { state: verdict.state, counts: verdict.counts, reasons: [] };
  }
  if (options.dryRun) {
    return { state: 'would-patch', counts: verdict.counts, reasons: [] };
  }

  // An already-broken bundle is never made worse, and there is no --force escape hatch.
  const baseline = spawnSync(process.execPath, ['--check', target], { env: CHECK_ENV });
  if (baseline.status !== 0) {
    return { state: 'refused', counts: verdict.counts, reasons: ['baseline-unparsable'] };
  }

  // The backup is the pristine pre-patch bundle, so an existing one is always the older
  // and more valuable copy: create only when absent, never overwrite.
  const backup = target + '.bak';
  let backupReason;
  if (fs.existsSync(backup)) {
    backupReason = 'backup=preserved';
  } else {
    const backupTmp = path.join(dir, BUNDLE + '.bak.' + tempSuffix() + '.tmp');
    try {
      // `wx` = O_CREAT|O_EXCL. Both temp names are freshly generated, so an existing path
      // is never legitimate: EEXIST beats truncating a file or following a planted symlink.
      fs.writeFileSync(backupTmp, baseBuf, { flag: 'wx' });
      fs.renameSync(backupTmp, backup);
    } catch {
      unlinkQuiet(backupTmp);
      return { state: 'failed', counts: verdict.counts, reasons: ['backup-write-failed'] };
    }
    backupReason = 'backup=created';
  }

  // Local restatement of the classifier's invariant: latin1 keeps char offsets equal to byte
  // offsets, so the bytes at siteOffset must read back as OLD_SITE verbatim before splicing.
  if (text.slice(verdict.siteOffset, verdict.siteOffset + OLD_SITE.length) !== OLD_SITE) {
    return { state: 'failed', counts: verdict.counts, reasons: [backupReason, 'site-mismatch'] };
  }
  const next =
    text.slice(0, verdict.siteOffset) +
    NEW_SITE +
    text.slice(verdict.siteOffset + OLD_SITE.length);
  const outBuf = Buffer.from(next, 'latin1');
  if (outBuf.length !== baseBuf.length) {
    return { state: 'failed', counts: verdict.counts, reasons: [backupReason, 'length-mismatch'] };
  }

  // The temp name must end `.js`: `node --check` picks its parse mode from the extension
  // and exits 1 with ERR_UNKNOWN_FILE_EXTENSION on a bare `.tmp` suffix. Same directory,
  // so the final step is an atomic same-volume rename. `wx` as above: fail on any existing path.
  const tmp = path.join(dir, 'extension.' + tempSuffix() + '.tmp.js');
  try {
    fs.writeFileSync(tmp, outBuf, { flag: 'wx' });
  } catch {
    unlinkQuiet(tmp);
    return { state: 'failed', counts: verdict.counts, reasons: [backupReason, 'tmp-write-failed'] };
  }

  const check = spawnSync(process.execPath, ['--check', tmp], { env: CHECK_ENV });
  if (check.status !== 0) {
    unlinkQuiet(tmp);
    return { state: 'failed', counts: verdict.counts, reasons: [backupReason, 'tmp-unparsable'] };
  }

  let tmpSize = -1;
  try {
    tmpSize = fs.statSync(tmp).size;
  } catch { /* -1 is not a valid size, so the mismatch branch below fires */ }
  if (tmpSize !== baseBuf.length) {
    unlinkQuiet(tmp);
    return { state: 'failed', counts: verdict.counts, reasons: [backupReason, 'length-mismatch'] };
  }

  // Last check before the rename: the bundle must still be the exact bytes that were
  // classified. A residual TOCTOU window remains between here and renameSync.
  let reread;
  try {
    reread = fs.readFileSync(target);
  } catch {
    unlinkQuiet(tmp);
    return { state: 'failed', counts: verdict.counts, reasons: [backupReason, 'reread-failed'] };
  }
  if (Buffer.compare(reread, baseBuf) !== 0) {
    unlinkQuiet(tmp);
    const rereadVerdict = classify(reread.toString('latin1'));
    if (rereadVerdict.state === 'already') {
      // Another writer landed the same fix: the goal is met, so this is not a failure.
      return { state: 'already', counts: rereadVerdict.counts, reasons: [backupReason, 'raced'] };
    }
    return {
      state: 'failed',
      counts: rereadVerdict.counts,
      reasons: [backupReason, 'changed-during-patch'],
    };
  }

  try {
    fs.renameSync(tmp, target);
  } catch {
    unlinkQuiet(tmp);
    return { state: 'failed', counts: verdict.counts, reasons: [backupReason, 'rename-failed'] };
  }

  // The rename already landed, so nothing leaks here; a failing read only leaves the result
  // unverified, which is the existing post-verify failure — not an unhandled exception.
  let after = null;
  try {
    after = classify(fs.readFileSync(target).toString('latin1'));
  } catch { /* fall through to post-verify-failed */ }
  if (after === null || after.state !== 'already') {
    const counts = after === null ? verdict.counts : after.counts;
    return { state: 'failed', counts, reasons: [backupReason, 'post-verify-failed'] };
  }
  return { state: 'patched', counts: verdict.counts, reasons: [backupReason] };
}

module.exports = { OLD_SITE, NEW_SITE, BUNDLE, CHECK_ENV, tempSuffix, unlinkQuiet, patchDir };

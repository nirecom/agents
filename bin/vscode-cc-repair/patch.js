// Façade for the extension-patch pass. Re-exports the pieces the entrypoint and the
// existing test suite reach for, and owns runPatch() — the whole-run driver that was
// the body of the old main().
'use strict';

const path = require('path');

const { warn } = require('./primitives');
const { KEY, classifyValue, zeroCounts, classify } = require('./patch/classify');
const {
  CANDIDATE_ROOTS,
  EXTENSION_DIR_PATTERN,
  resolveRoots,
  listExtensionDirs,
} = require('./patch/discover');
const { OLD_SITE, NEW_SITE, BUNDLE, patchDir } = require('./patch/apply');
const { countPrefix, summaryLine } = require('./patch/report');

// Runs the patch pass over every resolved root and writes its own report to stdout.
// Returns { failed } — true when any directory ended `refused` or `failed`, which the
// CLI folds into the process-wide exit code. The prune pass runs independently, so this
// deliberately reports a boolean rather than exiting.
function runPatch(options) {
  const opts = options || {};
  const overrides = Array.isArray(opts.overrides) ? opts.overrides : [];
  const dryRun = opts.dryRun === true;

  const roots = resolveRoots({ home: opts.home, overrides });
  const tally = { patched: 0, already: 0, absent: 0, 'would-patch': 0, refused: 0, failed: 0 };
  let dirs = 0;

  if (roots.length === 0) {
    process.stdout.write('no VS Code extension root found — nothing to do\n');
    process.stdout.write(summaryLine(0, 0, tally) + '\n');
    return { failed: false };
  }

  for (const root of roots) {
    // On stdout the absolute path appears once per root and the per-directory lines below are
    // basename-only, so stdout is safe to paste verbatim. The stderr diagnostics deliberately
    // differ: absolute directory plus Node's error.message (also absolute), for local debugging.
    process.stdout.write('root: ' + root + '\n');
    for (const dir of listExtensionDirs(root)) {
      let result;
      try {
        result = patchDir(dir, { dryRun });
      } catch (error) {
        result = { state: 'failed', counts: zeroCounts(), reasons: ['exception'] };
        warn(path.basename(dir) + ': ' + error.message);
      }
      dirs += 1;
      const details = [countPrefix(result.counts)].concat(result.reasons).join(' ');
      process.stdout.write(result.state + '  ' + path.basename(dir) + '  ' + details + '\n');
      if (result.state === 'refused' || result.state === 'failed') {
        warn(result.state + ': ' + dir + ' (' + details + ')');
      }
      tally[result.state] += 1;
    }
  }

  process.stdout.write(summaryLine(roots.length, dirs, tally) + '\n');
  return { failed: tally.refused + tally.failed > 0 };
}

module.exports = {
  KEY,
  OLD_SITE,
  NEW_SITE,
  BUNDLE,
  CANDIDATE_ROOTS,
  EXTENSION_DIR_PATTERN,
  classifyValue,
  zeroCounts,
  classify,
  resolveRoots,
  listExtensionDirs,
  patchDir,
  countPrefix,
  summaryLine,
  runPatch,
};

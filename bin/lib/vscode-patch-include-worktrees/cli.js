// The command-line surface: argument parsing, validation, and the two passes.
//
// `--prune-stub-sessions` is ADDITIVE, not a mode selector — a run that asked for a
// prune still patches the extension, and the exit code is the union of both passes.
// Both validations run before either pass, so a caller error never leaves the tree
// half-processed.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseArgs } = require('util');

const { warn, normalizeInputPath } = require('./primitives');
const { runPatch } = require('./patch');
const { resolvePruneRoots, pruneRoots } = require('./prune');

const USAGE = [
  'Usage: vscode-patch-include-worktrees [options]',
  '',
  'Options:',
  '  --extensions-dir <path>  Extension root to scan (absolute, repeatable).',
  '                           When given, the default ~/.vscode* roots are not scanned.',
  '  --prune-stub-sessions    Additionally delete title-only stub session files whose',
  '                           content is already carried by a surviving real copy.',
  '  --claude-projects-dir <path>',
  '                           Session-store root to scan (absolute, repeatable).',
  '                           Requires --prune-stub-sessions. When given, the default',
  '                           ~/.claude/projects root is not scanned.',
  '  --dry-run                Classify and report only; write nothing.',
  '  --help                   Show this help and exit.',
  '',
].join('\n');

// Shared validation for both path-valued options: a second option that validated
// differently from the first would be a trap. Returns null when every value is
// acceptable, otherwise the exit code 2.
function rejectBadPaths(flag, values) {
  for (const value of values) {
    if (!path.isAbsolute(value)) {
      warn(flag + ' must be an absolute path: ' + value);
      return 2;
    }
    if (value.split(/[\\/]+/).includes('..')) {
      warn(flag + ' must not contain "..": ' + value);
      return 2;
    }
    let stat = null;
    try {
      stat = fs.statSync(value);
    } catch {
      // Deliberately asymmetric with the silently-skipped default candidates: a typo in
      // an explicit override must not read as a 0-hit success.
      warn(flag + ' does not exist: ' + value);
      return 2;
    }
    if (!stat.isDirectory()) {
      warn(flag + ' is not a directory: ' + value);
      return 2;
    }
  }
  return null;
}

function rejectBadOverrides(overrides) {
  return rejectBadPaths('--extensions-dir', overrides);
}

function rejectBadPruneDirs(dirs) {
  return rejectBadPaths('--claude-projects-dir', dirs);
}

// One report line: `<state>  <root-relative path>  <details>`. The path is relative to
// its root (announced once, absolutely, above) and the details are counts and paths
// only. Session titles are user content and never appear on either stream.
function reportLine(state, relative, details) {
  const tail = details.length > 0 ? '  ' + details.join(' ') : '';
  return state + '  ' + relative + tail + '\n';
}

function relativeTo(root, target) {
  const relative = path.relative(String(root), String(target));
  return relative === '' ? '.' : relative;
}

function pruneSummaryLine(nRoots, scanned, groups, tally, scanErrors) {
  return (
    'prune-summary: prune-roots=' + nRoots +
    ' scanned=' + scanned +
    ' groups=' + groups +
    ' pruned=' + tally.pruned +
    ' would-prune=' + tally.wouldPrune +
    ' kept=' + tally.kept +
    ' changed=' + tally.changed +
    ' unreadable=' + tally.unreadable +
    ' unclassified=' + tally.unclassified +
    ' scan-errors=' + scanErrors +
    ' failed=' + tally.failed
  );
}

// Runs the prune pass and writes its report. Returns { failed } — true when anything
// could not be OBSERVED (unreadable / unclassified / scan error / a failed unlink).
// A refused race (`changed`) is a decision that was reached and costs nothing, so it
// stays on the success side.
function runPrune(options) {
  const roots = resolvePruneRoots({ home: options.home, overrides: options.overrides });
  if (roots.length === 0) {
    process.stdout.write('no Claude projects root found — nothing to prune\n');
    process.stdout.write(
      pruneSummaryLine(0, 0, 0, {
        pruned: 0, wouldPrune: 0, kept: 0, changed: 0, unreadable: 0, unclassified: 0, failed: 0,
      }, 0) + '\n'
    );
    return { failed: false };
  }

  for (const root of roots) process.stdout.write('prune-root: ' + root + '\n');

  const result = pruneRoots({
    roots,
    dryRun: options.dryRun,
    onEntry: (entry) => {
      const details = [];
      if (entry.reason) details.push('reason=' + entry.reason);
      if (entry.scope) details.push('scope=' + entry.scope);
      if (entry.via) details.push('via=' + entry.via);
      if (entry.realCopies != null) details.push('real-copies=' + entry.realCopies);
      process.stdout.write(reportLine(entry.state, relativeTo(entry.root, entry.file), details));
      if (entry.state === 'unreadable' || entry.state === 'failed') {
        warn(entry.state + ': ' + entry.file + ' (' + details.join(' ') + ')');
      }
    },
  });

  for (const error of result.scanErrors) {
    process.stdout.write(
      reportLine('scan-error', relativeTo(error.root, error.path), ['reason=' + error.code])
    );
    warn('scan-error: ' + error.path + ' (reason=' + error.code + ')');
  }

  const tally = result.tally;
  process.stdout.write(
    pruneSummaryLine(
      result.roots.length, result.scanned, result.groups, tally, result.scanErrors.length
    ) + '\n'
  );

  return {
    failed:
      tally.failed + tally.unreadable + tally.unclassified + result.scanErrors.length > 0,
  };
}

function main() {
  let parsed;
  try {
    parsed = parseArgs({
      options: {
        'extensions-dir': { type: 'string', multiple: true },
        'prune-stub-sessions': { type: 'boolean' },
        'claude-projects-dir': { type: 'string', multiple: true },
        'dry-run': { type: 'boolean' },
        help: { type: 'boolean' },
      },
      strict: true,
      allowPositionals: false,
    });
  } catch (error) {
    warn('argument error: ' + error.message);
    return 2;
  }

  if (parsed.values.help) {
    process.stdout.write(USAGE);
    return 0;
  }

  const overrides = (parsed.values['extensions-dir'] || []).map((value) =>
    normalizeInputPath(String(value))
  );
  const pruneDirs = (parsed.values['claude-projects-dir'] || []).map((value) =>
    normalizeInputPath(String(value))
  );
  const prune = parsed.values['prune-stub-sessions'] === true;

  // Silently accepting the root override without the opt-in would leave a caller
  // believing a prune ran when none did.
  if (!prune && pruneDirs.length > 0) {
    warn('--claude-projects-dir requires --prune-stub-sessions');
    return 2;
  }

  // Both validations precede both passes: exit 2 must mean nothing was touched.
  const rejected = rejectBadOverrides(overrides);
  if (rejected !== null) return rejected;
  const rejectedPrune = rejectBadPruneDirs(pruneDirs);
  if (rejectedPrune !== null) return rejectedPrune;

  const dryRun = parsed.values['dry-run'] === true;
  const home = os.homedir();

  const patched = runPatch({ home, overrides, dryRun });
  const pruned = prune ? runPrune({ home, overrides: pruneDirs, dryRun }) : { failed: false };

  return patched.failed || pruned.failed ? 1 : 0;
}

module.exports = { USAGE, rejectBadOverrides, rejectBadPruneDirs, runPrune, main };

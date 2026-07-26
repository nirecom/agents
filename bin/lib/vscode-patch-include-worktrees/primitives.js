// Leaf primitives shared by both paths of bin/vscode-patch-include-worktrees:
// the shipped extension-patch pass and the session-file prune pass. Nothing here
// knows about either feature — moved verbatim out of the entrypoint when it was
// split, so the existing suite is the proof that the move changed no behaviour.
'use strict';

const fs = require('fs');
const path = require('path');

const PREFIX = '[vscode-patch-include-worktrees] ';

function warn(message) {
  process.stderr.write(PREFIX + message + '\n');
}

// Git Bash / MSYS2 hand absolute paths over in POSIX drive-letter form (`/c/foo`), which
// Node's fs.* rejects with ENOENT on win32. Only that one spelling is rewritten, and only
// on win32 — on POSIX `/c/foo` is a legitimate path. Every other spelling is returned
// byte-identical, so report lines can echo the caller's own path back verbatim.
// Idempotent, so applying it at two boundaries of the same value is harmless.
function normalizeInputPath(raw) {
  if (typeof raw !== 'string' || process.platform !== 'win32') return raw;
  const drive = raw.match(/^\/([A-Za-z])(\/.*)?$/);
  if (!drive) return raw;
  const tail = (drive[2] || '').replace(/\//g, '\\').replace(/^\\/, '');
  return drive[1].toUpperCase() + ':\\' + tail;
}

// Comparison key for root/directory dedup. win32 paths are case-insensitive, POSIX are not.
function pathKey(target) {
  const resolved = path.normalize(path.resolve(String(target)));
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
}

function realPathKey(target) {
  try {
    return pathKey(fs.realpathSync(target));
  } catch {
    return pathKey(target);
  }
}

function isDirectory(target) {
  try {
    return fs.statSync(target).isDirectory();
  } catch { return false; }
}

module.exports = {
  PREFIX,
  warn,
  normalizeInputPath,
  pathKey,
  realPathKey,
  isDirectory,
};

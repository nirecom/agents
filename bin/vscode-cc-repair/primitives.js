// Leaf primitives shared by both paths of bin/vscode-cc-repair:
// the shipped extension-patch pass and the session-file prune pass. Nothing here
// knows about either feature — moved verbatim out of the entrypoint when it was
// split, so the existing suite is the proof that the move changed no behaviour.
'use strict';

const fs = require('fs');
const path = require('path');

const PREFIX = '[vscode-cc-repair] ';

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

// The ONE statement of the platform's case rule: win32 filesystems fold case, POSIX ones
// do not. Every identity question about a path — root dedup, duplicate-basename grouping,
// counterpart validation — is expressed through this, so those answers cannot drift apart
// into a build where two files are "one name" to the grouper and "two sessions" to the
// verifier. Takes any path fragment, including a bare basename, and never resolves.
function caseFoldPath(value) {
  const text = String(value);
  return process.platform === 'win32' ? text.toLowerCase() : text;
}

// Comparison key for root/directory dedup. win32 paths are case-insensitive, POSIX are not.
function pathKey(target) {
  return caseFoldPath(path.normalize(path.resolve(String(target))));
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
  caseFoldPath,
  pathKey,
  realPathKey,
  isDirectory,
};

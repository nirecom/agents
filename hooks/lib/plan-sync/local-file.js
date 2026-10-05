"use strict";
// hooks/lib/plan-sync/local-file.js
// Verified reads of local plan files, shared by commit-push.js (one file per write) and
// provision.js (every existing plan at init).
const fs = require("fs");
const path = require("path");

// A symlink or a hard link (nlink > 1) named like a plan could publish another file's content.
function isSoleRegularFile(st) {
  return st.isFile() && !st.isSymbolicLink() && st.nlink === 1;
}

function isRegularFile(absPath) {
  try {
    return isSoleRegularFile(fs.lstatSync(path.resolve(absPath)));
  } catch (_) {
    return false;
  }
}

// readVerifiedRegularFile(absPath) -> Buffer | null — the content read once through an fd that
// is proven (fstat dev/ino == lstat dev/ino) to be the same sole regular file, so a swap of the
// path after the check can never substitute another file's bytes.
function readVerifiedRegularFile(absPath) {
  const p = path.resolve(absPath);
  let fd = null;
  try {
    const st = fs.lstatSync(p);
    if (!isSoleRegularFile(st)) return null;
    fd = fs.openSync(p, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const fst = fs.fstatSync(fd);
    if (!fst.isFile() || fst.nlink !== 1 || fst.dev !== st.dev || fst.ino !== st.ino) return null;
    return fs.readFileSync(fd);
  } catch (_) {
    return null;
  } finally {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch (_) { /* already closed */ }
    }
  }
}

module.exports = { isRegularFile, readVerifiedRegularFile };

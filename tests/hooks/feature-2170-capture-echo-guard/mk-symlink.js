"use strict";
// node mk-symlink.js <target> <linkPath> [file|dir]
// Exit 0 on success, 77 when the platform refuses to create symlinks (Windows without
// Developer Mode / admin) so the CALLER can skip only that case, never the whole file.

const fs = require("fs");

const target = process.argv[2];
const link = process.argv[3];
const type = process.argv[4] === "dir" ? "dir" : "file";

try {
  try { fs.unlinkSync(link); } catch (_e) { /* nothing to remove */ }
  fs.symlinkSync(target, link, type);
  process.exit(0);
} catch (e) {
  const code = e && e.code ? e.code : "";
  if (code === "EPERM" || code === "EACCES" || code === "ENOSYS" || code === "UNKNOWN") {
    process.stderr.write("symlink creation denied: " + code + "\n");
    process.exit(77);
  }
  process.stderr.write("symlink failed: " + (e && e.message ? e.message : String(e)) + "\n");
  process.exit(1);
}

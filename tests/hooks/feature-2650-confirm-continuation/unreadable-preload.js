"use strict";
// NODE_OPTIONS --require preload: makes fs.readFileSync throw EACCES for the one file named by
// CC_UNREADABLE, so the plan exists (lstat / exists still see it) but its body cannot be read —
// the portable stand-in for chmod 000, which Windows does not honor.
const fs = require("fs");
const path = require("path");

const norm = (p) => {
  const r = path.resolve(String(p)).replace(/\\/g, "/");
  return process.platform === "win32" ? r.toLowerCase() : r;
};
const target = process.env.CC_UNREADABLE ? norm(process.env.CC_UNREADABLE) : null;
const orig = fs.readFileSync;
fs.readFileSync = function (p, ...rest) {
  if (target && (typeof p === "string" || p instanceof URL) && norm(p instanceof URL ? p.pathname : p) === target) {
    const e = new Error("EACCES: permission denied, open '" + p + "'");
    e.code = "EACCES";
    throw e;
  }
  return orig.call(this, p, ...rest);
};

"use strict";
// tests/lib/test-cache-base.js — the one place that decides where test caches live (#2590):
// <realpath(TEST_HOST_TMPDIR || os.tmpdir())>/agents-test-cache-<user>. Caches sit in the OS
// temp area the run started from, never under $HOME and never inside a run root, so every run
// and every fixture HOME shares one build. tests/lib/test-run-root.sh exports TEST_HOST_TMPDIR.

const fs = require("fs");
const os = require("os");
const path = require("path");

// Git Bash hands over /c/... paths that fs.* cannot open on Windows.
function toNative(p) {
  if (process.platform !== "win32") return p;
  const m = /^\/([A-Za-z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

function userName() {
  let name = "";
  try {
    name = os.userInfo().username;
  } catch (_) {}
  name = name || process.env.USER || process.env.USERNAME || "user";
  return name.replace(/[^A-Za-z0-9._-]/g, "_");
}

function testCacheBase() {
  const host = path.resolve(toNative(process.env.TEST_HOST_TMPDIR || os.tmpdir()));
  fs.mkdirSync(host, { recursive: true });
  let real = fs.realpathSync.native(host);
  if (process.platform === "win32") real = real.replace(/\\/g, "/");
  return `${real.replace(/\/+$/, "")}/agents-test-cache-${userName()}`;
}

module.exports = { testCacheBase, toNative };

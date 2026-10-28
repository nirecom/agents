"use strict";
// NODE_OPTIONS --require preload for tests/hooks/feature-2811-confirm-continue-active.js: reproduces a
// transcript that is flushed late. The first FLUSH reads of CC_REREAD_OLD (the 11 reads readTurnTail
// makes while it waits for the final message) return the old file; later reads return CC_REREAD_NEW.
// Without CC_REREAD_NEW every read returns the old file (the final message never reaches the transcript).
const fs = require("fs");
const path = require("path");

const FLUSH_READS = 11;
const norm = (p) => (process.platform === "win32" ? path.resolve(p).toLowerCase() : path.resolve(p));
const target = process.env.CC_REREAD_OLD ? norm(process.env.CC_REREAD_OLD) : "";
const fresh = process.env.CC_REREAD_NEW || "";
const original = fs.readFileSync;
let reads = 0;

fs.readFileSync = function (file, ...rest) {
  if (target && typeof file === "string" && norm(file) === target) {
    reads += 1;
    if (reads > FLUSH_READS && fresh) return original.call(this, fresh, ...rest);
  }
  return original.call(this, file, ...rest);
};

"use strict";
// NODE_OPTIONS --require preload for tests/hooks/feature-2811-confirm-continue-active.js: reproduces a
// transcript that is flushed late. When readTurnTail first returns for CC_REREAD_OLD (it has waited for
// the final message and given up), the bytes of CC_REREAD_APPEND are appended to that file on disk, so
// the settle-time re-read sees them whether it reads the whole file or only [span.end, size) (#2936).
// CC_REREAD_MARK receives {undecidable} of that first tail; without CC_REREAD_APPEND nothing is appended.
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const norm = (p) => (process.platform === "win32" ? path.resolve(p).toLowerCase() : path.resolve(p));
const target = process.env.CC_REREAD_OLD ? norm(process.env.CC_REREAD_OLD) : "";
const payloadPath = process.env.CC_REREAD_APPEND || "";
const markPath = process.env.CC_REREAD_MARK || "";

// lateFlush(tail): append once; a file that already ends with the payload (a later Stop) is left as is.
function lateFlush(tail) {
  const payload = fs.readFileSync(payloadPath);
  const cur = fs.readFileSync(process.env.CC_REREAD_OLD);
  if (cur.length >= payload.length && cur.subarray(cur.length - payload.length).equals(payload)) return;
  fs.appendFileSync(process.env.CC_REREAD_OLD, payload);
  if (markPath) fs.writeFileSync(markPath, JSON.stringify({ undecidable: !!(tail && tail.undecidable) }));
}

if (target && payloadPath) {
  const TR = require(path.join(ROOT, "hooks", "lib", "transcript-reader"));
  const original = TR.readTurnTail;
  let done = false;
  TR.readTurnTail = function (opts, ...rest) {
    const tail = original.call(this, opts, ...rest);
    const tp = opts && opts.input && opts.input.transcript_path;
    if (!done && typeof tp === "string" && norm(tp) === target) {
      done = true;
      lateFlush(tail);
    }
    return tail;
  };
}

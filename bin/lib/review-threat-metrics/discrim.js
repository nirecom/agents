"use strict";
// bin/lib/review-threat-metrics/discrim.js — a port of cl_discrim (bin/lib/concern-ledger/core.sh):
// the text's bytes are lower-cased as bash's ${1,,} does under LC_ALL=C, split into words,
// byte-sorted, joined by one space and hashed through a herestring (so a trailing newline is hashed
// too); the DISCRIM is the first 8 hex.
// Which bytes ${1,,} folds under LC_ALL=C depends on the host's C library: glibc folds only A-Z,
// while MSYS2 bash (Git Bash) also folds the Latin-1 capitals 0xC0-0xDE. The journal's DISCRIMs
// come from the local bash, so its behaviour is probed once instead of assumed.
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

let latin1Fold = null;

// foldsLatin1() — whether the local bash lower-cases byte 0xC3 under LC_ALL=C (false without bash).
function foldsLatin1() {
  if (latin1Fold === null) {
    const r = spawnSync("bash", ["-c", "LC_ALL=C; x=$(printf '\\303'); y=${x,,}; [ \"$x\" = \"$y\" ] && echo ascii || echo latin1"],
      { encoding: "utf8" });
    latin1Fold = r.status === 0 && String(r.stdout).trim() === "latin1";
  }
  return latin1Fold;
}

function fold(b) {
  if (b >= 0x41 && b <= 0x5a) return b + 0x20;
  if (b >= 0xc0 && b <= 0xde && b !== 0xd7 && foldsLatin1()) return b + 0x20;
  return b;
}

function discrim(text) {
  const bytes = Buffer.from(String(text).split("\n")[0], "utf8").map(fold);
  const words = [];
  let start = -1;
  for (let i = 0; i <= bytes.length; i++) {
    const sep = i === bytes.length || bytes[i] === 0x20 || bytes[i] === 0x09;
    if (!sep && start < 0) start = i;
    if (sep && start >= 0) {
      words.push(bytes.subarray(start, i));
      start = -1;
    }
  }
  words.sort(Buffer.compare);
  const parts = [];
  words.forEach((w, k) => parts.push(...(k ? [Buffer.from(" ")] : []), w));
  return crypto.createHash("sha256").update(Buffer.concat([...parts, Buffer.from("\n")])).digest("hex").slice(0, 8);
}

module.exports = { discrim };

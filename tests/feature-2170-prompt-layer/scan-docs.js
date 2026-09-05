#!/usr/bin/env node
// Feeds the shell snippets a prompt document tells the model to run through the very
// predicate the guard uses, so a doc can never re-introduce an instruction the hook
// would then block (the prompt-versus-guard deadlock of #2170).
//
// Usage: node scan-docs.js <mode> <file>...
//   mode=hits   -> one "<file>#<n>: <first line>" per capture-echo-shaped snippet
//   mode=count  -> total number of snippets examined (non-vacuity witness)
"use strict";

const fs = require("fs");
const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || path.join(__dirname, "..", "..");
const mode = process.argv[2];
const files = process.argv.slice(3);

let shape;
let parse;
try {
  shape = require(path.join(AGENTS_DIR, "hooks", "block-capture-echo", "shape.js"));
  ({ parse } = require(path.join(AGENTS_DIR, "hooks", "lib", "command-ir.js")));
} catch (_e) {
  process.stdout.write("MODULE_MISSING\n");
  process.exit(0);
}

// A fenced block whose info string names a POSIX shell is an instruction to run it.
const FENCE_RE = /^```(bash|sh|shell)\s*$/;

function snippetsOf(text) {
  const out = [];
  const lines = text.split(/\r?\n/);
  let buf = null;
  for (const line of lines) {
    if (buf === null) {
      if (FENCE_RE.test(line)) buf = [];
      continue;
    }
    if (/^```/.test(line)) {
      if (buf.length) out.push(buf.join("\n"));
      buf = null;
      continue;
    }
    buf.push(line);
  }
  return out;
}

let examined = 0;
const hits = [];
for (const f of files) {
  let text;
  try {
    text = fs.readFileSync(f, "utf8");
  } catch (_e) {
    hits.push(f + "#0: FILE_MISSING");
    continue;
  }
  const snippets = snippetsOf(text);
  snippets.forEach((snip, i) => {
    examined += 1;
    let ir;
    try {
      ir = parse(snip, { preserveSubstitutionSpans: true });
    } catch (_e) {
      return; // unparsable prose in a fence is not an instruction we can judge
    }
    if (!ir || ir.parseFailure) return;
    if (shape.detectCaptureEcho(ir)) {
      hits.push(path.basename(f) + "#" + (i + 1) + ": " + snip.split("\n")[0]);
    }
  });
}

if (mode === "count") {
  process.stdout.write(String(examined) + "\n");
} else {
  process.stdout.write(hits.length ? hits.join("\n") + "\n" : "");
}

#!/usr/bin/env node
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { getWorkflowPlansDir } = require("../hooks/lib/workflow-plans-dir");

const SRC = path.resolve(path.join(os.homedir(), ".claude", "plans"));
let DST;
try { DST = path.resolve(getWorkflowPlansDir()); }
catch (e) { console.error(`migrate-plans-dir: ${e.message}`); process.exit(2); }

// Guard: DST must not be inside SRC (self-copy/delete edge case).
const srcWithSep = SRC + path.sep;
if ((DST + path.sep).toLowerCase().startsWith(srcWithSep.toLowerCase()) || DST === SRC) {
  console.error(`migrate-plans-dir: destination ${DST} is inside source ${SRC}; aborting`);
  process.exit(2);
}

try { fs.accessSync(SRC); }
catch { console.log(`no-op: ${SRC} does not exist`); process.exit(0); }

fs.mkdirSync(DST, { recursive: true });

function bytesEqual(a, b) {
  const sa = fs.statSync(a), sb = fs.statSync(b);
  if (sa.size !== sb.size) return false;
  return Buffer.compare(fs.readFileSync(a), fs.readFileSync(b)) === 0;
}

// First pass: plan all actions, fail fast on content conflicts.
const actions = [];
function walk(srcDir, dstDir) {
  fs.mkdirSync(dstDir, { recursive: true });
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const s = path.join(srcDir, entry.name);
    const d = path.join(dstDir, entry.name);
    if (entry.isDirectory()) { walk(s, d); continue; }
    if (!entry.isFile()) continue;
    if (fs.existsSync(d)) {
      if (bytesEqual(s, d)) { actions.push({ src: s, dst: d, kind: "skip-identical" }); }
      else {
        console.error(`migrate-plans-dir: conflict — ${d} exists with different content; aborting (source preserved)`);
        process.exit(3);
      }
    } else { actions.push({ src: s, dst: d, kind: "copy" }); }
  }
}
walk(SRC, DST);

// Second pass: execute copies.
for (const a of actions) {
  if (a.kind === "copy") fs.copyFileSync(a.src, a.dst);
}

// Verify all source files present at destination before deleting source.
function verify(srcDir, dstDir) {
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const s = path.join(srcDir, entry.name);
    const d = path.join(dstDir, entry.name);
    if (entry.isDirectory()) { verify(s, d); continue; }
    if (!entry.isFile()) continue;
    if (!fs.existsSync(d) || !bytesEqual(s, d)) {
      console.error(`migrate-plans-dir: verification failed for ${s}; source preserved`);
      process.exit(4);
    }
  }
}
verify(SRC, DST);

fs.rmSync(SRC, { recursive: true, force: true });
const skipped = actions.filter(a => a.kind === "skip-identical").length;
console.log(`migrated ${SRC} → ${DST} (${actions.length} entries; ${skipped} identical)`);

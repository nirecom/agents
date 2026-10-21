"use strict";
// Tests: bin/glossary-promote
// Tags: TL2, bin, glossary, provenance, promote, fixture, scope:issue-specific
// Shared by the parts of tests/bin/feat-2529-glossary-promote.js. Builds on the provenance
// fixture (isolated state + plans dirs, approved sessions) and adds the promote runner and
// a glossary-file snapshot so every block case can assert "nothing was written".

const c = require("../feat-2529-glossary-provenance/common");

const FILES = ["docs/glossary/user.md", "docs/glossary/internal.md"];

// promote(intent, repo) — node bin/glossary-promote <intent.md> <repo-root>.
function promote(intent, repo) {
  return c.runNode("bin/glossary-promote", [c.fwd(intent), repo], { cwd: repo });
}

// snapshot(repo) — the bytes of both category files (null when absent).
function snapshot(repo) {
  return FILES.map((f) => c.readFile(repo, f));
}
function unchanged(repo, before) {
  c.eq(snapshot(repo), before, "glossary files after a block");
}

// termsOf(text) — { term(lowercase): definition } of one entry file.
function termsOf(text) {
  const out = {};
  let cur = null;
  for (const line of String(text || "").split(/\r?\n/)) {
    const h = /^### (.+?)\s*$/.exec(line);
    if (h) { cur = h[1].toLowerCase(); out[cur] = null; continue; }
    const d = /^- \*\*Definition\*\*:\s*(.*)$/.exec(line);
    if (d && cur !== null) out[cur] = d[1].trim();
  }
  return out;
}
const userTerms = (repo) => termsOf(c.readFile(repo, FILES[0]));
const internalTerms = (repo) => termsOf(c.readFile(repo, FILES[1]));

// counters(out) — the ADDED= ... SKIPPED_SESSION= line as an object.
function counters(out) {
  const res = {};
  for (const k of ["ADDED", "DELETED", "REDEFINED", "SKIPPED_EXISTING", "SKIPPED_SESSION"]) {
    const m = new RegExp(`\\b${k}=(\\d+)`).exec(out || "");
    res[k] = m ? Number(m[1]) : null;
  }
  return res;
}

// blockLine(term, op, cat, reason) — the `  BLOCK: <term> <operation> <category>: <reason>` form.
function blockLine(term, op, cat, reason) {
  return new RegExp(`BLOCK: ${term} ${op} ${cat}: ${reason}`);
}

// session(tag, rows) — a fresh BASE repo plus an approved session holding `rows`.
function session(tag, rows, opts) {
  const repo = c.mkRepo(tag);
  const sid = c.approvedSession(tag, rows, Object.assign({ cwd: repo }, opts || {}));
  return { repo, sid, intent: c.intentPath(sid) };
}

module.exports = Object.assign({}, c, { FILES, promote, snapshot, unchanged, termsOf, userTerms, internalTerms, counters, blockLine, session });

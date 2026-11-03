"use strict";
// hooks/workflow-run-tests/hit-summary.js — the unattributed hit lines of one run (#2669), read
// from the emitter's own bytes: run-all's column-0 `HIT: ` lines (a child's copy arrives
// neutralized, so never at column 0), or the worker header's `hits:` list (the header ends at
// `log_tail: |`, so suite bytes never reach it). The count itself is the contract's HITS.

const { sanitizeLine } = require("../lib/output-sanitize");

const MAX_HIT_SUMMARY = 20;
const MAX_HIT_LINE = 300;
const RUN_ALL_HIT_RE = /^HIT: (.+)$/;
const WORKER_ITEM_RE = /^ {2}- '(.*)'$/;

const linesOf = (text) => (typeof text === "string" ? text.split("\n").map((l) => l.replace(/\r$/, "")) : []);

function runAllHits(stdout) {
  const out = [];
  for (const line of linesOf(stdout)) {
    const m = RUN_ALL_HIT_RE.exec(line);
    if (m !== null) out.push(m[1]);
  }
  return out;
}

// workerHits(header) — the items of the header's `hits:` block, YAML single quotes undone.
function workerHits(header) {
  const lines = linesOf(header);
  const at = lines.indexOf("hits:");
  if (at < 0) return [];
  const out = [];
  for (const line of lines.slice(at + 1)) {
    const m = WORKER_ITEM_RE.exec(line);
    if (m === null) break;
    out.push(m[1].replace(/''/g, "'"));
  }
  return out;
}

// boundHits(list) — what state may hold: at most 20 entries, each sanitized and capped.
function boundHits(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((h) => typeof h === "string").slice(0, MAX_HIT_SUMMARY).map((h) => sanitizeLine(h, MAX_HIT_LINE));
}

// hitTestId(line) — the test a `worktree-change <id> tree=…` hit names; null for any other hit
// and for `(no test id)`. Only such an id can be rerun alone (#2688, #2803).
const WCD_ID_RE = /^worktree-change (.+?) tree=/;
function hitTestId(line) {
  const m = typeof line === "string" ? WCD_ID_RE.exec(line) : null;
  return m === null || m[1] === "(no test id)" ? null : m[1];
}

module.exports = { MAX_HIT_SUMMARY, runAllHits, workerHits, boundHits, hitTestId };

"use strict";
// failing-list.js — the repo-relative failing test paths a trusted run reported
// (#2431). The list feeds bin/run-tests-baseline, which re-executes each entry at
// the merge base, so an entry must name a real test kind under tests/ or the
// whole list is withheld (null): a partial list would under-classify silently.

const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { tryLoadRegistry, matchBasename } = require("../lib/test-language-registry");

const RUN_ALL_FAIL_RE = /^FAIL: (.+) \(exit -?\d+\)$/;
const LOG_TAIL_RE = /^log_tail:[ \t]*\|/;
const WORKER_ITEM_RE = /^ {2}- '((?:[^']|'')*)'\s*$/;

// The supported registry entry run_all_exec would launch the file with; null when none
// (or the table is unreadable, which withholds the whole list).
function classifyTestKind(p) {
  if (typeof p !== "string") return null;
  const reg = tryLoadRegistry();
  if (!reg) return null;
  const hit = matchBasename(p.replace(/\\/g, "/").split("/").pop(), reg);
  return hit && hit.status === "supported" ? hit.id : null;
}

function slashed(p) {
  return String(normalizeCwd(p) || p).replace(/\\/g, "/");
}

function startsWithPath(full, prefix) {
  if (process.platform === "win32") return full.toLowerCase().startsWith(prefix.toLowerCase());
  return full.startsWith(prefix);
}

function normalizeTestPath(p, root) {
  if (typeof p !== "string" || p.trim() === "") return null;
  const raw = p.trim();
  if (raw.split(/[\\/]/).includes("..")) return null;
  let rel = slashed(raw);
  if (path.isAbsolute(normalizeCwd(raw) || raw) || /^[A-Za-z]:\//.test(rel)) {
    if (typeof root !== "string" || root === "") return null;
    const prefix = `${slashed(root).replace(/\/+$/, "")}/`;
    if (!startsWithPath(rel, prefix)) return null;
    rel = rel.slice(prefix.length);
  }
  rel = rel.replace(/^(\.\/)+/, "");
  if (!rel.startsWith("tests/")) return null;
  return classifyTestKind(rel) === null ? null : rel;
}

function runAllNames(stdout) {
  const out = [];
  for (const line of stdout.replace(/\r\n/g, "\n").split("\n")) {
    const m = RUN_ALL_FAIL_RE.exec(line);
    if (m !== null) out.push(m[1]);
  }
  return out;
}

function workerNames(stdout) {
  const out = [];
  let inList = false;
  for (const line of stdout.replace(/\r\n/g, "\n").split("\n")) {
    if (LOG_TAIL_RE.test(line)) break;
    if (/^failing_tests:\s*$/.test(line)) { inList = true; continue; }
    if (!inList) continue;
    const m = WORKER_ITEM_RE.exec(line);
    if (m === null) { inList = false; continue; }
    out.push(m[1].replace(/''/g, "'"));
  }
  return out;
}

// The checkout the emitter lives in: tests/run-all.sh and bin/worker-dispatch.js
// both sit two levels below their repo root.
function emitterRoot(emitterPath, cwd) {
  if (typeof emitterPath !== "string" || emitterPath === "") return null;
  const base = normalizeCwd(cwd) || process.cwd();
  return path.resolve(base, normalizeCwd(emitterPath) || emitterPath, "..", "..");
}

function extractFailingTests({ stdout, isWorker, worktreeRoot, contract } = {}) {
  if (typeof stdout !== "string" || !contract || typeof contract.fail !== "number") return null;
  const names = isWorker ? workerNames(stdout) : runAllNames(stdout);
  if (names.length !== contract.fail) return null;
  const out = [];
  for (const n of names) {
    const rel = normalizeTestPath(n, worktreeRoot);
    if (rel === null) return null;
    out.push(rel);
  }
  return out;
}

module.exports = { extractFailingTests, classifyTestKind, normalizeTestPath, emitterRoot };

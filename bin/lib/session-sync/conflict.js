"use strict";
// Non-jsonl both-changed resolution (#2658): newer side wins outside the clock-skew window.

const SKEW_MS = 120000;

function decide({ localMtimeMs, remoteTimeMs }) {
  if (localMtimeMs - remoteTimeMs > SKEW_MS) return "local";
  if (remoteTimeMs - localMtimeMs > SKEW_MS) return "remote";
  return "both";
}

function stamp(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z").replace(/[-:]/g, "");
}

function splitName(rel) {
  const slash = rel.lastIndexOf("/");
  const dir = slash >= 0 ? rel.slice(0, slash + 1) : "";
  const base = rel.slice(slash + 1);
  const dot = base.lastIndexOf(".");
  return { head: `${dir}${dot > 0 ? base.slice(0, dot) : base}`, ext: dot > 0 ? base.slice(dot) : "" };
}

function siblingName(rel, host, date, existsFn) {
  const { head: stem, ext } = splitName(rel);
  const head = `${stem}.sync-conflict-${host}-${stamp(date)}`;
  let name = `${head}${ext}`;
  for (let n = 2; existsFn(name); n += 1) name = `${head}-${n}${ext}`;
  return name;
}

// Deterministic in rel and blob, so every machine and every repeated run converge on one copy.
function collisionCopyName(rel, blob) {
  const { head, ext } = splitName(rel);
  return `${head}.sync-conflict-${blob.slice(0, 12)}${ext}`;
}

module.exports = { SKEW_MS, decide, siblingName, collisionCopyName };

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

function siblingName(rel, host, date, existsFn) {
  const slash = rel.lastIndexOf("/");
  const dir = slash >= 0 ? rel.slice(0, slash + 1) : "";
  const base = rel.slice(slash + 1);
  const dot = base.lastIndexOf(".");
  const stem = dot > 0 ? base.slice(0, dot) : base;
  const ext = dot > 0 ? base.slice(dot) : "";
  const head = `${dir}${stem}.sync-conflict-${host}-${stamp(date)}`;
  let name = `${head}${ext}`;
  for (let n = 2; existsFn(name); n += 1) name = `${head}-${n}${ext}`;
  return name;
}

module.exports = { SKEW_MS, decide, siblingName };

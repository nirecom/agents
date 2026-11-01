"use strict";
// noNewFailures(count, fn) — the node:test verdict of a counter-style case (#2865): its checks tally
// failures instead of throwing, so the case fails when the tally grew while fn ran (async fn awaited).

async function noNewFailures(count, fn) {
  if (typeof count !== "function") throw new TypeError("noNewFailures: count must be a function returning the failure tally");
  const before = count();
  const r = fn();
  if (r && typeof r.then === "function") await r;
  const after = count();
  if (after > before) {
    throw new Error(`noNewFailures: failure count rose from ${before} to ${after} (+${after - before}) while the case ran`);
  }
}

module.exports = { noNewFailures };

"use strict";
// hooks/lib/jev/liveness.js — per-session cache of a successful GET /v1/models probe.
// Only success is cached ({checked_at_ms}, epoch ms); a failed probe is never cached,
// so the next dispatch probes again (the breaker is what stops the retries).

const path = require("path");
const { sessionDir, readJson, writeJsonAtomic } = require("./state-paths");

const LIVENESS_TTL_MS = 600000;

function livenessPath(sid) {
  return path.join(sessionDir(sid), "liveness.json");
}

function isFresh(sid, opts = {}) {
  const now = opts.now ? opts.now() : Date.now();
  const ttl = opts.ttlMs || LIVENESS_TTL_MS;
  const o = readJson(livenessPath(sid));
  if (!o || typeof o.checked_at_ms !== "number" || !Number.isFinite(o.checked_at_ms)) return false;
  const age = now - o.checked_at_ms;
  return age >= 0 && age < ttl;
}

function markLive(sid, opts = {}) {
  const now = opts.now ? opts.now() : Date.now();
  try {
    writeJsonAtomic(livenessPath(sid), { checked_at_ms: now });
  } catch (_e) { /* cache only — a lost write costs one extra probe */ }
}

module.exports = { LIVENESS_TTL_MS, isFresh, markLive, livenessPath };

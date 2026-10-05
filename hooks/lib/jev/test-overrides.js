"use strict";
// hooks/lib/jev/test-overrides.js — entry-time snapshot of the JEV_* test overrides.
// Every entrypoint calls captureTestOverrides(process.env) before anything requires
// load-env: loadDefaultEnv injects .env values into process.env, so a snapshot taken
// later could mistake a JEV_BASE_URL written in a .env file for a caller export.
// Leaf module by design: it must never require load-env or another jev module.

const TIMEOUT_CAP_MS = 12000;
const PENDING_TTL_CAP_MS = 86400000;
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost"]);

// Loopback hosts only (http or https), never embedded credentials: a test override
// must not be able to carry the real API key and request body to another host.
function parseBaseUrl(raw) {
  if (typeof raw !== "string" || raw.trim() === "") return null;
  let u;
  try {
    u = new URL(raw.trim());
  } catch (_e) {
    return null;
  }
  if (u.username || u.password) return null;
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  if (!LOOPBACK_HOSTS.has(u.hostname)) return null;
  return u.origin + u.pathname.replace(/\/+$/, "");
}

function parsePositiveInt(raw, cap) {
  if (typeof raw !== "string" || !/^\d+$/.test(raw.trim())) return null;
  const n = Number(raw.trim());
  if (!Number.isSafeInteger(n) || n <= 0) return null;
  return Math.min(n, cap);
}

function captureTestOverrides(env) {
  const src = env || {};
  return Object.freeze({
    baseUrl: parseBaseUrl(src.JEV_BASE_URL),
    httpTimeoutMs: parsePositiveInt(src.JEV_HTTP_TIMEOUT_MS, TIMEOUT_CAP_MS),
    pendingTtlMs: parsePositiveInt(src.JEV_PENDING_TTL_MS, PENDING_TTL_CAP_MS),
  });
}

module.exports = { captureTestOverrides, TIMEOUT_CAP_MS, PENDING_TTL_CAP_MS };

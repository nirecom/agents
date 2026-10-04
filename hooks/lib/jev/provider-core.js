"use strict";
// hooks/lib/jev/provider-core.js — the Jev HTTP client (init / check / probe / run / log).
// Every outcome collapses to one enum status. Nothing from the response reaches a caller
// unsanitised: error bodies are cancelled unread, a success body is read up to a byte cap,
// redirects are refused, the model name is charset/length-capped, usage must be a sane
// integer. The API key rides only in the Authorization header and is held off the
// enumerable ctx fields so no log or JSON.stringify can pick it up.

const { resolveConfigVar } = require("../load-env");

const DEFAULT_BASE_URL = "https://api.typesafe.ai";
const PROBE_TIMEOUT_MS = 2000;
const QUERY_TIMEOUT_MS = 6000;
const MAX_RESPONSE_BYTES = 65536;
const REQUEST_MODEL = "jev-latest";
const COST_PER_INPUT_TOKEN_USD = 0.042 / 1e6;
const MODEL_RE = /^[A-Za-z0-9._-]{1,64}$/;
// Statuses the circuit breaker counts as an outage; the rest are not failures of Jev.
const OUTAGE_STATUSES = new Set(["unreachable", "timeout", "http-error", "bad-response"]);

// Pure: only the entry snapshot (never a .env value) can move the endpoint.
function resolveEndpoint(overrides) {
  return (overrides && overrides.baseUrl) || DEFAULT_BASE_URL;
}

function jevCoreInit({ sessionId, overrides } = {}) {
  const ov = overrides || {};
  // The timeout override is test-only: it must never stretch a production query past the hook budget.
  const timeoutOv = ov.baseUrl ? ov.httpTimeoutMs : null;
  const ctx = {
    sessionId,
    baseUrl: resolveEndpoint(ov),
    probeTimeoutMs: timeoutOv || PROBE_TIMEOUT_MS,
    queryTimeoutMs: timeoutOv || QUERY_TIMEOUT_MS,
    startMs: Date.now(),
  };
  Object.defineProperty(ctx, "apiKey", { value: "", writable: true, enumerable: false });
  return ctx;
}

// A .env load failure counts as no key: the key is never guessed from a partial load.
function jevCoreCheck(ctx) {
  let key = "";
  try {
    const r = resolveConfigVar("TYPESAFE_API_KEY", "");
    key = r.loadFailed ? "" : String(r.value || "").trim();
  } catch (_e) {
    key = "";
  }
  ctx.apiKey = key;
  return key ? { ok: true, status: "ok" } : { ok: false, status: "no-key" };
}

function sanitizeModel(m) {
  return typeof m === "string" && MODEL_RE.test(m) ? m : "unknown";
}

function sanitizeTokens(n) {
  return Number.isSafeInteger(n) && n >= 0 ? n : null;
}

// Awaited so the stream is fully closed before the hook exits: an in-flight cancel at
// process.exit trips a libuv assertion on Windows (UV_HANDLE_CLOSING) and exits 127.
async function discardBody(res) {
  try {
    if (res && res.body && typeof res.body.cancel === "function") await res.body.cancel();
  } catch (_e) { /* body already consumed or closed */ }
}

// The body as UTF-8 text, or null once it declares or delivers more than MAX_RESPONSE_BYTES;
// the overrun stream is cancelled and awaited closed, for the reason given at discardBody.
async function readCappedText(res) {
  if (Number(res.headers.get("content-length")) > MAX_RESPONSE_BYTES) {
    await discardBody(res);
    return null;
  }
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_RESPONSE_BYTES) {
      try {
        await reader.cancel();
      } catch (_e) { /* stream already closed */ }
      return null;
    }
    chunks.push(value);
  }
  return new TextDecoder("utf-8").decode(Buffer.concat(chunks));
}

// fetch with an abort timer that also covers reading the body. A redirect is an error
// (surfacing as unreachable): the POST body and the key never follow one to another origin.
async function timedRequest(url, init, timeoutMs, readBody) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const res = await fetch(url, Object.assign({}, init, { signal: ac.signal, redirect: "error" }));
    if (!res.ok) {
      await discardBody(res);
      return { status: "http-error", http_status: res.status };
    }
    if (!readBody) {
      await discardBody(res);
      return { status: "ok", http_status: null };
    }
    let text;
    try {
      text = await readCappedText(res);
    } catch (_e) {
      return { status: ac.signal.aborted ? "timeout" : "unreachable", http_status: null };
    }
    if (text === null) return { status: "bad-response", http_status: null };
    return { status: "ok", http_status: null, text };
  } catch (_e) {
    return { status: ac.signal.aborted ? "timeout" : "unreachable", http_status: null };
  } finally {
    clearTimeout(timer);
  }
}

function authHeaders(ctx) {
  return { authorization: "Bearer " + ctx.apiKey, accept: "application/json" };
}

// A failed request keeps its own outage status (http-error with its code, timeout, ...) so a
// bad key reads apart from an outage; any other status is unreachable, a non-integer code null.
function normalizeFailure(r) {
  return {
    status: OUTAGE_STATUSES.has(r.status) ? r.status : "unreachable",
    http_status: Number.isInteger(r.http_status) ? r.http_status : null,
  };
}

async function jevCoreProbe(ctx) {
  const r = await timedRequest(ctx.baseUrl + "/v1/models", { method: "GET", headers: authHeaders(ctx) },
    ctx.probeTimeoutMs, false);
  if (r.status === "ok") return { ok: true, status: "ok" };
  const { status, http_status } = normalizeFailure(r);
  return http_status === null ? { ok: false, status } : { ok: false, status, http_status };
}

async function jevCoreRun(ctx, { state, questions }) {
  const t0 = Date.now();
  const headers = Object.assign({ "content-type": "application/json" }, authHeaders(ctx));
  const body = JSON.stringify({ state, model: REQUEST_MODEL, questions });
  const r = await timedRequest(ctx.baseUrl + "/v1/systemone", { method: "POST", headers, body },
    ctx.queryTimeoutMs, true);
  const latency_ms = Math.max(0, Date.now() - t0);
  if (r.status !== "ok") return Object.assign(normalizeFailure(r), { latency_ms });
  let parsed;
  try {
    parsed = JSON.parse(r.text);
  } catch (_e) {
    return { status: "bad-response", http_status: null, latency_ms };
  }
  if (!parsed || typeof parsed !== "object" || !parsed.answers || typeof parsed.answers !== "object") {
    return { status: "bad-response", http_status: null, latency_ms };
  }
  const input_tokens = sanitizeTokens(parsed.usage && parsed.usage.input_tokens);
  return {
    status: "ok",
    http_status: null,
    latency_ms,
    response: { answers: parsed.answers },
    model: sanitizeModel(parsed.model),
    input_tokens,
    est_cost_usd: input_tokens === null ? null : input_tokens * COST_PER_INPUT_TOKEN_USD,
  };
}

// Classification only; the broker owns every file write.
function jevCoreLog(_ctx, result) {
  const status = (result && result.status) || "bad-response";
  return { status, counts_as_outage: OUTAGE_STATUSES.has(status) };
}

// One stderr line: the enum reason and the numeric HTTP status, nothing else.
function jevCoreEmitFailed(_ctx, reason, httpStatus) {
  const code = Number.isInteger(httpStatus) ? ` http ${httpStatus}` : "";
  try {
    process.stderr.write(`[jev-shadow] query failed: ${String(reason)}${code}\n`);
  } catch (_e) { /* stderr closed */ }
}

module.exports = {
  DEFAULT_BASE_URL,
  PROBE_TIMEOUT_MS,
  QUERY_TIMEOUT_MS,
  MAX_RESPONSE_BYTES,
  MODEL_RE,
  OUTAGE_STATUSES,
  resolveEndpoint,
  sanitizeModel,
  jevCoreInit,
  jevCoreCheck,
  jevCoreProbe,
  jevCoreRun,
  jevCoreLog,
  jevCoreEmitFailed,
};

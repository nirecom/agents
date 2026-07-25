"use strict";
// Write-side model identification (#1611): resolve WHICH model is driving the
// current session, so the flag in the session state file can be frozen once.
//
// Two layers, tried in order:
//   layer① the hook payload's `model` field (SessionStart stdin),
//   layer② SESSION_MODEL_ID, after loadDefaultEnv() so a .env value counts.
// Layer③ (the model's own self-report) is not resolvable from here — it arrives
// later through bin/record-session-model.js.
//
// The live shape of layer① is not verified upstream, so all three observed
// shapes are accepted: a bare string, an object, or an absent field. Every
// error path returns null, which means "do not inject" (fail-open).

const { loadDefaultEnv } = require("./load-env");

// Pull a usable identifier out of a hook payload. `model` may be a string, or
// an object carrying `id` (preferred) and/or `display_name`.
function extractModelIdFromHookInput(input) {
  try {
    if (!input || typeof input !== "object") return null;
    const model = input.model;
    if (typeof model === "string") return model.trim() || null;
    if (!model || typeof model !== "object") return null;
    for (const key of ["id", "display_name"]) {
      const value = model[key];
      if (typeof value === "string" && value.trim()) return value.trim();
    }
    return null;
  } catch (_) {
    return null;
  }
}

// { id, source } for the first layer that yields an identifier, else null.
// `source` is persisted so the layer that actually fired stays observable.
function resolveModelId(input) {
  try {
    const fromHook = extractModelIdFromHookInput(input);
    if (fromHook) return { id: fromHook, source: "hook-input" };

    loadDefaultEnv();
    const fromEnv = process.env.SESSION_MODEL_ID;
    if (typeof fromEnv === "string" && fromEnv.trim()) {
      return { id: fromEnv.trim(), source: "env" };
    }
    return null;
  } catch (_) {
    return null;
  }
}

module.exports = { extractModelIdFromHookInput, resolveModelId };

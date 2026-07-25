"use strict";
// Write-side model identification (#1611): resolve WHICH model is driving the
// current session, so the flag in the session state file can be frozen once.
//
// Single layer: the hook payload's `model` field (SessionStart stdin).
//
// The live shape is not verified upstream, so all three observed shapes are
// accepted: a bare string, an object, or an absent field. Every error path
// returns null, which means "do not inject" (fail-open).

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

// { id, source } when the hook payload yields an identifier, else null.
// `source` is persisted so the layer that actually fired stays observable.
function resolveModelId(input) {
  try {
    const fromHook = extractModelIdFromHookInput(input);
    if (fromHook) return { id: fromHook, source: "hook-input" };
    return null;
  } catch (_) {
    return null;
  }
}

module.exports = { extractModelIdFromHookInput, resolveModelId };

"use strict";
// AUTO_MERGE_PR (#2527 4-2): whether the model may merge the PR itself ("on", the
// default) or the user merges it on the web ("off"). Read through the same rule as
// bin/get-config-var. An unreadable config falls back to "on" — the user-verified
// dialog — so a broken read can never silently move the release decision to the web.

const loadEnv = require("./load-env");
const { isOffValue } = require("./off-value");

const SOURCE_BY_LAYER = Object.freeze({ export: "config", "env-file": "config", default: "default" });

// opts.repoDir — the project whose .env.local overlay applies; omitted, the process cwd decides.
function readAutoMergePr(opts) {
  try {
    const repoRoot = opts && typeof opts.repoDir === "string" && opts.repoDir ? opts.repoDir : undefined;
    // Through the module object, never a destructured copy: callers may patch it.
    const r = loadEnv.resolveConfigVar("AUTO_MERGE_PR", "on", repoRoot ? { repoRoot } : undefined);
    if (!r || r.loadFailed) return { value: "on", readable: false, source: "fallback" };
    return {
      value: isOffValue(r.value) ? "off" : "on",
      readable: true,
      source: SOURCE_BY_LAYER[r.source] || "default",
    };
  } catch (_) {
    return { value: "on", readable: false, source: "fallback" };
  }
}

module.exports = { readAutoMergePr };

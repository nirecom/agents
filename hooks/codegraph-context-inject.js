#!/usr/bin/env node
// codegraph-context-inject.js — UserPromptSubmit hook that forwards the CodeGraph
// CLI's own per-prompt context into the session.
//
// Upstream ships this as a hook its own installer writes into
// ~/.claude/settings.json; this framework refuses that installer, which also
// rewrites ~/.claude/CLAUDE.md, and calls the same subcommand itself. Every
// failure path prints `{}` and exits 0 — a CodeGraph problem must never cost
// a prompt. Design: docs/architecture/claude-code.md, docs/ops/codegraph.md.

const { readHookInput } = require("./lib/read-stdin");
const {
  codegraphEnabled,
  spawnCodegraph,
  normalizePayloadCwd,
  promptHookScopeAllows,
} = require("./lib/codegraph-boundary");

const SPAWN_TIMEOUT_MS = 4000;

function nothing() {
  console.log("{}");
  process.exit(0);
}

function main() {
  if (!codegraphEnabled()) nothing();

  const r = readHookInput();
  if (r.kind !== "ok") nothing();
  const raw = r.text;
  const input = r.input;
  if (!input || typeof input !== "object") nothing();

  // The gate and the child must judge the same root: re-serialize only when
  // normalization actually changed the cwd, so every other payload reaches the
  // child byte-identical.
  const normalized = normalizePayloadCwd(input.cwd);
  if (!promptHookScopeAllows(normalized)) nothing();
  const payload = typeof input.cwd === "string" && normalized !== input.cwd
    ? JSON.stringify({ ...input, cwd: normalized })
    : raw;

  const result = spawnCodegraph(["prompt-hook"], {
    input: payload,
    encoding: "utf8",
    timeout: SPAWN_TIMEOUT_MS,
  });
  if (!result || result.error || result.status !== 0) nothing();
  const context = String(result.stdout || "");
  if (context === "") nothing();

  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: context,
    },
  }));
  process.exit(0);
}

try {
  main();
} catch (_) {
  nothing();
}

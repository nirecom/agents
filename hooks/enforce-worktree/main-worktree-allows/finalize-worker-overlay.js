"use strict";
// hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
// Sole HARD gate for env VALUES and path/enum ARGUMENTS of the finalize-worker
// scripts: their internal fs.writeFileSync calls are invisible to
// collectBashWriteTargets' outer-redirect-only scan, so identity alone is not
// enough — env and args must be validated structurally here.
// G5_DECISION_VALUES must be kept in sync with run-loop-step.js's accepted
// decision values in the same diff if they ever change.

const path = require("path");
const { normalizeCwd } = require("../../lib/path-normalize");
const { normalizeForCompare } = require("../git-repo-detection");
const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");

// SSOT enum for the enum-g5 argSpec — mirrors run-loop-step.js's accepted decisions.
const G5_DECISION_VALUES = ["accept", "decline", "llm_declined", "recurse_done"];

// Per-script HARD-validation metadata. `rel` is the repo-relative script path;
// `matchable:false` entries are registry-known but never matched at top level
// (step-g5-loop.sh is a subprocess-only child of run-loop-step.js / run-initial.sh).
const FINALIZE_OVERLAY_REGISTRY = [
  {
    rel: "skills/issue-close-finalize/scripts/run-initial.sh",
    interpreter: "bash",
    requiredEnv: ["AGENTS_CONFIG_DIR", "FINALIZE_SCRIPTS_DIR", "MAIN_WORKTREE_PATH"],
    argCountMin: 3,
    argCountMax: 3,
    argSpec: ["id", "id", "id"],
    matchable: true,
  },
  {
    rel: "skills/issue-close-finalize/scripts/run-loop-step.js",
    interpreter: "node",
    requiredEnv: ["AGENTS_CONFIG_DIR", "FINALIZE_SCRIPTS_DIR"],
    argCountMin: 2,
    argCountMax: 2,
    argSpec: ["path-plansdir", "enum-g5"],
    matchable: true,
  },
  {
    rel: "skills/issue-close-finalize/scripts/run-finalize-terminal.sh",
    interpreter: "bash",
    requiredEnv: ["AGENTS_CONFIG_DIR"],
    argCountMin: 3,
    argCountMax: 3,
    argSpec: ["path-plansdir", "id", "path-plansdir"],
    matchable: true,
  },
  {
    rel: "skills/issue-close-finalize/scripts/step-g5-loop.sh",
    interpreter: "bash",
    requiredEnv: ["AGENTS_CONFIG_DIR"],
    argCountMin: 2,
    argCountMax: 3,
    argSpec: ["id", "id", "id"],
    matchable: false,
  },
];

// Canonical implementation of the arg-tail safety scan (mirrors the reject set in
// worker-script.js's legacy structural scan): chaining / substitution / newline /
// bare background operator are all unsafe.
function isUnsafeArgTail(str) {
  if (typeof str !== "string") return true;
  if (/\|\||&&|;|\$\(|`|<\(|>\(|\n/.test(str)) return true;
  if (/&(?!>)/.test(str)) return true;
  return false;
}

// path.resolve + Windows-safe normalization + lowercase (identity-comparison form
// for script paths and env path values — matches worker-script.js's normScript).
function normLower(p) {
  return path.resolve(normalizeCwd(p) || p).toLowerCase();
}

// True when `token` resolves to a path genuinely inside the workflow plans dir.
// Uses path.resolve + separator-boundary containment (not naive string-prefix) so
// sibling-prefix lookalikes (<plans>-evil/...) and ..-traversal escapes are rejected.
function isUnderPlansDir(token) {
  try {
    if (typeof token !== "string" || /[$`~]/.test(token)) return false;
    let plansDir;
    try {
      plansDir = getWorkflowPlansDir();
    } catch (_) {
      return false;
    }
    if (!plansDir) return false;
    const normPlans = normalizeForCompare(normalizeCwd(plansDir) || plansDir);
    const normTok = normalizeForCompare(normalizeCwd(token) || token);
    if (!normPlans || !normTok) return false;
    if (normTok === normPlans) return true;
    return normTok.startsWith(normPlans + path.sep) || normTok.startsWith(normPlans + "/");
  } catch (_) {
    return false;
  }
}

/**
 * HARD-validate a single-line finalize-worker `eval` invocation. Returns
 * { scriptPath: <normalized> } on a full pass, or null on any rejection
 * (fail-closed). The caller then defers only to the shared write-scope tail.
 */
function matchFinalizeWorkerOverlay(cmd, acd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return null;
  if (!acd) return null;
  if (cmd.includes("\n") || cmd.includes("\r")) return null;

  // Outer wrapper: eval "$(...)" with an optional `|| exit 0` tail and nothing else.
  const mOuter = cmd.match(/^\s*eval\s+"\$\((.+)\)"\s*(?:\|\|\s*exit\s+0\s*)?$/);
  if (!mOuter) return null;
  const inner = mOuter[1];

  // Inner: (env KEY="VALUE" span) (bash|node) "script-path-literal" (arg tail).
  const mInner = inner.match(
    /^\s*((?:[A-Za-z_][A-Za-z0-9_]*="[^"]*"\s+)*)(bash|node)\s+"([^"]+)"\s*([\s\S]*)$/
  );
  if (!mInner) return null;
  const envSpan = mInner[1] || "";
  const interpreter = mInner[2];
  const scriptLiteral = mInner[3];
  const argTail = (mInner[4] || "").trim();

  // Script path must be a fully-resolved literal — no indirection.
  if (/[$`~]/.test(scriptLiteral)) return null;

  let normScript;
  try {
    normScript = normLower(scriptLiteral);
  } catch (_) {
    return null;
  }

  // Identity: resolve against every matchable registry entry under acd.
  let entry = null;
  for (const e of FINALIZE_OVERLAY_REGISTRY) {
    if (!e.matchable) continue;
    let expected;
    try {
      expected = normLower(path.join(acd, e.rel));
    } catch (_) {
      continue;
    }
    if (expected === normScript) {
      entry = e;
      break;
    }
  }
  if (!entry) return null;

  // Interpreter binding — exact, case-sensitive.
  if (interpreter !== entry.interpreter) return null;

  // Env HARD gate: whitelist keys, no indirection in values, values match canonicals,
  // and the present key SET must exactly equal requiredEnv.
  const WHITELIST = new Set(["AGENTS_CONFIG_DIR", "FINALIZE_SCRIPTS_DIR", "MAIN_WORKTREE_PATH"]);
  const acdNorm = normLower(acd);
  const fsdNorm = normLower(path.join(acd, "skills", "issue-close-finalize", "scripts"));
  const rootNorm = normalizeForCompare(normalizeCwd(repoRoot) || repoRoot);
  const present = new Set();
  const envRe = /([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"/g;
  let em;
  while ((em = envRe.exec(envSpan)) !== null) {
    const key = em[1];
    const val = em[2];
    if (!WHITELIST.has(key)) return null;
    if (present.has(key)) return null; // duplicate key
    present.add(key);
    if (/[$`~]/.test(val)) return null;
    if (key === "AGENTS_CONFIG_DIR") {
      if (normLower(val) !== acdNorm) return null;
    } else if (key === "FINALIZE_SCRIPTS_DIR") {
      if (normLower(val) !== fsdNorm) return null;
    } else if (key === "MAIN_WORKTREE_PATH") {
      const vNorm = normalizeForCompare(normalizeCwd(val) || val);
      if (!vNorm || !rootNorm || vNorm !== rootNorm) return null;
    }
  }
  if (present.size !== entry.requiredEnv.length) return null;
  for (const k of entry.requiredEnv) {
    if (!present.has(k)) return null;
  }

  // Argument HARD gate: shape scan, count bound, per-position type validation.
  if (isUnsafeArgTail(argTail)) return null;
  const tokens = [];
  const argRe = /"([^"]*)"|(\S+)/g;
  let am;
  while ((am = argRe.exec(argTail)) !== null) {
    // Track quoted-vs-unquoted provenance: unquoted tokens are real shell word
    // boundaries and must be re-checked for metacharacters the tokenizer itself
    // treats as opaque (e.g. bare `|` splits into a pipeline at the shell level
    // even though this regex captures it as one token).
    if (am[1] !== undefined) {
      tokens.push({ value: am[1], quoted: true });
    } else {
      tokens.push({ value: am[2], quoted: false });
    }
  }
  if (tokens.length < entry.argCountMin || tokens.length > entry.argCountMax) return null;
  for (let i = 0; i < tokens.length; i++) {
    const spec = entry.argSpec[i];
    if (spec === undefined) continue; // beyond spec — optional, shape already checked
    const tok = tokens[i];
    // Unquoted tokens are real shell word boundaries: reject any metacharacter
    // the shell would treat specially (pipe/redirect/subshell/etc.), regardless
    // of argSpec — closes the gap universally rather than per-spec (CPR-8).
    if (!tok.quoted && /[|&;<>()$`]/.test(tok.value)) return null;
    if (spec === "id") continue;
    if (spec === "enum-g5") {
      if (!G5_DECISION_VALUES.includes(tok.value)) return null;
    } else if (spec === "path-plansdir") {
      if (!isUnderPlansDir(tok.value)) return null;
    } else {
      return null; // unknown spec → fail-closed
    }
  }

  return { scriptPath: normScript };
}

module.exports = {
  FINALIZE_OVERLAY_REGISTRY,
  G5_DECISION_VALUES,
  isUnsafeArgTail,
  matchFinalizeWorkerOverlay,
};

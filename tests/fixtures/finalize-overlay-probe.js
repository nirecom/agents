"use strict";
// tests/fixtures/finalize-overlay-probe.js
// CLI probe over the enforce-worktree argument-value guard for the #1630
// cross-validation work.
//
// #1673 splits the subject in two:
//   - the SHARED VALUE HELPERS (stripRelSuffix / isUnderPlansDir / hasControlChar
//     / UNSAFE_ARG_VALUE_RE / ID_VALUE_RE / REPO_SLUG_VALUE_RE / isSimpleArgValue)
//     live in hooks/enforce-worktree/arg-value-guard.js. The `strip` and
//     `plansdir` ops read them from there and keep working after the overlay is
//     retired.
//   - matchFinalizeWorkerOverlay and FINALIZE_OVERLAY_REGISTRY belong to
//     hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js,
//     which #1673 commit 5 DELETES together with the Bash-tool `eval` path it
//     guarded. The `match` / `mutmatch` / `matchextra` / `specshape` / `matchraw`
//     ops therefore print an explicit OVERLAY-RETIRED line once the module is
//     gone — never a silent pass.
//
// Usage:
//   node finalize-overlay-probe.js strip <absScriptPath> <relSuffix>
//   node finalize-overlay-probe.js match <command> <repoRoot>
//     (AGENTS_CONFIG_DIR from the environment supplies the acd argument)
//   node finalize-overlay-probe.js mutmatch <mutation> <command> <repoRoot>
//     mutation ∈ none | drop-derived | drop-payload
//
// `mutmatch` compiles a MUTATED copy of the overlay source in memory, under the
// original filename so its own `require(...)`s still resolve, and runs the same
// match. It never writes to the repo. Deleting one equality of the three-way
// cross-validation must make at least one documented mismatch case pass; if it
// does not, that equality is untested. When the mutation pattern is absent the
// probe prints NO-MUTATION-SITE — an explicit failure, never a silent skip.
//
// Prints exactly one line and always exits 0.

const fs = require("fs");
const path = require("path");
const Module = require("module");

const AGENTS_DIR = path.resolve(__dirname, "..", "..");
// Overlay module (retired by #1673 commit 5) — required lazily/softly.
const MODULE_PATH = path.join(
  AGENTS_DIR, "hooks", "enforce-worktree", "main-worktree-allows",
  "finalize-worker-overlay.js"
);
// Shared value helpers (#1673 commit 1) — the durable home.
const GUARD_PATH = path.join(
  AGENTS_DIR, "hooks", "enforce-worktree", "arg-value-guard.js"
);

const line1 = (s) => String(s).split("\n")[0];

let guard = null;
let guardErr = null;
try {
  guard = require(GUARD_PATH);
} catch (e) {
  guardErr = line1(e.message);
}

let mod = null;
let modErr = null;
try {
  mod = require(MODULE_PATH);
} catch (e) {
  modErr = line1(e.message);
}

// Value helpers resolve to arg-value-guard.js first; the overlay is only a
// fallback for the migration window in which it still re-exports them.
function helper(name) {
  if (guard && typeof guard[name] !== "undefined") return guard[name];
  if (mod && typeof mod[name] !== "undefined") return mod[name];
  return undefined;
}

// The overlay ops cannot be answered once the module is gone. Print a distinct
// marker rather than "null", so a retired capability can never read as a pass.
function requireOverlay() {
  if (mod) return true;
  console.log("OVERLAY-RETIRED: " + (modErr || "finalize-worker-overlay.js absent"));
  return false;
}

const op = process.argv[2] || "";
const a1 = process.argv[3] || "";
const a2 = process.argv[4] || "";
const a3 = process.argv[5] || "";

const fwd = (s) => String(s).replace(/\\/g, "/");

// Each mutation neutralises exactly ONE equality of
// `anchorAcd === derivedAcd && anchorAcd === payloadAcd`, in either polarity
// (`a === b` inside the conjunction, or `a !== b` in a fail-closed early
// return). Returns { src, hits }.
function applyMutation(src, which) {
  // The anchor may be spelled `anchorAcd` or reuse the existing `acdNorm`, and
  // the payload equality may stay inside the requiredEnv loop in its legacy
  // `normLower(val) !== acdNorm` form. All spellings of ONE equality are
  // neutralised together; the other equality is left untouched.
  const pairs = {
    "drop-derived": [["anchorAcd", "derivedAcd"], ["acdNorm", "derivedAcd"]],
    "drop-payload": [["anchorAcd", "payloadAcd"], ["acdNorm", "payloadAcd"]],
  };
  const sets = pairs[which];
  if (!sets) return { src, hits: -1 };
  let hits = 0;
  let out = src;
  for (const [x, y] of sets) {
    const eq = new RegExp("(?:" + x + "\\s*===\\s*" + y + "|" + y + "\\s*===\\s*" + x + ")", "g");
    const ne = new RegExp("(?:" + x + "\\s*!==\\s*" + y + "|" + y + "\\s*!==\\s*" + x + ")", "g");
    out = out.replace(eq, () => { hits += 1; return "true"; });
    out = out.replace(ne, () => { hits += 1; return "false"; });
  }
  if (which === "drop-payload") {
    const legacyNe = /(?:normLower\([A-Za-z0-9_.[\]]+\)\s*!==\s*acdNorm|acdNorm\s*!==\s*normLower\([A-Za-z0-9_.[\]]+\))/g;
    const legacyEq = /(?:normLower\([A-Za-z0-9_.[\]]+\)\s*===\s*acdNorm|acdNorm\s*===\s*normLower\([A-Za-z0-9_.[\]]+\))/g;
    out = out.replace(legacyNe, () => { hits += 1; return "false"; });
    out = out.replace(legacyEq, () => { hits += 1; return "true"; });
  }
  return { src: out, hits };
}

function loadMutant(which) {
  const src = fs.readFileSync(MODULE_PATH, "utf8");
  const { src: mutated, hits } = applyMutation(src, which);
  if (hits <= 0) return { mod: null, hits };
  const m = new Module(MODULE_PATH, null);
  m.filename = MODULE_PATH;
  m.paths = Module._nodeModulePaths(path.dirname(MODULE_PATH));
  m._compile(mutated, MODULE_PATH);
  return { mod: m.exports, hits };
}

// The run-loop-step payload shape, byte-identical to the suite's
// `build_loop_step` helper. Built here (not passed on argv) so that the ONLY
// thing that varies between the accepted and rejected rows is the token itself.
function buildLoopStep(acd, args) {
  const scripts = fwd(acd) + "/skills/issue-close-finalize/scripts";
  const quoted = args.map((a) => '"' + a + '"').join(" ");
  return 'eval "$(AGENTS_CONFIG_DIR="' + fwd(acd) + '" FINALIZE_SCRIPTS_DIR="' + scripts +
    '" node "' + scripts + '/run-loop-step.js" ' + quoted + ')"';
}

function showMatch(m, cmd, acd, repoRoot) {
  const r = m.matchFinalizeWorkerOverlay(cmd, acd, repoRoot);
  if (r === null || r === undefined) return "null";
  const p = r.scriptPath || r.script || r.path || r.rel || "";
  return p ? path.basename(fwd(p)) : JSON.stringify(r);
}

try {
  switch (op) {
    // stripRelSuffix(absPath, rel) -> the implied root, or null when the path
    // does not end with `rel` on a segment boundary.
    case "strip": {
      const stripRelSuffix = helper("stripRelSuffix");
      if (typeof stripRelSuffix !== "function") {
        console.log("ERROR: stripRelSuffix is not exported"
          + (guardErr ? " (arg-value-guard.js: " + guardErr + ")" : ""));
        break;
      }
      const r = stripRelSuffix(a1, a2);
      console.log(r === null || r === undefined ? "null" : fwd(r));
      break;
    }
    // matchFinalizeWorkerOverlay(cmd, acd, repoRoot) -> the matched registry
    // script's basename, or "null".
    case "match": {
      if (!requireOverlay()) break;
      if (typeof mod.matchFinalizeWorkerOverlay !== "function") {
        console.log("ERROR: matchFinalizeWorkerOverlay is not exported");
        break;
      }
      const acd = (process.env.AGENTS_CONFIG_DIR || "").trim();
      const r = mod.matchFinalizeWorkerOverlay(a1, acd, a2);
      if (r === null || r === undefined) { console.log("null"); break; }
      const p = r.scriptPath || r.script || r.path || r.rel || "";
      console.log(p ? path.basename(fwd(p)) : JSON.stringify(r));
      break;
    }
    // mutmatch <mutation> <command> <repoRoot>
    case "mutmatch": {
      if (!requireOverlay()) break;
      if (typeof mod.matchFinalizeWorkerOverlay !== "function") {
        console.log("ERROR: matchFinalizeWorkerOverlay is not exported");
        break;
      }
      const acd = (process.env.AGENTS_CONFIG_DIR || "").trim();
      if (a1 === "none") { console.log(showMatch(mod, a2, acd, a3)); break; }
      const { mod: mutant, hits } = loadMutant(a1);
      if (hits === -1) { console.log("ERROR: unknown mutation " + JSON.stringify(a1)); break; }
      if (!mutant) { console.log("NO-MUTATION-SITE"); break; }
      console.log(showMatch(mutant, a2, acd, a3));
      break;
    }
    // plansdir <token> <repoRoot> — is `token` acceptable as a `path-plansdir`
    // argument? Prefers the predicate itself when the module exports it; when it
    // does not (the case today), the token is driven through the only public
    // seam that consumes it — a run-loop-step payload identical in every other
    // respect — so the answer still comes from the real validation path.
    //
    // Prints "accepted" | "rejected".
    case "plansdir": {
      const isUnderPlansDir = helper("isUnderPlansDir");
      if (typeof isUnderPlansDir === "function") {
        console.log(isUnderPlansDir(a1) ? "accepted" : "rejected");
        break;
      }
      if (!requireOverlay()) break;
      if (typeof mod.matchFinalizeWorkerOverlay !== "function") {
        console.log("ERROR: matchFinalizeWorkerOverlay is not exported");
        break;
      }
      const acd = (process.env.AGENTS_CONFIG_DIR || "").trim();
      console.log(showMatch(mod, buildLoopStep(acd, [a1, "accept"]), acd, a2) === "null"
        ? "rejected" : "accepted");
      break;
    }
    // matchextra <extraToken> <repoRoot> — a token BEYOND the entry's argSpec.
    //
    // No shipped entry currently has argCountMax > argSpec.length, so the
    // `spec === undefined` branch is unreachable through the registry as
    // written. The bound is raised here on the exported registry object (which
    // callers hold by reference) for the duration of one call, and restored
    // immediately: this pins the BRANCH, so that widening any entry's count
    // bound later cannot quietly open an unvalidated argument slot.
    case "matchextra": {
      if (!requireOverlay()) break;
      if (typeof mod.matchFinalizeWorkerOverlay !== "function") {
        console.log("ERROR: matchFinalizeWorkerOverlay is not exported");
        break;
      }
      const reg = mod.FINALIZE_OVERLAY_REGISTRY;
      if (!Array.isArray(reg)) { console.log("ERROR: FINALIZE_OVERLAY_REGISTRY is not exported"); break; }
      const entry = reg.filter((e) => String(e.rel).indexOf("run-loop-step.js") !== -1)[0];
      if (!entry) { console.log("ERROR: no run-loop-step registry entry"); break; }
      const acd = (process.env.AGENTS_CONFIG_DIR || "").trim();
      const plans = (process.env.WORKFLOW_PLANS_DIR || "").trim();
      const saved = entry.argCountMax;
      entry.argCountMax = entry.argSpec.length + 1;
      let shown;
      try {
        shown = showMatch(mod, buildLoopStep(acd, [plans + "/state.json", "accept", a1]), acd, a2);
      } finally {
        entry.argCountMax = saved;
      }
      console.log(shown);
      break;
    }
    // specshape — structural registry invariant: every entry must declare a spec
    // for every argument position it is willing to accept. Prints "ok" or the
    // first offending entry.
    case "specshape": {
      if (!requireOverlay()) break;
      const reg = mod.FINALIZE_OVERLAY_REGISTRY;
      if (!Array.isArray(reg)) { console.log("ERROR: FINALIZE_OVERLAY_REGISTRY is not exported"); break; }
      let bad = "";
      for (const e of reg) {
        const specLen = Array.isArray(e.argSpec) ? e.argSpec.length : -1;
        if (specLen < e.argCountMax) {
          bad = path.basename(String(e.rel)) + ":spec=" + specLen + ",max=" + e.argCountMax;
          break;
        }
      }
      console.log(bad || "ok");
      break;
    }
    // Same call, raw JSON result — diagnostic only.
    case "matchraw": {
      if (!requireOverlay()) break;
      const acd = (process.env.AGENTS_CONFIG_DIR || "").trim();
      console.log(JSON.stringify({ acd, r: mod.matchFinalizeWorkerOverlay(a1, acd, a2) }));
      break;
    }
    default:
      console.log("ERROR: unknown op " + JSON.stringify(op));
  }
} catch (e) {
  console.log("ERROR: threw " + line1(e.message));
}

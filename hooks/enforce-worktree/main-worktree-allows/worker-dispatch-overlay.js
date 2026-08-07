"use strict";
// hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js
//
// Sole HARD gate for the single worker-dispatch entry point (#1643).
// Canonical form — the ONLY shape this overlay ever matches:
//
//     node "<AGENTS_CONFIG_DIR>/bin/worker-dispatch.js" <worker> <main-root> <payload-json>
//
// Trust split (CPR-SC): this overlay validates the Bash COMMAND STRING only.
// Payload FILE CONTENTS are validated by bin/worker-dispatch/capability.js on the
// dispatcher side — the file lives in the git-unmanaged plans dir and is untrusted
// here by construction.
//
// Three locks, each independently load-bearing:
//   Lock 1  the invoked script path must live at <acd>/bin/worker-dispatch.js,
//           where <acd> is the marker-validated config dir the caller resolved.
//   Lock 2  argv <main-root> must be the very repo the guard is judging.
//   Lock 3  argv <main-root> must be the MAIN worktree of a repo in this
//           session's trusted anchor set (getSessionRepoRoots()).
//
// Lock 2 alone is not enough: repoRoot is derived from the tool's caller-supplied
// cwd, so a command that moves cwd to another checkout would otherwise authorize
// worker operations against that repository. Lock 3 anchors the decision to the
// session instead of to the command (codex concern C2).
//
// Fail-closed everywhere: any parse failure, missing SSOT module, spawn error or
// unresolvable anchor returns null (= no allow), never a partial match.

const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeCwd } = require("../../lib/path-normalize");
const { normalizeForCompare } = require("../git-repo-detection");
const { getSessionRepoRoots } = require("../session-scope");
const {
  stripRelSuffix, isUnderPlansDir, hasControlChar, UNSAFE_ARG_VALUE_RE,
} = require("../arg-value-guard");

// Worker-name enum SSOT. Loaded defensively: a partial revert that removes the
// registry must degrade this overlay to BLOCK, not crash the whole hook.
let WORKER_NAMES = null;
try {
  ({ WORKER_NAMES } = require("../../lib/worker-dispatch-registry"));
} catch (_e) {
  WORKER_NAMES = null;
}

// The dispatcher's fixed location inside the agents checkout.
const DISPATCH_REL = "bin/worker-dispatch.js";

const GIT_TIMEOUT_MS = 2000;

function normLower(p) {
  return path.resolve(normalizeCwd(p) || p).toLowerCase();
}

/**
 * Split a single-line command into shell words, accepting only two token shapes:
 * a fully double-quoted word, or a bare word containing no quote character.
 * Anything else (mixed quoting like `a"b"c`, an unterminated quote, an env
 * assignment carrying a quoted value) returns null — the caller then blocks.
 *
 * Deliberately NOT a general shell tokenizer: every metacharacter is refused
 * downstream by UNSAFE_ARG_VALUE_RE, so the only strings that reach a verdict
 * are ones whose word split is unambiguous under any shell.
 */
function tokenizeSimple(cmd) {
  const toks = [];
  const n = cmd.length;
  let i = 0;
  while (i < n) {
    while (i < n && (cmd[i] === " " || cmd[i] === "\t")) i += 1;
    if (i >= n) break;
    if (cmd[i] === '"') {
      const end = cmd.indexOf('"', i + 1);
      if (end === -1) return null;
      const next = cmd[end + 1];
      if (next !== undefined && next !== " " && next !== "\t") return null;
      toks.push({ value: cmd.slice(i + 1, end), quoted: true });
      i = end + 1;
    } else {
      let j = i;
      while (j < n && cmd[j] !== " " && cmd[j] !== "\t") {
        if (cmd[j] === '"') return null;
        j += 1;
      }
      toks.push({ value: cmd.slice(i, j), quoted: false });
      i = j;
    }
  }
  return toks;
}

// Every token value must survive a second round of shell parsing unchanged.
// Whitespace is included in the reject set (it is part of UNSAFE_ARG_VALUE_RE),
// so a config dir / plans dir containing a space is refused here exactly as it
// already is by the finalize-worker overlay (CPR-ORTH) — the sanctioned layout has
// no such path.
function isSafeValue(v) {
  if (typeof v !== "string" || v === "") return false;
  if (hasControlChar(v)) return false;
  return !UNSAFE_ARG_VALUE_RE.test(v);
}

/**
 * The MAIN worktree of `root`, normalized for comparison. `git worktree list`
 * lists the main worktree first by definition, so the first record is the answer
 * regardless of which worktree `root` itself is.
 */
function mainWorktreeOf(root) {
  try {
    const r = spawnSync("git", ["-C", root, "worktree", "list", "--porcelain"], {
      encoding: "utf8", timeout: GIT_TIMEOUT_MS,
    });
    if (r.error || r.status !== 0) return null;
    for (const line of (r.stdout || "").split("\n")) {
      const m = line.match(/^worktree\s+(.+)$/);
      if (!m) continue;
      const raw = m[1].trim();
      if (!raw) return null;
      return normalizeForCompare(normalizeCwd(raw) || raw);
    }
    return null;
  } catch (_e) {
    return null;
  }
}

// Trusted anchor set for Lock 3: the MAIN worktree of every repo root this
// session is scoped to. Built from getSessionRepoRoots(), which reads the hook
// process's own location plus ENFORCE_WORKTREE_ADDITIONAL_REPOS — never the
// command under judgement.
function trustedMainWorktrees() {
  const out = new Set();
  let roots;
  try {
    roots = getSessionRepoRoots();
  } catch (_e) {
    return out;
  }
  for (const root of roots) {
    const main = mainWorktreeOf(root);
    if (main) out.add(main);
  }
  return out;
}

/**
 * HARD-validate a worker-dispatch invocation.
 *
 * @param {string} cmd       the raw Bash command string
 * @param {string} acd       marker-validated AGENTS_CONFIG_DIR (resolved by the caller)
 * @param {string} repoRoot  the repo root the guard is currently judging
 * @returns {{worker:string,mainRoot:string,payloadPath:string,scriptPath:string}|null}
 */
function matchWorkerDispatchOverlay(cmd, acd, repoRoot) {
  // (1) Input shape.
  if (!cmd || typeof cmd !== "string") return null;
  if (!acd || typeof acd !== "string") return null;
  if (!repoRoot || typeof repoRoot !== "string") return null;

  // (2) Single line only. A newline is a command separator, never argument text
  // in this form, so injection attempts die before any structural read.
  if (cmd.includes("\n") || cmd.includes("\r")) return null;
  if (hasControlChar(cmd)) return null;

  // (3) SSOT enum must be loadable; a missing registry is a BLOCK, not a bypass.
  if (!Array.isArray(WORKER_NAMES) || WORKER_NAMES.length === 0) return null;

  // (4) Word split.
  const toks = tokenizeSimple(cmd);
  if (toks === null) return null;

  // (5) Arity: exactly `node` + script + 3 positional arguments.
  if (toks.length !== 5) return null;

  // (6) Command word: bare `node`, no env prefix, no interpreter substitution.
  if (toks[0].quoted || toks[0].value !== "node") return null;

  // (7) Script path: a double-quoted, fully-resolved literal.
  if (!toks[1].quoted) return null;
  for (const t of toks) {
    if (!isSafeValue(t.value)) return null;
  }

  let normScript;
  try {
    normScript = normLower(toks[1].value);
  } catch (_e) {
    return null;
  }

  // (8) Lock 1 — identity. The root implied by the script path (segment-wise
  // suffix strip, so `<acd>/bin/worker-dispatch.js.bak` and `<acd>/xbin/...` do
  // not match) must BE the anchor the caller resolved.
  const derivedAcd = stripRelSuffix(normScript, DISPATCH_REL);
  if (!derivedAcd) return null;
  let anchorAcd;
  try {
    anchorAcd = normLower(acd);
  } catch (_e) {
    return null;
  }
  if (!anchorAcd || derivedAcd !== anchorAcd) return null;

  // (9) Worker name: exact, case-sensitive enum member.
  const worker = toks[2].value;
  if (!WORKER_NAMES.includes(worker)) return null;

  // (10) Lock 2 — argv <main-root> is the repo under judgement.
  const argRoot = normalizeForCompare(normalizeCwd(toks[3].value) || toks[3].value);
  const judgedRoot = normalizeForCompare(normalizeCwd(repoRoot) || repoRoot);
  if (!argRoot || !judgedRoot) return null;
  if (argRoot !== judgedRoot) return null;

  // (11) Lock 3 — argv <main-root> is a MAIN worktree of a session-anchored repo.
  // This is what makes Lock 2 meaningful: repoRoot follows the caller's cwd, the
  // trusted set does not.
  const trusted = trustedMainWorktrees();
  if (trusted.size === 0) return null;
  if (!trusted.has(argRoot)) return null;

  // (12) Payload path must live under the workflow plans dir (separator-boundary
  // containment, so sibling-prefix and ..-escape lookalikes are refused).
  const payload = toks[4].value;
  if (!isUnderPlansDir(payload)) return null;

  return { worker, mainRoot: argRoot, payloadPath: payload, scriptPath: normScript };
}

module.exports = { matchWorkerDispatchOverlay, DISPATCH_REL };

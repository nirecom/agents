"use strict";
// hooks/enforce-worktree/main-worktree-allows/worker-dispatch-overlay.js — sole HARD gate for
// the single worker-dispatch entry point (#1643). The ONLY shape this overlay matches:
//     node "<script checkout root>/bin/worker-dispatch.js" <worker> <target-main-root> <payload-json>
// It validates the COMMAND STRING only; payload CONTENTS are the dispatcher's job
// (bin/worker-dispatch/capability.js). Three independently load-bearing locks:
//   Lock 1  the script path is bin/worker-dispatch.js of the checkout this hook was loaded from.
//   Lock 2  argv <target-main-root> is the very repo the guard is judging.
//   Lock 3  argv <target-main-root> is the MAIN worktree of a session-anchored repo (codex C2),
//           since repoRoot follows the caller's cwd. Fail-closed: any failure returns null.

const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeCwd } = require("../../lib/path-normalize");
const { normalizeForCompare } = require("../git-repo-detection");
const { getSessionRepoRoots } = require("../session-scope");
const {
  stripRelSuffix, isUnderPlansDir, hasControlChar, UNSAFE_ARG_VALUE_RE,
} = require("../arg-value-guard");
const { listStateRoots } = require("../../workflow-state/state-io/state-root");
const { resolveScriptCheckoutRoot } = require("../../lib/script-checkout-root");

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
const CONTROL_SEG_RE = /^[a-z0-9_-]+\.control$/i;
const PAYLOAD_NAME_RE = /^worker-[a-z0-9]+(?:-[a-z0-9]+)*\.json$/i;

function normLower(p) {
  return path.resolve(normalizeCwd(p) || p).toLowerCase();
}

/**
 * Split a single-line command into shell words, accepting only a fully double-quoted
 * word or a bare word with no quote character; anything else returns null (block).
 * Not a general tokenizer: UNSAFE_ARG_VALUE_RE refuses every metacharacter downstream.
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
// Whitespace is in the reject set, so a config / plans dir containing a space is
// refused exactly as the finalize-worker overlay refuses it (CPR-ORTH).
function isSafeValue(v) {
  if (typeof v !== "string" || v === "") return false;
  if (hasControlChar(v)) return false;
  return !UNSAFE_ARG_VALUE_RE.test(v);
}

// True when `token` is <root>/<sid>.control/worker-*.json for some state root (#2511) —
// exactly two segments below that root after resolution, so `..` escapes and nesting are refused.
function isControlDirPayload(token) {
  try {
    if (!isSafeValue(token)) return false;
    const normTok = normalizeForCompare(normalizeCwd(token) || token);
    if (!normTok) return false;
    return listStateRoots().some((wf) => {
      const normWf = wf ? normalizeForCompare(normalizeCwd(wf) || wf) : null;
      if (!normWf || !normTok.startsWith(normWf + path.sep)) return false;
      const segs = normTok.slice(normWf.length + 1).split(/[\\/]/);
      return segs.length === 2 && CONTROL_SEG_RE.test(segs[0]) && PAYLOAD_NAME_RE.test(segs[1]);
    });
  } catch (_e) {
    return false;
  }
}

/**
 * The MAIN worktree of `root`, normalized for comparison. `git worktree list`
 * lists the main worktree first by definition, whichever worktree `root` is.
 */
function targetMainRootOf(root) {
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
function trustedTargetMainRoots() {
  const out = new Set();
  let roots;
  try {
    roots = getSessionRepoRoots();
  } catch (_e) {
    return out;
  }
  for (const root of roots) {
    const main = targetMainRootOf(root);
    if (main) out.add(main);
  }
  return out;
}

/**
 * HARD-validate a worker-dispatch invocation.
 *
 * @param {string} cmd       the raw Bash command string
 * @param {string} repoRoot  the repo root the guard is currently judging
 * @returns {{worker:string,targetMainRoot:string,payloadPath:string,scriptPath:string}|null}
 */
function matchWorkerDispatchOverlay(cmd, repoRoot) {
  // (1) Input shape.
  if (!cmd || typeof cmd !== "string") return null;
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
  // suffix strip, so `<root>/bin/worker-dispatch.js.bak` and `<root>/xbin/...` do
  // not match) must BE the checkout this hook was loaded from.
  const derivedRoot = stripRelSuffix(normScript, DISPATCH_REL);
  if (!derivedRoot) return null;
  let ownRoot;
  try {
    const SCRIPT_CHECKOUT_ROOT = resolveScriptCheckoutRoot();
    if (!SCRIPT_CHECKOUT_ROOT) return null;
    ownRoot = normLower(SCRIPT_CHECKOUT_ROOT);
  } catch (_e) {
    return null;
  }
  if (!ownRoot || derivedRoot !== ownRoot) return null;

  // (9) Worker name: exact, case-sensitive enum member.
  const worker = toks[2].value;
  if (!WORKER_NAMES.includes(worker)) return null;

  // (10) Lock 2 — argv <target-main-root> is the repo under judgement.
  const argRoot = normalizeForCompare(normalizeCwd(toks[3].value) || toks[3].value);
  const judgedRoot = normalizeForCompare(normalizeCwd(repoRoot) || repoRoot);
  if (!argRoot || !judgedRoot) return null;
  if (argRoot !== judgedRoot) return null;

  // (11) Lock 3 — argv <target-main-root> is a MAIN worktree of a session-anchored repo.
  // This is what makes Lock 2 meaningful: repoRoot follows the caller's cwd, the
  // trusted set does not.
  const trusted = trustedTargetMainRoots();
  if (trusted.size === 0) return null;
  if (!trusted.has(argRoot)) return null;

  // (12) Payload path: a control-dir worker payload. A read argument, not a write target.
  const payload = toks[4].value;
  if (!isControlDirPayload(payload) && !isLegacyPlansPayload(payload)) return null;

  return { worker, targetMainRoot: argRoot, payloadPath: payload, scriptPath: normScript };
}

// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
// deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
function isLegacyPlansPayload(token) {
  return isUnderPlansDir(token);
}
// --- END temporary: plans-dir control files -> workflow control dir migration ---

module.exports = { matchWorkerDispatchOverlay, DISPATCH_REL };

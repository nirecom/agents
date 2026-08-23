"use strict";

// Proof, never assumption. Every path out of this module that is not a POSITIVE
// answer from gh — a non-zero exit, a timeout, an unparsable body, a thrown
// spawn, an exhausted budget — returns "not proven", which the caller turns into
// an ask. There are exactly two rungs: the authenticated login IS the owner, or
// the authenticated identity holds admin on the repository. Anything else the
// API might imply (push rights, org membership) is not ownership.
const { spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { probeTimeout, chargeBudget } = require("./budget");
const { isValidOwner, isValidRepo, GITHUB_HOST } = require("../lib/parse-remote-url");
const { AUTH_FP_VARS } = require("./auth-context");
const { readJsonState, writeJsonState } = require("./gh-env-state");

const LOGIN_PROBE_CAP_MS = 2500;
const REPO_PROBE_CAP_MS = 2500;
const GIT_PROBE_CAP_MS = 1500;
const LOGIN_TTL_MS = 30 * 60 * 1000;

// Resolve a bare command name against PATH. Node execs the file directly rather
// than through a shell, so a name that the shell would have found is otherwise
// simply "not found" — and a not-found probe reads as "ownership not proven",
// which is a silent loss of the proof path rather than a visible failure.
function resolveOnPath(name) {
  if (typeof name !== "string" || name === "" || name.indexOf("/") !== -1 || name.indexOf("\\") !== -1) return null;
  const dirs = String(process.env.PATH || "").split(path.delimiter).filter((d) => d !== "");
  const exts = [""].concat(String(process.env.PATHEXT || "").split(";").filter((e) => e !== ""));
  for (const dir of dirs) {
    for (const ext of exts) {
      const candidate = path.join(dir, name + ext);
      try {
        if (fs.statSync(candidate).isFile()) return candidate;
      } catch (_e) { /* not here */ }
    }
  }
  return null;
}

// A `#!` script cannot be exec'd by Node on every platform (Git Bash notably
// cannot), so the interpreter is read from the script's own first line — the same
// treatment hooks/lib/mechanism-failure.js gives its CLI.
function shebangInterpreter(file) {
  let head = "";
  try {
    const fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(128);
    const n = fs.readSync(fd, buf, 0, 128, 0);
    fs.closeSync(fd);
    head = buf.slice(0, n).toString("utf8").split("\n")[0];
  } catch (_e) {
    return null;
  }
  if (head.slice(0, 2) !== "#!") return null;
  if (/node/.test(head)) return process.execPath;
  if (/\b(bash|sh|zsh)\b/.test(head)) return "bash";
  return null;
}

function execArgv(argv) {
  const resolved = resolveOnPath(argv[0]);
  if (!resolved) return argv;
  const interp = shebangInterpreter(resolved);
  return interp ? [interp, resolved].concat(argv.slice(1)) : [resolved].concat(argv.slice(1));
}

// The probe must authenticate against the SAME forge the decision is about. An
// ambient GH_HOST naming an enterprise instance would otherwise have gh answer
// "who am I" for a forge the write never targets, and that answer would be read
// as proof about github.com.
function probeEnv(ctx) {
  const host = ctx && typeof ctx.host === "string" && ctx.host !== "" ? ctx.host : GITHUB_HOST;
  return Object.assign({}, process.env, { GH_HOST: host });
}

// One spawn, bounded by whatever is left of the invocation's budget. `spawn` is
// injectable so the proof path can be exercised without a real gh on PATH.
function runProbe(argv, budget, capMs, options, ctx) {
  const timeout = probeTimeout(budget, capMs);
  if (timeout === null) return null;
  const injected = budget && typeof budget.spawn === "function";
  const spawn = injected ? budget.spawn : spawnSync;
  const started = Date.now();
  try {
    const opts = Object.assign(
      { encoding: "utf8", timeout, windowsHide: true, stdio: ["ignore", "pipe", "pipe"], env: probeEnv(ctx) },
      options || {}
    );
    const real = injected ? argv : execArgv(argv);
    const res = spawn(real[0], real.slice(1), opts);
    chargeBudget(budget, Date.now() - started);
    if (!res || res.error) return null;
    return {
      status: typeof res.status === "number" ? res.status : 1,
      stdout: typeof res.stdout === "string" ? res.stdout : "",
    };
  } catch (_e) {
    chargeBudget(budget, Date.now() - started);
    return null;
  }
}

function normalizeTarget(target) {
  let owner = null;
  let repo = null;
  if (typeof target === "string") {
    const slash = target.indexOf("/");
    if (slash > 0) { owner = target.slice(0, slash); repo = target.slice(slash + 1); }
  } else if (target && typeof target === "object") {
    owner = target.owner;
    repo = target.repo;
  }
  if (!isValidOwner(owner) || !isValidRepo(repo)) return null;
  return { owner, repo };
}

// Classify one raw `gh api repos/OWNER/REPO` response. A body that is not a JSON
// object is not a repository — an array root in particular is what an error
// envelope or a paginated endpoint returns, and reading fields off it would
// silently produce `admin: undefined`.
function classifyRepoFacts(res) {
  if (!res || (res.status !== 0 && res.status !== 200)) return null;
  let parsed = null;
  try {
    parsed = JSON.parse(res.stdout);
  } catch (_e) {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const perms = parsed.permissions;
  const parent = parsed.parent;
  // `fork` is TRI-state on purpose. Coercing a missing or non-boolean field to
  // `false` turns "the response never said" into "this is not a fork", which is
  // exactly the answer that lets an issue land in an upstream repository without
  // a prompt. Unknown stays unknown; the caller decides what to do about it.
  const forkField = parsed.fork;
  return {
    admin: !!(perms && typeof perms === "object" && perms.admin === true),
    fork: forkField === true ? true : (forkField === false ? false : null),
    parent: parent && typeof parent === "object" && typeof parent.full_name === "string" ? parent.full_name : null,
  };
}

function memoOf(budget, slot) {
  if (!budget || typeof budget !== "object") return null;
  if (!budget[slot]) budget[slot] = {};
  return budget[slot];
}

function probeRepoFacts(target, budget, ctx) {
  const t = normalizeTarget(target);
  if (!t) return null;
  const key = t.owner + "/" + t.repo;
  const memo = memoOf(budget, "_repoFactsMemo");
  if (memo && Object.prototype.hasOwnProperty.call(memo, key)) return memo[key];
  const res = runProbe(["gh", "api", "repos/" + t.owner + "/" + t.repo], budget, REPO_PROBE_CAP_MS, null, ctx);
  const facts = classifyRepoFacts(res);
  if (memo) memo[key] = facts;
  return facts;
}

// Dual signature by design: repoFacts({status, stdout}) classifies a response
// the caller already has, repoFacts(target, budget) goes and gets one.
function repoFacts(a, b, ctx) {
  if (a && typeof a === "object" && !Array.isArray(a) && (typeof a.status === "number" || typeof a.stdout === "string")) {
    return classifyRepoFacts(a);
  }
  return probeRepoFacts(a, b, ctx);
}

function tokenDigest(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

// A digest, not the values: a token reaches this only as a one-way hash, so the
// state file can say "the same credential as last time" without ever holding
// the credential. Fingerprinting mere PRESENCE would let a swap from one token
// to another inherit the previous token's proof. GH_CONFIG_DIR and GH_HOST
// select a profile and a forge rather than carrying a secret.
function authFingerprint() {
  const parts = AUTH_FP_VARS.map((v) => (process.env[v] ? tokenDigest(process.env[v]) : "0"));
  parts.push(process.env.GH_CONFIG_DIR || "");
  parts.push((process.env.GH_HOST || "").toLowerCase());
  return crypto.createHash("sha256").update(parts.join("\u0000")).digest("hex").slice(0, 32);
}

function cachedLogin(ctx) {
  if (!ctx || typeof ctx.sid !== "string") return null;
  const state = readJsonState(ctx.sid, "gh-login");
  if (!state) return null;
  const cachedAt = typeof state.cachedAt === "number" ? state.cachedAt : 0;
  if (Date.now() - cachedAt >= LOGIN_TTL_MS) return null;
  if (state.authFp !== authFingerprint()) return null;
  if (state.host !== (ctx.host || GITHUB_HOST)) return null;
  return isValidOwner(state.login) ? state.login : null;
}

// Only a login that actually PROVED something is remembered. Caching a login
// that failed to prove the last target would make the next, different target
// inherit a stale negative — see C6-3d/C6-3e.
function cacheLogin(ctx, login) {
  if (!ctx || typeof ctx.sid !== "string" || !isValidOwner(login)) return;
  writeJsonState(ctx.sid, "gh-login", {
    login,
    host: ctx.host || GITHUB_HOST,
    authFp: authFingerprint(),
    cachedAt: Date.now(),
  });
}

// A POSITIVE capability answer is remembered per target, on the same terms as
// the login: same session, same auth fingerprint, same host, same TTL. Only the
// positive is stored — a negative must be re-asked, because access can be granted
// between two commands and a cached "no" would outlive the grant.
function provenState(ctx) {
  if (!ctx || typeof ctx.sid !== "string") return null;
  const state = readJsonState(ctx.sid, "gh-login");
  if (!state) return null;
  if (state.authFp !== authFingerprint()) return null;
  if (state.host !== (ctx.host || GITHUB_HOST)) return null;
  return state;
}

function cachedProven(ctx, key) {
  const state = provenState(ctx);
  if (!state || !state.proven || typeof state.proven !== "object") return false;
  const at = state.proven[key];
  return typeof at === "number" && Date.now() - at < LOGIN_TTL_MS;
}

function cacheProven(ctx, key) {
  if (!ctx || typeof ctx.sid !== "string") return;
  const existing = provenState(ctx) || {};
  const proven = existing.proven && typeof existing.proven === "object" ? existing.proven : {};
  proven[key] = Date.now();
  writeJsonState(ctx.sid, "gh-login", Object.assign({}, existing, {
    host: ctx.host || GITHUB_HOST,
    authFp: authFingerprint(),
    proven,
  }));
}

// `gh api user --jq .login` yields a bare login. It is validated as a login and
// never JSON-parsed: a raw JSON body reaching here means the flag did not take
// effect, and guessing a field out of it would be reading an unexpected shape.
function ghLogin(budget, ctx) {
  const memo = memoOf(budget, "_loginMemo");
  if (memo && Object.prototype.hasOwnProperty.call(memo, "login")) return memo.login;
  const cached = cachedLogin(ctx);
  if (cached) {
    if (memo) memo.login = cached;
    return cached;
  }
  const res = runProbe(["gh", "api", "user", "--jq", ".login"], budget, LOGIN_PROBE_CAP_MS, null, ctx);
  let login = null;
  if (res && (res.status === 0 || res.status === 200)) {
    const trimmed = res.stdout.trim();
    if (isValidOwner(trimmed)) login = trimmed;
  }
  if (memo) memo.login = login;
  return login;
}

function proveOwned(target, budget, ctx) {
  const t = normalizeTarget(target);
  if (!t) return false;
  const login = ghLogin(budget, ctx);
  if (login && login.toLowerCase() === t.owner.toLowerCase()) {
    cacheLogin(ctx, login);
    return true;
  }
  const key = (t.owner + "/" + t.repo).toLowerCase();
  if (cachedProven(ctx, key)) return true;
  const facts = probeRepoFacts(t, budget, ctx);
  if (!(facts && facts.admin === true)) return false;
  cacheProven(ctx, key);
  return true;
}

module.exports = {
  proveOwned,
  repoFacts,
  ghLogin,
  runProbe,
  authFingerprint,
  normalizeTarget,
  GIT_PROBE_CAP_MS,
};

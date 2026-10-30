"use strict";
// tests/lib/command-guard/resolve-target.js — where a git write lands, and whether it may (#2590).
// The repo a write touches is asked from the real git with the caller's own globals and
// environment, so -C chains, --git-dir, GIT_DIR, GIT_WORK_TREE, core.worktree and linked
// worktrees resolve exactly as the write itself would. Verbs that name a path of their own
// (init, clone, worktree, archive, bundle, config --file / --global, push to a local remote)
// add that path. Every target must sit inside one of the allowed roots after realpath.
// Remote URLs are judged after git's own insteadOf / pushInsteadOf rewriting (remote-urls.js).

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { operands } = require("./classify");
const { remoteUrls, rawUrlTargets, configGlobals } = require("./remote-urls");

const IS_WIN = process.platform === "win32";

// Git Bash hands over /c/... paths that fs.* cannot open on Windows.
function toNative(p) {
  if (!IS_WIN) return p;
  const m = /^\/([A-Za-z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

// realish(p) — realpath of p, through its nearest existing ancestor when p does not exist yet;
// forward slashes on Windows.
function realish(p, base) {
  let cur = path.resolve(base || process.cwd(), toNative(p));
  const tail = [];
  for (;;) {
    try {
      cur = path.join(fs.realpathSync.native(cur), ...tail);
      break;
    } catch (_) {
      const up = path.dirname(cur);
      if (up === cur) {
        cur = path.join(cur, ...tail);
        break;
      }
      tail.unshift(path.basename(cur));
      cur = up;
    }
  }
  return IS_WIN ? cur.replace(/\\/g, "/") : cur;
}

function isUnder(p, roots) {
  const fold = (s) => (IS_WIN ? s.toLowerCase() : s).replace(/\/+$/, "");
  const fp = fold(p);
  return roots.some((r) => {
    const fr = fold(r);
    return fr !== "" && (fp === fr || fp.startsWith(`${fr}/`));
  });
}

// A network URL by git's own rule: scheme://, <transport>::, or a colon before the first slash
// that is not a drive letter (user@host:path, host:path). file:// is local.
function isNetworkUrl(s) {
  if (typeof s !== "string" || s === "") return false;
  if (/^file:\/\//i.test(s)) return false;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(s) || /^[A-Za-z][A-Za-z0-9+.-]*::/.test(s)) return true;
  const colon = s.indexOf(":");
  if (colon <= 0) return false;
  if (colon === 1 && /^[A-Za-z]$/.test(s[0])) return false;
  const slash = s.search(/[/\\]/);
  return slash < 0 || colon < slash;
}

function localUrlPath(s) {
  return /^file:\/\//i.test(s) ? s.replace(/^file:\/\//i, "").replace(/^\/([A-Za-z]:)/, "$1") : s;
}

const PUSH_FETCH_VALUE_OPTS = ["--repo", "--receive-pack", "--exec", "-o", "--push-option", "--upload-pack", "--depth",
  "--deepen", "--shallow-since", "--shallow-exclude", "--negotiation-tip", "-j", "--jobs", "--refmap", "--server-option",
  "--filter", "--sort"];
const CLONE_VALUE_OPTS = ["-o", "--origin", "-b", "--branch", "-u", "--upload-pack", "--reference", "--reference-if-able",
  "--separate-git-dir", "--depth", "--shallow-since", "--shallow-exclude", "-c", "--config", "--template", "-j", "--jobs",
  "--filter", "--server-option", "--bundle-uri", "--ref-format"];
const INIT_VALUE_OPTS = ["--template", "--separate-git-dir", "-b", "--initial-branch", "--object-format", "--ref-format"];

function optValue(rest, ...names) {
  let v = null;
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--") break;
    for (const n of names) {
      if (a === n && i + 1 < rest.length) v = rest[i + 1];
      else if (n.startsWith("--") && a.startsWith(`${n}=`)) v = a.slice(n.length + 1);
    }
  }
  return v;
}

function makeGit(realgit, globals) {
  return (args) => {
    const r = spawnSync(realgit, [...globals, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    const out = String(r.stdout || "");
    return { status: r.status, out, lines: out.split(/\r?\n/).filter((l) => l !== "") };
  };
}

// networkCheck(ctx) — the URL a command would reach over the network after git's URL rewriting,
// or null. ctx.remoteUrls keeps the rewritten push / fetch URLs for checkWrite. A network URL that
// ctx.trustedUrl(url, pre, fresh) accepts (the declared ssh stub, ssh-stub.js) is not one; fresh
// marks a URL fetched into a new repo, where the current repo's own config does not apply.
function networkCheck(ctx) {
  const { verb, rest, git } = ctx;
  const reaches = (u, pre, fresh) => isNetworkUrl(u) && !(ctx.trustedUrl && ctx.trustedUrl(u, pre, fresh));
  const fetched = (url, pre) => (url ? rawUrlTargets(git, url, false, pre).find((u) => reaches(u, pre, true)) || null : null);
  if (["push", "fetch", "pull", "ls-remote"].includes(verb)) {
    const repo = optValue(rest, "--repo") || operands(rest, PUSH_FETCH_VALUE_OPTS)[0] || null;
    const urls = remoteUrls(git, repo, verb === "push");
    ctx.remoteUrls = urls;
    return urls.find((u) => reaches(u, [], false)) || null;
  }
  if (verb === "clone") return fetched(operands(rest, CLONE_VALUE_OPTS)[0] || null, configGlobals(rest));
  if (verb === "submodule") {
    const ops = operands(rest, ["-b", "--branch", "--name", "--reference", "--depth", "--jobs", "-j"]);
    if (ops[0] === "add") return fetched(ops[1] || null, []);
    if (ops[0] === "update" || ops[0] === "init" || ops[0] === "sync") {
      const top = git(["rev-parse", "--show-toplevel"]).lines[0];
      const urls = git(["config", "--get-regexp", "^submodule\\..*\\.url$"]).lines;
      if (top) urls.push(...git(["config", "-f", `${top}/.gitmodules`, "--get-regexp", "^submodule\\..*\\.url$"]).lines);
      for (const u of urls.map((l) => l.replace(/^\S+\s+/, ""))) {
        const hit = fetched(u, []);
        if (hit) return hit;
      }
    }
  }
  return null;
}

function globalConfigFiles(env, cwd) {
  if (env.GIT_CONFIG_GLOBAL) return [env.GIT_CONFIG_GLOBAL];
  const home = env.HOME || env.USERPROFILE || cwd;
  const files = [path.join(toNative(home), ".gitconfig")];
  const xdg = path.join(env.XDG_CONFIG_HOME ? toNative(env.XDG_CONFIG_HOME) : path.join(toNative(home), ".config"), "git", "config");
  if (fs.existsSync(xdg)) files.push(xdg);
  return files;
}

// Paths the verb writes besides its repo; repo:false when the repo itself is not written.
function verbPaths(ctx) {
  const { verb, rest, cwd, env } = ctx;
  const ops = (opts) => operands(rest, opts);
  switch (verb) {
    case "init": {
      const dest = ops(INIT_VALUE_OPTS)[0];
      const paths = [dest || ctx.gitDir || env.GIT_DIR || cwd];
      const sep = optValue(rest, "--separate-git-dir");
      if (sep) paths.push(sep);
      return { repo: false, paths };
    }
    case "clone": {
      const o = ops(CLONE_VALUE_OPTS);
      const src = (o[0] || "").replace(/[/\\]+$/, "");
      const dest = o[1] || path.basename(src).replace(/\.git$/, "") || ".";
      const paths = [dest];
      const sep = optValue(rest, "--separate-git-dir");
      if (sep) paths.push(sep);
      return { repo: false, paths };
    }
    case "worktree": {
      const o = ops(["-b", "-B", "--reason", "--orphan"]);
      if (o[0] === "add") return { repo: true, paths: o.slice(1, 2) };
      if (o[0] === "move") return { repo: true, paths: o.slice(1, 3) };
      if (["remove", "repair", "lock", "unlock"].includes(o[0])) return { repo: true, paths: o.slice(1) };
      return { repo: true, paths: [] };
    }
    case "archive": {
      const out = optValue(rest, "-o", "--output");
      return { repo: true, paths: out ? [out] : [] };
    }
    case "format-patch": {
      const out = optValue(rest, "-o", "--output-directory");
      return { repo: true, paths: [out || cwd] };
    }
    case "bundle": {
      const o = ops([]);
      return { repo: true, paths: o[0] === "create" && o[1] ? [o[1]] : [] };
    }
    case "config": {
      if (rest.includes("--system")) return { reject: "config --system" };
      const file = optValue(rest, "-f", "--file");
      if (file) return { repo: false, paths: [file] };
      if (rest.includes("--global")) return { repo: false, paths: globalConfigFiles(env, cwd) };
      // With no scope option git config writes the file GIT_CONFIG names.
      if (env.GIT_CONFIG && !rest.includes("--local") && !rest.includes("--worktree")) return { repo: false, paths: [env.GIT_CONFIG] };
      return { repo: true, paths: [] };
    }
    default: {
      const out = optValue(rest, "--output", "--output-directory");
      if (out) return { repo: false, paths: [out] };
      return { repo: true, paths: [] };
    }
  }
}

// repoTargets(ctx) — git-dir, common dir and work tree of the repo the command runs in, or the
// effective cwd when there is none. A bare repo fails --show-toplevel; the lines before it count.
function repoTargets(ctx) {
  const r = ctx.git(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--is-bare-repository", "--show-toplevel"]);
  const out = r.lines.filter((l) => l !== "true" && l !== "false");
  const targets = out.length > 0 ? out : [ctx.cwd];
  for (const name of ["GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"]) {
    if (ctx.env[name]) targets.push(ctx.env[name]);
  }
  return targets;
}

// checkWrite(ctx) — { reject, target } for a git write: reject is the reason or null.
function checkWrite(ctx) {
  const vp = verbPaths(ctx);
  if (vp.reject) return { reject: vp.reject, target: "system config" };
  const targets = vp.paths.slice();
  if (vp.repo) targets.push(...repoTargets(ctx));
  if (ctx.verb === "push") {
    for (const u of ctx.remoteUrls || []) if (!isNetworkUrl(u)) targets.push(localUrlPath(u));
  }
  for (const t of targets) {
    const real = realish(t, ctx.cwd);
    if (!isUnder(real, ctx.allowed)) return { reject: "write outside the run root", target: real };
  }
  return { reject: null, target: null };
}

// effectiveCwd(cDirs) — the cwd after the -C chain; `-C ""` leaves it unchanged.
function effectiveCwd(cDirs) {
  return cDirs.reduce((cwd, d) => (d === "" ? cwd : path.resolve(cwd, toNative(d))), process.cwd());
}

module.exports = { toNative, realish, isUnder, isNetworkUrl, makeGit, networkCheck, checkWrite, effectiveCwd };

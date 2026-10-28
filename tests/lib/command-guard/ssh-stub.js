"use strict";
// tests/lib/command-guard/ssh-stub.js — the one ssh transport the command guard lets through (#2768).
// guard.conf `sshstub=` declares tests/lib/git-ssh-stub.sh, which serves a local bare repo. An ssh
// URL passes only when the ssh command git would run starts that very file: GIT_SSH_COMMAND, else
// core.sshCommand, else GIT_SSH (git's connect.c order). The command must be `<stub> [args]` or
// `sh|bash <stub> [args]` in plain words; any other word, expansion or shell syntax is refused.

const fs = require("fs");
const path = require("path");
const { toNative } = require("./resolve-target");

const IS_WIN = process.platform === "win32";
const SSH_SCHEMES = /^(ssh|git\+ssh|ssh\+git):\/\//;
const SHELLS = ["sh", "bash", "/bin/sh", "/bin/bash", "/usr/bin/sh", "/usr/bin/bash"];
const BARE = /[A-Za-z0-9_./:@%+,=-]/;

// isSshUrl(url) — a URL git connects to through the ssh command: an ssh scheme or the scp-like
// user@host:path form. Other schemes and <transport>:: helpers are never ssh here.
function isSshUrl(url) {
  if (typeof url !== "string" || url === "") return false;
  if (SSH_SCHEMES.test(url)) return true;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(url) || url.includes("::")) return false;
  const colon = url.indexOf(":");
  if (colon <= 0 || (colon === 1 && /^[A-Za-z]$/.test(url[0]))) return false;
  const slash = url.search(/[/\\]/);
  return slash < 0 || colon < slash;
}

// shellWords(cmd) — the words sh would split cmd into, or null when anything in it could expand,
// redirect, chain or comment: only plain characters, '...' and "..." without $ ` \ ! survive.
function shellWords(cmd) {
  const words = [];
  let cur = null;
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (c === " " || c === "\t") {
      if (cur !== null) words.push(cur);
      cur = null;
    } else if (c === "'" || c === '"') {
      const end = cmd.indexOf(c, i + 1);
      if (end < 0) return null;
      const body = cmd.slice(i + 1, end);
      if (c === '"' && /[$`\\!]/.test(body)) return null;
      cur = (cur || "") + body;
      i = end;
    } else if (BARE.test(c)) {
      cur = (cur || "") + c;
    } else {
      return null;
    }
  }
  if (cur !== null) words.push(cur);
  return words;
}

// canon(p) — the real absolute path of an existing file, or null; case-folded on Windows.
function canon(p) {
  const n = toNative(String(p || ""));
  if (n === "" || !path.isAbsolute(n)) return null;
  try {
    const real = fs.realpathSync.native(n).replace(/\\/g, "/");
    return IS_WIN ? real.toLowerCase() : real;
  } catch {
    return null;
  }
}

// sshCommand(env, git, pre, fresh) — { shell, cmd } git would run for an ssh URL, or null for the
// plain `ssh` or any doubt. fresh: a new repo (clone) never sees the current repo's local config.
function sshCommand(env, git, pre, fresh) {
  if (env.GIT_SSH_COMMAND !== undefined) return { shell: true, cmd: env.GIT_SSH_COMMAND };
  const r = git([...pre, "config", "--show-scope", "--get", "core.sshCommand"]);
  if (r.status === 0) {
    const line = r.out.replace(/\r?\n$/, "");
    const tab = line.indexOf("\t");
    const scope = tab < 0 ? "" : line.slice(0, tab);
    if (tab < 0 || (fresh && (scope === "local" || scope === "worktree"))) return null;
    return { shell: true, cmd: line.slice(tab + 1) };
  }
  if (r.status !== 1) return null;
  return env.GIT_SSH !== undefined && env.GIT_SSH !== "" ? { shell: false, cmd: env.GIT_SSH } : null;
}

// runsStub(command, stub) — the command starts the declared stub directly.
function runsStub(command, stub) {
  if (!command || !stub) return false;
  const words = command.shell ? shellWords(command.cmd) : [command.cmd];
  if (!words || words.length === 0) return false;
  const i = SHELLS.includes(words[0]) ? 1 : 0;
  return i < words.length && canon(words[i]) === stub;
}

// stubTrust(declared, env, git) — the ctx.trustedUrl predicate networkCheck asks, or null when
// guard.conf declares no stub (or the declared one is missing): every ssh URL is then refused.
function stubTrust(declared, env, git) {
  const stub = declared ? canon(declared) : null;
  if (!stub) return null;
  return (url, pre, fresh) => isSshUrl(url) && runsStub(sshCommand(env, git, pre || [], fresh), stub);
}

module.exports = { isSshUrl, shellWords, stubTrust };

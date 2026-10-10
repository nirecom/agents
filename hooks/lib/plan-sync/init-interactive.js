"use strict";
// hooks/lib/plan-sync/init-interactive.js
// Interactive setup for bin/plan-sync-init (#2513 4d): when no remote is configured and stdin
// is a TTY, propose the private repo <gh login>/agent-plans, create or reuse it with gh,
// provision the plans dir, and offer to write PLAN_SYNC_REMOTE_URL into the agents .env.
// gh is spawned without a shell and every value it returns is validated before use.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const GH_TIMEOUT_MS = 30000;
const REPO_NAME = "agent-plans";
// GitHub login grammar: alphanumerics and single hyphens, at most 39 characters.
const LOGIN_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;
// Spaces around "=" match too: the .env loader accepts them, so such a line is live.
const URL_LINE_RE = /^[ \t]*PLAN_SYNC_REMOTE_URL[ \t]*=[^\r\n]*/m;
const NOT_CONFIGURED = "plan-sync: not configured (PLAN_SYNC_REMOTE_URL empty)\n";

// shouldRunInteractive({ remoteUrlArg, url, isPlaceholder }) — only an unconfigured remote
// (empty or the .env.example placeholder) on a TTY, and never when --remote-url was given.
function shouldRunInteractive({ remoteUrlArg, url, isPlaceholder }) {
  if (remoteUrlArg !== undefined) return false;
  if (url && !isPlaceholder) return false;
  return process.env.PLAN_SYNC_INIT_ASSUME_TTY === "1" || process.stdin.isTTY === true;
}

function gh(args) {
  const r = spawnSync("gh", args, { encoding: "utf8", timeout: GH_TIMEOUT_MS, windowsHide: true });
  return { status: r.status, stdout: r.stdout || "", stderr: r.stderr || "", error: r.error || null };
}

// readAnswerLine() -> one stdin line without the newline, or null at EOF / on a read error.
function readAnswerLine() {
  const buf = Buffer.alloc(1);
  let s = "";
  for (let spins = 0; spins < 100000;) {
    let n;
    try {
      n = fs.readSync(0, buf, 0, 1, null);
    } catch (e) {
      if (e && e.code === "EAGAIN") { spins++; continue; }
      break;
    }
    if (n === 0) break;
    const ch = buf.toString("latin1");
    if (ch === "\n") return s.replace(/\r$/, "");
    s += ch;
  }
  return s.length ? s.replace(/\r$/, "") : null;
}

function ask(out, question) {
  out(`${question} [y/N] `);
  const a = readAnswerLine();
  out("\n");
  return a !== null && /^\s*y(es)?\s*$/i.test(a);
}

// envFilePath() — $AGENTS_CONFIG_DIR/.env (the agents repo's .env when the variable is unset).
function envFilePath() {
  const { configDirCandidates } = require("../agents-config-dir");
  const c = configDirCandidates()[0];
  return path.join(c ? c.dir : path.resolve(__dirname, "..", "..", ".."), ".env");
}

// writeEnvUrl(file, url) — replace every PLAN_SYNC_REMOTE_URL line in place (the .env parser
// takes the last one, so a stale duplicate would win), else append it; every other byte is kept.
function writeEnvUrl(file, url) {
  const line = `PLAN_SYNC_REMOTE_URL=${url}`;
  let body = "";
  try { body = fs.readFileSync(file, "utf8"); } catch (e) { if (!e || e.code !== "ENOENT") throw e; }
  let next;
  if (URL_LINE_RE.test(body)) next = body.replace(new RegExp(URL_LINE_RE.source, "gm"), () => line);
  else next = body + (body.length && !body.endsWith("\n") ? "\n" : "") + line + "\n";
  // Write a sibling temp file, then rename: an interrupted write never truncates the live .env.
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, next, { mode: 0o600 });
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* already gone */ }
    throw e;
  }
}

// repoState(repo) -> "absent" | "private" | "internal" | "public" | null (lookup failed).
function repoState(repo) {
  const r = gh(["api", `repos/${repo}`, "--jq", ".visibility"]);
  if (r.status === 0) {
    const v = r.stdout.trim().toLowerCase();
    return ["private", "internal", "public"].includes(v) ? v : null;
  }
  return /404|Not Found/i.test(r.stderr) ? "absent" : null;
}

// runInteractive({ PS, plansDir, out, err }) -> exit code.
function runInteractive({ PS, plansDir, out, err }) {
  const auth = gh(["auth", "status"]);
  if (auth.error && auth.error.code === "ENOENT") {
    out("plan-sync: gh (GitHub CLI) not found — install gh to create the plan repo interactively, " +
      "or set PLAN_SYNC_REMOTE_URL in .env and re-run.\n");
    out(NOT_CONFIGURED);
    return 0;
  }
  if (auth.error || auth.status !== 0) {
    out("plan-sync: gh is not authenticated — run `gh auth login`, then re-run plan-sync-init.\n");
    out(NOT_CONFIGURED);
    return 0;
  }
  const who = gh(["api", "user", "--jq", ".login"]);
  const login = who.status === 0 ? who.stdout.trim() : "";
  if (!LOGIN_RE.test(login)) {
    err("plan-sync-init: could not read a valid GitHub login from `gh api user`\n");
    return 1;
  }
  const repo = `${login}/${REPO_NAME}`;
  const state = repoState(repo);
  if (state === null) {
    err(`plan-sync-init: could not look up ${repo} with gh\n`);
    return 1;
  }
  // internal is visible to every member of the enterprise, so only private qualifies.
  if (state === "public" || state === "internal") {
    err(`plan-sync-init: ${repo} is ${state} — plans must live in a private repo; nothing was changed\n`);
    return 1;
  }
  if (state === "absent") {
    if (!ask(out, `plan-sync: create private GitHub repo ${repo}?`)) {
      out("plan-sync: nothing changed\n");
      return 0;
    }
    const c = gh(["repo", "create", repo, "--private"]);
    if (c.error || c.status !== 0) {
      err(`plan-sync-init: gh repo create ${repo} failed; nothing was provisioned\n`);
      return 1;
    }
  } else if (!ask(out, `plan-sync: use existing private GitHub repo ${repo}?`)) {
    out("plan-sync: nothing changed\n");
    return 0;
  }

  const url = `git@github.com:${repo}.git`;
  let result;
  try {
    result = PS.provisionRepo(plansDir, url);
  } catch (e) {
    err(`plan-sync-init: failed: ${PS.redactText(String(e && e.message))}\n`);
    return 1;
  }
  for (const note of result.notes || []) out(`plan-sync: ${PS.redactText(note)}\n`);
  if (!result.ok) {
    // The repo now exists, so a re-run reuses it; the usual cause is git having no SSH key for GitHub.
    err(`plan-sync-init: not provisioned (${result.reason}) for ${PS.redactUrl(url)}\n`);
    err(`plan-sync-init: ${repo} exists; check SSH access with \`ssh -T git@github.com\`, ` +
      `or set PLAN_SYNC_REMOTE_URL=https://github.com/${repo}.git in .env (after \`gh auth setup-git\`) and re-run\n`);
    return 1;
  }
  out(`plan-sync: provisioned ${plansDir} -> ${PS.redactUrl(url)}\n`);

  const envFile = envFilePath();
  if (ask(out, `plan-sync: write PLAN_SYNC_REMOTE_URL=${url} to ${envFile}?`)) {
    try {
      writeEnvUrl(envFile, url);
    } catch (e) {
      err(`plan-sync-init: could not write ${envFile}: ${e && e.code ? e.code : "error"}\n`);
      return 1;
    }
    out(`plan-sync: wrote PLAN_SYNC_REMOTE_URL to ${envFile}\n`);
  } else {
    out("plan-sync: add this line to your .env so hooks sync plans:\n");
    out(`PLAN_SYNC_REMOTE_URL=${url}\n`);
  }
  return 0;
}

module.exports = { shouldRunInteractive, runInteractive, writeEnvUrl, LOGIN_RE };

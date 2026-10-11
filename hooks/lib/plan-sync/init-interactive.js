"use strict";
// hooks/lib/plan-sync/init-interactive.js
// Interactive setup for bin/plan-sync-init (#2513): when the remote is empty or the
// .env.example placeholder and stdin is a TTY, create or reuse a private repo through the
// forge CLI (glab for a GitLab template, gh otherwise), provision the plans dir and offer
// to write PLAN_SYNC_REMOTE_URL into the agents .env. Forge CLIs are spawned without a
// shell, and every value they return is validated before use.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const remoteUrl = require("./remote-url");

const CLI_TIMEOUT_MS = 30000;
// Spaces around "=" match too: the .env loader accepts them, so such a line is live.
const URL_LINE_RE = /^[ \t]*PLAN_SYNC_REMOTE_URL[ \t]*=[^\r\n]*/gm;
const NOT_CONFIGURED = "plan-sync: not configured (PLAN_SYNC_REMOTE_URL empty)\n";

// shouldRunInteractive(url) — only an unconfigured remote (empty or the placeholder) on a TTY.
// PLAN_SYNC_INIT_ASSUME_TTY=1 is the test seam that stands in for a terminal on stdin.
function shouldRunInteractive(url) {
  if (url && !remoteUrl.isPlaceholderUrl(url)) return false;
  return process.env.PLAN_SYNC_INIT_ASSUME_TTY === "1" || process.stdin.isTTY === true;
}

// runCli(cmd, args) -> {status, stdout, stderr, error}; array argv, no shell.
function runCli(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8", timeout: CLI_TIMEOUT_MS, windowsHide: true });
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

function makeAsk(out) {
  return (question) => {
    out(`${question} [y/N] `);
    const a = readAnswerLine();
    out("\n");
    return a !== null && /^\s*y(es)?\s*$/i.test(a);
  };
}

// writeEnvUrl(file, url) — replace every PLAN_SYNC_REMOTE_URL line in place (the .env parser
// takes the last one, so a stale duplicate would win), else append it; every other byte is kept.
function writeEnvUrl(file, url) {
  const line = `PLAN_SYNC_REMOTE_URL=${url}`;
  let body = "";
  let mode = 0o600;
  try {
    body = fs.readFileSync(file, "utf8");
    mode = fs.statSync(file).mode & 0o777;
  } catch (e) {
    if (!e || e.code !== "ENOENT") throw e;
  }
  URL_LINE_RE.lastIndex = 0;
  const next = URL_LINE_RE.test(body)
    ? body.replace(URL_LINE_RE, () => line)
    : body + (body.length && !body.endsWith("\n") ? "\n" : "") + line + "\n";
  if (next === body) return;
  // A sibling temp file, then rename: an interrupted write never truncates the live .env.
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, next, { mode });
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) { /* already gone */ }
    throw e;
  }
}

// finish(ctx, url, deps) -> exit code: provision, then offer the .env write.
function finish(ctx, url, deps) {
  const { PS, plansDir, out, err, ask, exported } = ctx;
  let result;
  try {
    result = PS.provisionRepo(plansDir, url, deps);
  } catch (e) {
    err(`plan-sync-init: failed: ${PS.redactText(String(e && e.message))}\n`);
    return 1;
  }
  for (const note of result.notes || []) out(`plan-sync: ${PS.redactText(note)}\n`);
  if (!result.ok) {
    // The repo now exists, so a re-run reuses it; the usual cause is git having no SSH access.
    err(`plan-sync-init: not provisioned (${result.reason}) for ${PS.redactUrl(url)}; ` +
      "the repo exists, so check git's SSH access to it and re-run\n");
    return 1;
  }
  out(`plan-sync: provisioned ${plansDir} -> ${PS.redactUrl(url)}\n`);

  const envFile = require("../load-env").defaultEnvFilePath();
  const wrote = ask(`plan-sync: write PLAN_SYNC_REMOTE_URL=${url} to ${envFile}?`);
  if (wrote) {
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
  if (!exported) return 0;
  // The exported value still shadows .env in this shell, so sync is not on yet.
  out(wrote
    ? "plan-sync: written to .env, but not in effect until the export of PLAN_SYNC_REMOTE_URL is removed\n"
    : "plan-sync: not in effect until the line is in .env and the export of PLAN_SYNC_REMOTE_URL is removed\n");
  return 1;
}

// runInteractive({ PS, plansDir, template, source, out, err }) -> exit code.
// template is the resolved PLAN_SYNC_REMOTE_URL (empty or a placeholder); source is
// resolveConfigVar's layer ("export" when the caller's shell exported it).
function runInteractive({ PS, plansDir, template, source, out, err }) {
  const exported = source === "export";
  if (exported) {
    out("plan-sync: PLAN_SYNC_REMOTE_URL is set in the environment (export), which outranks .env; " +
      "the setup below still runs, but remove the export afterwards\n");
  }
  const ctx = { PS, plansDir, out, err, exported, ask: makeAsk(out), runCli, NOT_CONFIGURED };
  const t = template ? remoteUrl.resolveRemoteTarget(template) : null;
  const flow = t && t.type === "gitlab" ? require("./init-interactive-glab") : require("./init-interactive-gh");
  const r = flow.propose(ctx, template || "", t);
  if (typeof r.exit === "number") return r.exit;
  return finish(ctx, r.url, r.deps);
}

module.exports = { shouldRunInteractive, runInteractive, writeEnvUrl, NOT_CONFIGURED };

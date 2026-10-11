"use strict";
// hooks/lib/plan-sync/init-interactive-gh.js
// The gh half of plan-sync-init's interactive setup (./init-interactive.js): propose the
// private GitHub repo <login>/agent-plans, then create it or reuse an existing private one.
const { isValidOwner } = require("../parse-remote-url");

const REPO_NAME = "agent-plans";

// repoState(ctx, repo) -> "absent" | "private" | "internal" | "public" | null (lookup failed).
function repoState(ctx, repo) {
  const r = ctx.runCli("gh", ["api", `repos/${repo}`, "--jq", ".visibility"]);
  if (r.status === 0) {
    const v = r.stdout.trim().toLowerCase();
    return ["private", "internal", "public"].includes(v) ? v : null;
  }
  return /\b404\b|Not Found/i.test(r.stderr) ? "absent" : null;
}

// propose(ctx) -> { exit } to stop, or { url } to provision.
function propose(ctx) {
  const { out, err, ask } = ctx;
  const auth = ctx.runCli("gh", ["auth", "status"]);
  if (auth.error && auth.error.code === "ENOENT") {
    out("plan-sync: gh (GitHub CLI) not found — install gh to create the plan repo interactively, " +
      "or set PLAN_SYNC_REMOTE_URL in .env and re-run.\n");
    out(ctx.NOT_CONFIGURED);
    return { exit: 0 };
  }
  if (auth.error || auth.status !== 0) {
    out("plan-sync: gh is not authenticated — run `gh auth login`, then re-run plan-sync-init.\n");
    out(ctx.NOT_CONFIGURED);
    return { exit: 0 };
  }
  const who = ctx.runCli("gh", ["api", "user", "--jq", ".login"]);
  const login = who.status === 0 ? who.stdout.trim() : "";
  if (!isValidOwner(login)) {
    err("plan-sync-init: could not read a valid GitHub login from `gh api user`; nothing was changed\n");
    return { exit: 1 };
  }
  const repo = `${login}/${REPO_NAME}`;
  const state = repoState(ctx, repo);
  if (state === null) {
    err(`plan-sync-init: could not look up ${repo} with gh; nothing was changed\n`);
    return { exit: 1 };
  }
  // internal is visible to every member of the enterprise, so only private qualifies.
  if (state === "public" || state === "internal") {
    err(`plan-sync-init: ${repo} is ${state} — plans must live in a private repo; nothing was changed\n`);
    return { exit: 1 };
  }
  if (state === "absent") {
    if (!ask(`plan-sync: create private GitHub repo ${repo}?`)) {
      out("plan-sync: nothing changed\n");
      return { exit: 0 };
    }
    const c = ctx.runCli("gh", ["repo", "create", repo, "--private"]);
    if (c.error || c.status !== 0) {
      err(`plan-sync-init: gh repo create ${repo} failed; nothing was provisioned\n`);
      return { exit: 1 };
    }
  } else if (!ask(`plan-sync: use existing private GitHub repo ${repo}?`)) {
    out("plan-sync: nothing changed\n");
    return { exit: 0 };
  }
  return { url: `git@github.com:${repo}.git` };
}

module.exports = { propose };

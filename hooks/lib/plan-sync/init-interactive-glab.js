"use strict";
// hooks/lib/plan-sync/init-interactive-glab.js
// The glab half of plan-sync-init's interactive setup (./init-interactive.js), chosen for a
// GitLab placeholder template: fill the template's YOUR_USERNAME with the glab user, then
// create the project as private or reuse an existing private one. Every glab api call names
// the web host with --hostname (an SSH alias maps to it); the written URL keeps the
// template's own host. glab api has no --jq, so its JSON output is parsed here.
const remoteUrl = require("./remote-url");
const { encodePath, glabHostArg } = require("../forge/gitlab");

// GitLab username grammar: alphanumerics, "_", "." and "-", not starting with "." or "-".
const USERNAME_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,254}$/;
const REPO_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,254}$/;

function parseJson(text) {
  try {
    const v = JSON.parse(text);
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch (_) {
    return null;
  }
}

function isUsername(s) {
  return typeof s === "string" && USERNAME_RE.test(s) && !/\.(git|atom)$/i.test(s) && !s.includes("..");
}

// projectState(ctx, host, project) -> "absent" | "private" | "internal" | "public" | null.
function projectState(ctx, host, project) {
  const r = ctx.runCli("glab", ["api", "--hostname", host, `projects/${encodePath(project)}`]);
  if (r.status === 0 && !r.error) {
    const body = parseJson(r.stdout);
    const v = body && typeof body.visibility === "string" ? body.visibility.trim().toLowerCase() : "";
    return ["private", "internal", "public"].includes(v) ? v : null;
  }
  return /\b404\b/.test(r.stdout + r.stderr) ? "absent" : null;
}

// templateParts(t) -> {repo} | null — the template's path must be exactly YOUR_USERNAME/<repo>.
function templateParts(t) {
  const segs = t && typeof t.project === "string" ? t.project.split("/") : [];
  if (segs.length !== 2 || segs[0].toUpperCase() !== "YOUR_USERNAME") return null;
  return REPO_RE.test(segs[1]) ? { repo: segs[1] } : null;
}

// propose(ctx, template, t) -> { exit } to stop, or { url, deps } to provision.
function propose(ctx, template, t) {
  const { out, err, ask } = ctx;
  const parts = templateParts(t);
  const host = glabHostArg(t);
  if (!parts || !host) {
    err(`plan-sync-init: ${remoteUrl.redactUrl(template)} is not of the form <host>:YOUR_USERNAME/<project>; ` +
      "fill it in by hand in .env and re-run; nothing was changed\n");
    return { exit: 1 };
  }
  const who = ctx.runCli("glab", ["api", "--hostname", host, "user"]);
  if (who.error && who.error.code === "ENOENT") {
    out("plan-sync: glab (GitLab CLI) not found — install glab to create the plan project interactively, " +
      "or set PLAN_SYNC_REMOTE_URL in .env and re-run.\n");
    out(ctx.NOT_CONFIGURED);
    return { exit: 0 };
  }
  if (who.error || who.status !== 0) {
    out(`plan-sync: glab is not authenticated for ${host} — run \`glab auth login --hostname ${host}\`, ` +
      "then re-run plan-sync-init.\n");
    out(ctx.NOT_CONFIGURED);
    return { exit: 0 };
  }
  const body = parseJson(who.stdout);
  const login = body ? body.username : "";
  if (!isUsername(login)) {
    err(`plan-sync-init: could not read a valid GitLab username from glab api user on ${host}; nothing was changed\n`);
    return { exit: 1 };
  }
  const project = `${login}/${parts.repo}`;
  const url = remoteUrl.fillPlaceholder(template, login);
  const filled = remoteUrl.resolveRemoteTarget(url);
  if (filled.type !== "gitlab" || filled.project !== project || glabHostArg(filled) !== host) {
    err(`plan-sync-init: the filled-in URL does not resolve to ${project} on ${host}; nothing was changed\n`);
    return { exit: 1 };
  }
  const state = projectState(ctx, host, project);
  if (state === null) {
    err(`plan-sync-init: could not look up ${project} on ${host} with glab; nothing was changed\n`);
    return { exit: 1 };
  }
  // internal is visible to every signed-in user of the instance, so only private qualifies.
  if (state === "public" || state === "internal") {
    err(`plan-sync-init: ${project} on ${host} is ${state} — plans must live in a private project; nothing was changed\n`);
    return { exit: 1 };
  }
  if (state === "absent") {
    if (!ask(`plan-sync: create private GitLab project ${project} on ${host}?`)) {
      out("plan-sync: nothing changed\n");
      return { exit: 0 };
    }
    const c = ctx.runCli("glab", ["api", "--hostname", host, "projects", "-X", "POST",
      "-f", `name=${parts.repo}`, "-f", "visibility=private"]);
    if (c.error || c.status !== 0) {
      err(`plan-sync-init: creating ${project} on ${host} failed; nothing was provisioned\n`);
      return { exit: 1 };
    }
    // An instance policy can override the requested visibility, so read it back.
    const made = projectState(ctx, host, project);
    if (made !== "private") {
      err(`plan-sync-init: ${project} on ${host} came out ${made || "unverified"}, not private — ` +
        "make it private or delete it, then re-run; nothing was provisioned\n");
      return { exit: 1 };
    }
  } else if (!ask(`plan-sync: use existing private GitLab project ${project} on ${host}?`)) {
    out("plan-sync: nothing changed\n");
    return { exit: 0 };
  }
  // The project's privacy was just verified on its own host; the codehost's private listing
  // (forge default host, glab --jq) is not consulted, so the blocklist reminder always shows.
  return { url, deps: { listPrivateRepoNames: () => [] } };
}

module.exports = { propose };

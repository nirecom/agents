"use strict";
// bin/worker-dispatch/workers/commit-push/resume.js
//
// Empty-stage resume of the commit-push procedure (#2527 3-8b). A re-run after
// a commit landed but its push or PR did not finds nothing staged; instead of
// ending in staging_incomplete it resumes from the unpushed-commit count:
//   count > 0          -> the push tail (Step 5 onward), reported "resumed: push";
//   count = 0, PR path -> only the idempotent PR step (pr_created / pr_reused);
//   count = 0, direct  -> up_to_date.
// Counting is local only (no fetch): against <branch>@{upstream}, else against
// origin/<default>. A missing origin/<default> ref defers to the bootstrap probe.

const { firstLine, runGit } = require("./gate");

// → "origin/<name>" for the remote default branch, or null when no such ref exists locally.
function resolveOriginDefault(ctx, payload, gateEnv, log) {
  const sym = runGit(ctx, payload, ["symbolic-ref", "refs/remotes/origin/HEAD"], log);
  if (sym !== null && sym.status === 0) {
    const ref = String(sym.stdout || "").trim().replace(/^refs\/remotes\//, "");
    if (/^origin\/\S+$/.test(ref)) return ref;
  }
  const names = String(gateEnv.DEFAULT_BRANCHES || "").split(",").map((s) => s.trim()).filter(Boolean);
  for (const name of names.length ? names : ["main", "master"]) {
    const v = runGit(ctx, payload, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${name}`], log);
    if (v !== null && v.status === 0) return `origin/${name}`;
  }
  return null;
}

// → { ok: true, count } | { ok: false, missingBase: true } | { ok: false, reason }
function countUnpushed(ctx, payload, gateEnv, log) {
  const branch = payload.branch;
  const upstream = runGit(ctx, payload, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", `${branch}@{upstream}`], log);
  let base = upstream !== null && upstream.status === 0 ? `${branch}@{upstream}` : null;
  if (base === null) {
    base = resolveOriginDefault(ctx, payload, gateEnv, log);
    if (base === null) return { ok: false, missingBase: true };
  }
  const res = runGit(ctx, payload, ["rev-list", "--count", `${base}..HEAD`], log);
  if (res === null || res.spawnError || res.timedOut || res.status !== 0) {
    return { ok: false, reason: `git rev-list --count ${base}..HEAD failed: ${res === null ? "could not start" : firstLine(res.stderr) || `exit ${res.status}`}` };
  }
  const count = Number.parseInt(String(res.stdout || "").trim(), 10);
  if (!Number.isFinite(count) || count < 0) return { ok: false, reason: "git rev-list --count returned no number" };
  return { ok: true, count };
}

// deps: { finish, probeBootstrap, pushTail, ensurePr } — supplied by procedure.js.
function resumeFromEmptyStage(payload, ctx, gateEnv, log, deps) {
  const counted = countUnpushed(ctx, payload, gateEnv, log);
  if (!counted.ok && counted.missingBase) {
    if (deps.probeBootstrap()) {
      return deps.finish("bootstrap_pending", "nothing staged; remote has no default branch — /merge-to-main completes the bootstrap push");
    }
    return deps.finish("staging_check_failed", "nothing staged and no origin/<default> ref to count unpushed commits against — refusing to push");
  }
  if (!counted.ok) return deps.finish("staging_check_failed", `nothing staged; ${counted.reason}`);
  if (counted.count > 0) return deps.pushTail("resumed: push");
  const pr = deps.ensurePr();
  if (pr) return deps.finish(pr.status, pr.summary);
  return deps.finish("up_to_date", `${payload.branch}: nothing staged and no unpushed commits — nothing to do`);
}

module.exports = { resumeFromEmptyStage, countUnpushed, resolveOriginDefault };

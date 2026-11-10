"use strict";
// Forge type of an origin for the /migrate-* skills (#2960): the resolver's judgment (exact host match,
// GITLAB_HOSTNAME / GITLAB_SSH_HOSTNAME from the effective .env), then — for migrate only — an
// unconfigured host with a `gitlab.` label is guessed gitlab. Never reclassifies to github (the
// docs/architecture/gitlab-support.md §3 invariant); no project path → no guess (#2308 fail-safe).

const { resolveForgeTarget } = require("../../hooks/lib/parse-remote-url");
const { readGitlabHostConfig, readGitlabSshHostConfig } = require("../../hooks/lib/forge-router");

const GITLAB_LABEL_RE = /(^|\.)gitlab\./;

// guessUnconfiguredType(res) — the type of a resolveForgeTarget result with the gitlab guess applied.
function guessUnconfiguredType(res) {
  if (res.type !== "unknown") return res.type;
  if (res.project === null || !res.host) return "unknown";
  return GITLAB_LABEL_RE.test(String(res.host).toLowerCase()) ? "gitlab" : "unknown";
}

// migrateForgeType(url, root) — { type, host, project }; host and project are the resolver's own.
function migrateForgeType(url, root) {
  const res = resolveForgeTarget(url, {
    gitlabHost: readGitlabHostConfig(root),
    gitlabSshHost: readGitlabSshHostConfig(root),
  });
  return { type: guessUnconfiguredType(res), host: res.host, project: res.project };
}

module.exports = { guessUnconfiguredType, migrateForgeType };

"use strict";
// Forge type of an origin for the /migrate-* skills (#2960): the resolver's judgment (exact host match,
// GITLAB_HOSTNAME / GITLAB_SSH_HOSTNAME from the effective .env), then — for migrate only — an
// unconfigured host with a `gitlab.` label is guessed gitlab. The one github reclassification is a
// host that is a plan-sync HOST_ALIASES key: it follows that alias, and github needs exactly
// owner/repo (the docs/architecture/gitlab-support.md §3 invariant otherwise holds); no project
// path → no guess (#2308 fail-safe).

const {
  resolveForgeTarget, FORGE_HOST_TYPES, isValidOwner, isValidRepo,
} = require("../../hooks/lib/parse-remote-url");
const { HOST_ALIASES } = require("../../hooks/lib/plan-sync/remote-url");
const { readGitlabHostConfig, readGitlabSshHostConfig } = require("../../hooks/lib/forge-router");

const GITLAB_LABEL_RE = /(^|\.)gitlab\./;
const hasOwn = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

function aliasType(host, project) {
  const target = HOST_ALIASES[host];
  const type = hasOwn(FORGE_HOST_TYPES, target) ? FORGE_HOST_TYPES[target] : "unknown";
  if (type === "gitlab") return type;
  if (type !== "github") return "unknown";
  const segs = String(project).split("/");
  return segs.length === 2 && isValidOwner(segs[0]) && isValidRepo(segs[1]) ? "github" : "unknown";
}

// guessUnconfiguredType(res) — the type of a resolveForgeTarget result with the alias / gitlab guess applied.
function guessUnconfiguredType(res) {
  if (res.type !== "unknown") return res.type;
  if (res.project === null || !res.host) return "unknown";
  const host = String(res.host).toLowerCase();
  if (hasOwn(HOST_ALIASES, host)) return aliasType(host, res.project);
  return GITLAB_LABEL_RE.test(host) ? "gitlab" : "unknown";
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

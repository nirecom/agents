"use strict";
// The forge kind of a checkout's origin (#2942): the PM field lives on GitHub Projects v2 only, so a
// gitlab (or unknown) origin skips every PM field read and write before any gh call.
//   forgeKindOf({origin?, cwd?}) -> "github" | "gitlab" | "unknown"
// origin is a remote URL; without it the cwd's `git remote get-url origin` is read (a local git call).

const { spawnSync } = require("child_process");
const { buildGitSpawn } = require("../../workflow/lib/workflow-init/spawn-env");
const { resolveForgeTarget } = require("../../../hooks/lib/parse-remote-url");

const ORIGIN_TIMEOUT_MS = 2000;

function originOf(cwd) {
  const [cmd, args, opts] = buildGitSpawn(["remote", "get-url", "origin"]);
  const r = spawnSync(cmd, args, Object.assign({}, opts, { cwd: cwd || process.cwd(), timeout: ORIGIN_TIMEOUT_MS, windowsHide: true }));
  return r.status === 0 && r.stdout ? String(r.stdout).split(/\r?\n/)[0].trim() : null;
}

function forgeKindOf(opts) {
  const o = opts || {};
  const url = typeof o.origin === "string" ? o.origin : originOf(o.cwd);
  if (!url) return "unknown";
  try {
    const t = resolveForgeTarget(url, {});
    return t && (t.type === "github" || t.type === "gitlab") ? t.type : "unknown";
  } catch (_) {
    return "unknown";
  }
}

module.exports = { forgeKindOf, originOf };

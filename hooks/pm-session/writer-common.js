"use strict";
// Shared parts of the pm key writer (#2941): the refusal type, the state reads, the home repo, the
// forge context and the `[pm-session]` note. Used by ./writer.js and ./inherit.js only.

const path = require("path");
const io = require("../workflow-state/state-io");
const S = require("./schema");
const { GH_MIN_CALL_MS } = require("./budget");

const BIN = path.join(__dirname, "..", "..", "bin", "lib");
const { ORIGIN_TIMEOUT_MS } = require(path.join(BIN, "pm-field", "forge-kind"));

class Refusal extends Error {}
const refuse = (msg) => { throw new Refusal(msg); };

function rawOf(sid) {
  try { return io.readRawState(sid); } catch (_) { return refuse("the session's state file cannot be read"); }
}

function workflowBegun(sid) {
  const { readWorkflowBegun } = require("../lib/workflow-begun");
  return readWorkflowBegun(sid).verdict === "begun";
}

// homeOriginOf(input, deps) -> the cwd's origin URL (a local git read, no forge), or null; read once per run.
function homeOriginOf(input, deps) {
  if (input && Object.prototype.hasOwnProperty.call(input, "__origin")) return input.__origin;
  let url;
  try {
    const { toWindowsPath } = require("../lib/branch-diff");
    const { originUrl } = require("../workflow-gate/gh-detect");
    const cwd = toWindowsPath(typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd());
    url = originUrl(cwd, { timeoutMs: ORIGIN_TIMEOUT_MS, spawnSync: deps && deps.spawnSync }) || null;
  } catch (_) {
    url = null;
  }
  if (input && typeof input === "object") Object.defineProperty(input, "__origin", { value: url, enumerable: false });
  return url;
}

// homeRepoOf(input, deps) -> the owner/repo of the cwd's origin, or null.
function homeRepoOf(input, deps) {
  try {
    const { parseOriginOwnerRepo } = require("../lib/parse-remote-url");
    const url = homeOriginOf(input, deps);
    const parsed = url ? parseOriginOwnerRepo(url) : null;
    return parsed && parsed.ok ? parsed.ownerRepo : null;
  } catch (_) {
    return null;
  }
}

// normalizeRef(ref, home) -> {number, repo:"owner/repo"}, the one ref normalizer of the writer and
// bin/pm-state (#2942); idempotent. A ref whose repo cannot be resolved is Refusal("repo-unresolved").
function normalizeRef(ref, home) {
  const repo = S.resolveRepo(ref, home);
  if (!repo.includes("/")) {
    refuse(`repo-unresolved: the repo of #${ref && ref.number} cannot be resolved (repo-unknown), and retrying will not fix it; run from a checkout whose origin is the issue's repo, or write owner/repo#N.`);
  }
  return { number: Number(ref.number), repo };
}

// normalizeStoredRef(ref, home) -> normalizeRef's answer, or the stored ref {number, repo?} when its repo
// cannot be resolved: for refs already in a state file (another PM's issues, an inherited assignment),
// which the caller reads but never takes from the user. ancestry.holdersOf answers repo-unknown for it.
function normalizeStoredRef(ref, home) {
  try { return normalizeRef(ref, home); } catch (e) {
    if (e instanceof Refusal) return S.toRef(ref);
    throw e;
  }
}

// ancestryOf(deps, deadlineAt?) -> a range checker over the forge, bounded by deadlineAt (the budget's check
// deadline; not finite: no deadline). The default fetch runs gh through deps.spawnSync.
function ancestryOf(deps, deadlineAt) {
  const { createAncestry } = require(path.join(BIN, "pm-state", "ancestry"));
  let fetch = deps && deps.fetchAncestorChains;
  if (!fetch) {
    const base = require(path.join(BIN, "forge-issue-links")).fetchAncestorChains;
    const spawnSync = deps && typeof deps.spawnSync === "function" ? deps.spawnSync : undefined;
    fetch = (refs, opts) => base(refs, Object.assign({}, opts, { spawnSync, minCallMs: GH_MIN_CALL_MS }));
  }
  return createAncestry({ fetchAncestorChains: fetch, deadlineAt: Number.isFinite(deadlineAt) ? deadlineAt : undefined });
}

// lockRefusal(e) -> the Refusal of a busy PM lock, or e itself; the writer shows it like any refusal.
function lockRefusal(e) {
  const { PmLockBusy } = require("./pm-lock");
  return e instanceof PmLockBusy ? new Refusal(e.message) : e;
}

const labels = (refs) => refs.map(S.refLabel).join(" ") || "(none)";

function note(op, pm, extra) {
  const ended = Boolean(pm.archived_at);
  return [
    `[pm-session] op=${op} tag=${pm.tag}`,
    `issues=${labels(pm.issues)} ended=${ended}`,
  ].concat(extra || []).concat([
    ended
      ? `This PM session has ended: it owns no issue any more, and PM tag ${pm.tag} is used and never reused. Tell the user and do not run a workflow here.`
      : "This is a PM session: no workflow runs here. Order the work with bin/pm-state set-sequence; change the assignment with /pm-add and /pm-remove.",
  ]).join("\n");
}

module.exports = {
  Refusal, refuse, rawOf, workflowBegun, homeOriginOf, homeRepoOf,
  normalizeRef, normalizeStoredRef, ancestryOf, lockRefusal, labels, note,
};

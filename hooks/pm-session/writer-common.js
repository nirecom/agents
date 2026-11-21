"use strict";
// Shared parts of the pm key writer (#2941): the refusal type, the state reads, the home repo, the
// forge context and the `[pm-session]` note. Used by ./writer.js and ./inherit.js only.

const path = require("path");
const io = require("../workflow-state/state-io");
const S = require("./schema");

// The forge budget of one writer run: the hook's 10 s timeout also holds node start-up, the scan,
// the writer's origin read (1 s) and the title's origin (1 s) and tracker (3 s) reads.
const WRITER_FORGE_BUDGET_MS = 3000;
const ORIGIN_TIMEOUT_MS = 1000;

class Refusal extends Error {}
const refuse = (msg) => { throw new Refusal(msg); };

function rawOf(sid) {
  try { return io.readRawState(sid); } catch (_) { return refuse("the session's state file cannot be read"); }
}

function workflowBegun(sid) {
  const { readWorkflowBegun } = require("../lib/workflow-begun");
  return readWorkflowBegun(sid).verdict === "begun";
}

// homeRepoOf(input, deps) -> the owner/repo of the cwd's origin (a local git read, no forge), or null.
function homeRepoOf(input, deps) {
  try {
    const { toWindowsPath } = require("../lib/branch-diff");
    const { originUrl } = require("../workflow-gate/gh-detect");
    const { parseOriginOwnerRepo } = require("../lib/parse-remote-url");
    const cwd = toWindowsPath(typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd());
    const url = originUrl(cwd, { timeoutMs: ORIGIN_TIMEOUT_MS, spawnSync: deps && deps.spawnSync });
    const parsed = url ? parseOriginOwnerRepo(url) : null;
    return parsed && parsed.ok ? parsed.ownerRepo : null;
  } catch (_) {
    return null;
  }
}

// resolved(ref, home) -> {number, repo:"owner/repo"} when the repo is known, else the stored ref
// (ancestry.holdersOf then answers repo-unknown for it).
function resolved(ref, home) {
  const repo = S.resolveRepo(ref, home);
  return repo.includes("/") ? { number: Number(ref.number), repo } : S.toRef(ref);
}

// ancestryOf(deps) -> a range checker over the forge, bounded by WRITER_FORGE_BUDGET_MS from now.
function ancestryOf(deps) {
  const BIN = path.join(__dirname, "..", "..", "bin", "lib");
  const { createAncestry } = require(path.join(BIN, "pm-state", "ancestry"));
  const fetch = (deps && deps.fetchAncestorChains) || require(path.join(BIN, "forge-issue-links")).fetchAncestorChains;
  return createAncestry({ fetchAncestorChains: fetch, deadlineAt: Date.now() + WRITER_FORGE_BUDGET_MS });
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

module.exports = { WRITER_FORGE_BUDGET_MS, ORIGIN_TIMEOUT_MS, Refusal, refuse, rawOf, workflowBegun, homeRepoOf, resolved, ancestryOf, labels, note };

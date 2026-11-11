"use strict";

// WHERE does this write land? gh answers that from four places at once — the
// --repo selector, GH_REPO, the endpoint path, and the origin of the working
// directory — and the guard has to reach the SAME answer gh would, or it proves
// ownership of a repository the command was never going to touch. Every rung
// that cannot be read literally ends the resolution: an unreadable target is
// not a missing target, it is an unknown one.
const { parseOriginOwnerRepo } = require("../lib/parse-remote-url");
const { normalizeCwd } = require("../lib/path-normalize");
const { runProbe, repoFacts, GIT_PROBE_CAP_MS } = require("./prove-ownership");
const {
  unresolved, hostIsGithub, hostSelector, hostSelectorIsGithub, repoSelectors, splitSelector, resolveSelectors,
} = require("../lib/forge-repo-selectors");

const REMOTE_CONFIG_RE = /^remote\.(.+)\.(url|gh-resolved)$/;

function readRemotes(cwd, budget) {
  const dir = normalizeCwd(cwd);
  const res = runProbe(
    ["git", "-C", dir, "config", "--get-regexp", "^remote\\..*\\.(url|gh-resolved)$"],
    budget,
    GIT_PROBE_CAP_MS
  );
  if (!res || res.status !== 0) return null;
  const urls = {};
  const resolved = {};
  for (const line of res.stdout.split(/\r?\n/)) {
    const trimmed = line.trim();
    const sp = trimmed.indexOf(" ");
    if (sp <= 0) continue;
    const match = trimmed.slice(0, sp).match(REMOTE_CONFIG_RE);
    if (!match) continue;
    if (match[2] === "url") urls[match[1]] = trimmed.slice(sp + 1);
    else resolved[match[1]] = trimmed.slice(sp + 1);
  }
  return { urls, resolved };
}

// The implicit target: the repository the working directory points at. Anything
// ambiguous about that checkout — several remotes, a gh-resolved override, a
// non-github origin, a fork whose issues land upstream — ends the resolution.
function cwdTarget(cwd, budget) {
  if (typeof cwd !== "string" || cwd.trim() === "") {
    return unresolved("no working directory was supplied, so the implicit target cannot be read");
  }
  const remotes = readRemotes(cwd, budget);
  if (!remotes) return unresolved("the working directory is not a readable git checkout");
  const names = Object.keys(remotes.urls);
  if (names.length !== 1 || names[0] !== "origin") {
    return unresolved("the checkout does not have exactly one origin remote, so the implicit target is ambiguous");
  }
  const ghResolved = remotes.resolved.origin;
  const parsed = parseOriginOwnerRepo(remotes.urls.origin);
  if (!parsed || !parsed.ok) {
    return unresolved("the origin remote is not a readable github.com repository");
  }
  if (typeof ghResolved === "string" && ghResolved !== "base" && ghResolved.toLowerCase() !== parsed.ownerRepo.toLowerCase()) {
    return unresolved("gh-resolved points the checkout at a different repository than its origin");
  }
  const facts = repoFacts(parsed.ownerRepo, budget);
  if (!facts) return unresolved("the implicit target " + parsed.ownerRepo + " could not be inspected");
  // Only a CONFIRMED `fork: false` clears this rung. An unreadable or absent
  // fork field is not a promise that the checkout is upstream — and if it is a
  // fork, the issue lands in someone else's repository.
  if (facts.fork !== false) {
    const parent = facts.parent || "its upstream";
    return unresolved("the checkout " + parsed.ownerRepo + " is a fork, so an issue filed here may land in " + parent);
  }
  return { kind: "cwd-derived", ownerRepo: parsed.ownerRepo };
}

// A GH_REPO that arrives from the session record or from the ambient process
// environment is weaker evidence than one written on the command line: it may be
// stale. It only stands when the checkout agrees with it (CPR-E2E) — and when
// the two disagree the user has to be told BOTH names, since either could be the
// one the command would really have written to.
function reconcileAmbient(ambient, cwd, budget, cwdAllowed) {
  if (!cwdAllowed) {
    return unresolved("GH_REPO names " + ambient + " but the working directory could not be checked against it");
  }
  const derived = cwdTarget(cwd, budget);
  if (derived.kind !== "cwd-derived") {
    return unresolved("GH_REPO names " + ambient + " and " + derived.why);
  }
  if (derived.ownerRepo.toLowerCase() !== ambient.toLowerCase()) {
    return unresolved("GH_REPO names " + ambient + " but the checkout is " + derived.ownerRepo);
  }
  return { kind: "explicit", ownerRepo: derived.ownerRepo };
}

// `gh api` has no --repo flag at all, so a selector on an api call cannot be
// the target: the endpoint PATH is. Letting the selector outrank it is how a
// write to the endpoint's repository goes silent behind a selector naming one
// the caller happens to own — so agreement stands, and divergence asks.
function reconcileApi(apiTarget, selectorVerdict) {
  if (!selectorVerdict) return { kind: "explicit", ownerRepo: apiTarget };
  if (selectorVerdict.kind === "unresolved") return selectorVerdict;
  if (selectorVerdict.ownerRepo.toLowerCase() !== apiTarget.toLowerCase()) {
    return unresolved("a repo selector names " + selectorVerdict.ownerRepo +
      " but the gh api endpoint targets " + apiTarget);
  }
  return { kind: "explicit", ownerRepo: apiTarget };
}

// The precedence ladder, highest first.
function resolveTarget(opts) {
  const selectorVerdict = resolveSelectors(opts.selectors || [], opts.rawText || "");
  if (opts.apiTarget) return reconcileApi(opts.apiTarget, selectorVerdict);
  if (selectorVerdict) return selectorVerdict;
  if (opts.apiInScope) return unresolved("the gh api endpoint does not name a repository the guard can read");
  const repoEnv = opts.ghRepo;
  if (repoEnv && repoEnv.present) {
    if (!repoEnv.readable || repoEnv.value === null) {
      return unresolved("GH_REPO is set to a value the guard cannot read");
    }
    const ownerRepo = splitSelector(repoEnv.value);
    if (!ownerRepo) return unresolved("GH_REPO is not a valid OWNER/REPO on github.com");
    if (repoEnv.rank <= 2) return { kind: "explicit", ownerRepo };
    return reconcileAmbient(ownerRepo, opts.cwd, opts.budget, opts.cwdAllowed);
  }
  if (!opts.cwdAllowed) {
    return unresolved("the target is implicit and the working directory this command runs in cannot be established");
  }
  return cwdTarget(opts.cwd, opts.budget);
}

module.exports = {
  resolveTarget,
  cwdTarget,
  hostSelector,
  hostSelectorIsGithub,
  hostIsGithub,
  repoSelectors,
  splitSelector,
};

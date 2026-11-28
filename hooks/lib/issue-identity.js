"use strict";
// SSOT of issue identity (#1889): the issue-ref rule shared by the pm state (hooks/pm-session/schema.js
// re-exports it) and the issue-close outcome bag. A ref is {number, repo?}; an outcome entry is
// {issueNumber, issueRepo?, state, ...}. Its key is (repo resolved against the home repo, N), so
// `#42` and `o/r#42` are one issue when o/r is home. Without a home repo nothing is normalized.
// Dependency-free: required by state-io's zombie sweep through the pm schema.

const OWNER_REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const REPO_RE = /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)?$/;
const CLOSED_STATES = Object.freeze(["succeeded", "subsumed", "already_closed"]);

// resolveRepo(ref, homeRepo) -> the repo a ref names: `#N` is in homeRepo (the cwd's origin
// owner/repo), `r#N` in homeRepo's owner; "" when unknown. Without homeRepo a ref's repo is taken as given.
function resolveRepo(ref, homeRepo) {
  const home = typeof homeRepo === "string" ? homeRepo : "";
  let r = ref && typeof ref.repo === "string" && ref.repo ? ref.repo : home;
  if (r && !r.includes("/") && home.includes("/")) r = `${home.split("/")[0]}/${r}`;
  return r;
}

const repoOf = (ref, homeRepo) => resolveRepo(ref, homeRepo).toLowerCase();

function sameIssue(a, b, homeRepo) {
  return Boolean(a) && Boolean(b) && Number(a.number) === Number(b.number) && repoOf(a, homeRepo) === repoOf(b, homeRepo);
}

// toRef(ref) -> the stored form {number, repo?}.
function toRef(ref) {
  const out = { number: Number(ref.number) };
  if (ref.repo) out.repo = String(ref.repo);
  return out;
}

const refLabel = (ref) => (ref.repo ? `${ref.repo}#${ref.number}` : `#${ref.number}`);

const normalizeHome = (r) => (typeof r === "string" && OWNER_REPO_RE.test(r) ? r : "");

function outcomeRef(e) {
  const out = { number: e.issueNumber };
  if (typeof e.issueRepo === "string" && e.issueRepo) out.repo = e.issueRepo;
  return out;
}

const refKey = (ref, homeRepo) => `${repoOf(ref, normalizeHome(homeRepo))}#${ref.number}`;

// refDisplay(ref, homeRepo) -> `#N` for the home repo (or an unknown repo), else `owner/repo#N`.
function refDisplay(ref, homeRepo) {
  const home = normalizeHome(homeRepo);
  const repo = resolveRepo(ref, home);
  return repo === "" || repo.toLowerCase() === home.toLowerCase() ? `#${ref.number}` : `${repo}#${ref.number}`;
}

const outcomeKey = (e, homeRepo) => refKey(outcomeRef(e), homeRepo);
const outcomeLabel = (e, homeRepo) => refDisplay(outcomeRef(e), homeRepo);

function isValidOutcomeEntry(e) {
  if (!e || typeof e !== "object" || Array.isArray(e)) return false;
  if (!Number.isInteger(e.issueNumber) || e.issueNumber <= 0) return false;
  return e.issueRepo === undefined || (typeof e.issueRepo === "string" && REPO_RE.test(e.issueRepo));
}

module.exports = {
  CLOSED_STATES, resolveRepo, repoOf, sameIssue, toRef, refLabel, normalizeHome,
  outcomeRef, outcomeKey, outcomeLabel, refKey, refDisplay, isValidOutcomeEntry,
};

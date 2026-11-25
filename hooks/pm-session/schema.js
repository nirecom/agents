"use strict";
// SSOT of the `pm` state key (#2941): the tag syntax, the two predicates, and issue identity.
// pm = {tag, issues: [{number, repo?}], objective, current_since, upstream_session_id,
//       assignment_log: [{at, op, issues, reason}], sequence: {updated_at, tables, unverified}, archived_at,
//       rename_pending?: {from, to}, retired_tags?: [tag], meta_children?: {<meta ref>: [child ref]},
//       seen_notifications?: [id] (last SEEN_NOTIFICATIONS_MAX)} — the optional four are #2942's.
// assignment_log[].reason is a non-empty string (REASON_UNSTATED when none was given). sequence.unverified
// is {reason, at} | null, reason one of UNVERIFIED_REASONS; only a passing check clears it.
// hasPmMark: the key exists (archived included); isActivePm: and archived_at is null.
// Dependency-free: required by state-io's zombie sweep.

const PM_TAG_RE = /^[A-Za-z0-9-]{1,40}$/;
const PM_OPS = Object.freeze(["init", "add", "remove", "inherit"]);
const REASON_UNSTATED = "reason not stated";
const UNVERIFIED_REASONS = Object.freeze(["gh_exec_failed", "timeout", "budget-exhausted", "spawn-failed", "parse_failed", "removed"]);
const SEEN_NOTIFICATIONS_MAX = 200;

function isValidPmTag(tag) {
  return typeof tag === "string" && PM_TAG_RE.test(tag);
}

function hasPmMark(state) {
  return Boolean(state) && typeof state === "object" && Boolean(state.pm) && typeof state.pm === "object" && !Array.isArray(state.pm);
}

function isActivePm(state) {
  return hasPmMark(state) && !state.pm.archived_at;
}

const sameTag = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

// resolveRepo(ref, homeRepo) -> the repo a ref names, the one issue-ref rule of the writer and
// bin/pm-state: `#N` is in homeRepo (the cwd's origin owner/repo), `r#N` in homeRepo's owner; ""
// when unknown. Without homeRepo a ref's repo is taken as given.
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

module.exports = {
  PM_TAG_RE, PM_OPS, REASON_UNSTATED, UNVERIFIED_REASONS, SEEN_NOTIFICATIONS_MAX, isValidPmTag, hasPmMark, isActivePm, sameTag, resolveRepo, repoOf, sameIssue, toRef, refLabel,
};

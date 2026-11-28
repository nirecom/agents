"use strict";
// SSOT of the `pm` state key (#2941): the tag syntax, the two predicates, and issue identity.
// pm = {tag, issues: [{number, repo?}], objective, current_since, upstream_session_id,
//       assignment_log: [{at, op, issues, reason}], sequence: {updated_at, tables, unverified}, archived_at,
//       rename_pending?: {from, to}, retired_tags?: [tag], meta_children?: {<meta ref>: [child ref]},
//       seen_notifications?: [id] (last SEEN_NOTIFICATIONS_MAX)} — the optional four are #2942's.
// assignment_log[].reason is a non-empty string (REASON_UNSTATED when none was given). sequence.unverified
// is {reason, at} | null, reason one of UNVERIFIED_REASONS; only a passing check clears it.
// hasPmMark: the key exists (archived included); isActivePm: and archived_at is null.
// Issue identity (resolveRepo / repoOf / sameIssue / toRef / refLabel) is hooks/lib/issue-identity.js, re-exported here.
// Dependency-free beyond that module: required by state-io's zombie sweep.

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

const { resolveRepo, repoOf, sameIssue, toRef, refLabel } = require("../lib/issue-identity");

module.exports = {
  PM_TAG_RE, PM_OPS, REASON_UNSTATED, UNVERIFIED_REASONS, SEEN_NOTIFICATIONS_MAX, isValidPmTag, hasPmMark, isActivePm, sameTag, resolveRepo, repoOf, sameIssue, toRef, refLabel,
};

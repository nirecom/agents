"use strict";
// bin/worker-dispatch/capability.js
//
// Capability validation — the second wall.
//
// The payload is untrusted input. The main-worktree guard already rejected
// obviously dangerous argv, but the guard sees one sanctioned identifier and a
// file path; it cannot know what the file says. So every field is typed by
// *what it can cause*, and every path-shaped type is cross-validated against a
// derived anchor (ACD / MAIN_ROOT / FAMILY / PLANS_DIR).
//
// There is deliberately NO generic `abs-path` type. "It is an absolute path" is
// not a capability — `C:\Windows\System32` is an absolute path too. A field that
// cannot be tied back to an anchor does not get to be a path.

const path = require("path");

const { realAbs, isUnder, samePath, sameString, stripTrailingSep } = require("./anchor");

const RE_BRANCH = /^[A-Za-z0-9._/+-]+$/;
const RE_ABS_PREFIX = /^(?:[A-Za-z]:|[\\/])/;
const RE_OWNER_REPO = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
// `owner/repo` OR a bare `repo`. Distinct from RE_OWNER_REPO because the
// close-family `issue_repo` argument is documented to accept both forms; the
// two types stay separate so a field that genuinely needs the qualified form
// (owner_repo) cannot silently start accepting a bare name.
const RE_REPO_REF = /^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)?$/;
const RE_SESSION_ID = /^[A-Za-z0-9_-]+$/;
const RE_ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

const DEFAULT_TEXT_MAX = 200000;
const DEFAULT_ITEMS_MAX = 256;
const BACKUP_DIR_NAME = ".worktree-backup";
// The finalize chain's scripts live at a fixed path inside the agents checkout.
// Authored with `/` and split before joining, so the constant is one spelling on
// every platform.
const FINALIZE_SCRIPTS_REL = "skills/issue-close-finalize/scripts";

function isPlainString(v) {
  return typeof v === "string";
}

// A branch name is not just a charset — it is also a sequence of path segments,
// because `derived-backup-dir` joins it onto a root. `path.join` normalizes `..`
// away, so a charset-only test lets `../../x` walk the derived directory out of
// the backup root entirely. Git ref rules already forbid every segment rejected
// here, so nothing legitimate is lost.
function isSafeBranch(v) {
  if (!isPlainString(v) || !RE_BRANCH.test(v)) return false;
  if (v.startsWith("/") || v.endsWith("/") || v.includes("//")) return false;
  return v.split("/").every((seg) => seg !== "." && seg !== ".." && !seg.startsWith("-"));
}

// A relative argument that the child resolves against its own cwd. Anchoring it
// the way path-shaped types do is impossible — the value may be a glob that
// matches nothing yet — so containment is proven structurally instead: it cannot
// name a root, cannot climb out with `..`, and cannot be read as an option.
function checkRelPathArg(value) {
  if (!isPlainString(value)) return { error: "must be a string" };
  if (value === "") return { error: "must not be empty" };
  if (value.startsWith("-")) return { error: "must not start with '-'" };
  if (RE_ABS_PREFIX.test(value)) return { error: "must be relative to the working directory" };
  const segments = value.split(/[\\/]/);
  if (segments.some((seg) => seg === "..")) return { error: "must not contain a '..' segment" };
  for (const ch of value) {
    if (ch.codePointAt(0) < 32) return { error: "must not contain control characters" };
  }
  return { value };
}

function checkText(value, field) {
  if (!isPlainString(value)) return { error: "must be a string" };
  const max = typeof field.max === "number" ? field.max : DEFAULT_TEXT_MAX;
  if (value.length > max) return { error: `exceeds the ${max} character limit` };
  // No content inspection: `text` carries commit bodies and PR titles, and the
  // dispatcher never puts it near a shell. Sanitization happens once, at the
  // single stdout boundary in emit.js.
  return { value };
}

function checkArray(value, field, checkElement) {
  if (!Array.isArray(value)) return { error: "must be an array" };
  const maxItems = typeof field.maxItems === "number" ? field.maxItems : DEFAULT_ITEMS_MAX;
  if (value.length > maxItems) return { error: `exceeds the ${maxItems} item limit` };
  const out = [];
  for (const item of value) {
    const r = checkElement(item, field);
    if (r.error) return { error: `every element ${r.error}` };
    out.push(r.value);
  }
  return { value: out };
}

function checkInt(value, field) {
  if (typeof value !== "number" || !Number.isInteger(value)) return { error: "must be an integer" };
  if (typeof field.min === "number" && value < field.min) return { error: `must be >= ${field.min}` };
  if (typeof field.max === "number" && value > field.max) return { error: `must be <= ${field.max}` };
  return { value };
}

function checkPattern(value, re, what) {
  if (!isPlainString(value)) return { error: "must be a string" };
  if (!re.test(value)) return { error: `is not a well-formed ${what}` };
  return { value };
}

function checkEnum(value, type) {
  const allowed = type.slice("enum:".length).split("|");
  if (!isPlainString(value) || !allowed.includes(value)) {
    return { error: `must be one of: ${allowed.join(", ")}` };
  }
  return { value };
}

// --- path-shaped types: each one names the anchor it is measured against ----

function checkAnchored(value, anchorPath, label) {
  if (!isPlainString(value)) return { error: "must be a string" };
  if (!samePath(value, anchorPath)) return { error: `must be exactly the ${label}` };
  return { value: realAbs(value) };
}

function checkUnder(value, anchorPath, label, allowEqual) {
  if (!isPlainString(value)) return { error: "must be a string" };
  const abs = realAbs(value);
  if (abs === null) return { error: "must be an absolute path" };
  if (!isUnder(abs, anchorPath, allowEqual)) return { error: `must be inside the ${label}` };
  return { value: abs };
}

function checkFamilyMember(value, family) {
  if (!isPlainString(value)) return { error: "must be a string" };
  const abs = realAbs(value);
  if (abs === null) return { error: "must be an absolute path" };
  const hit = family.find((f) => sameString(stripTrailingSep(f), stripTrailingSep(abs)));
  if (!hit) return { error: "must be a worktree registered under main-root" };
  return { value: hit };
}

function checkUnderFamily(value, family) {
  if (!isPlainString(value)) return { error: "must be a string" };
  const abs = realAbs(value);
  if (abs === null) return { error: "must be an absolute path" };
  const hit = family.some((f) => isUnder(abs, f, true));
  if (!hit) return { error: "must be inside a worktree of the main-root family" };
  return { value: abs };
}

// The backup directory is DERIVED, never accepted: <main-root>/.worktree-backup/<branch>.
// A caller may echo it back for readability, but only the exact derived value.
function checkDerivedBackupDir(value, anchors, payload) {
  const branch = payload ? payload.branch : null;
  if (!isSafeBranch(branch)) {
    return { error: "cannot be validated without a well-formed 'branch'" };
  }
  const backupRoot = path.join(anchors.mainRoot, BACKUP_DIR_NAME);
  const derived = path.join(backupRoot, branch);
  // Belt and braces: `isSafeBranch` already rejects every escape, but this is the
  // field that authorizes a write scope, so the containment is asserted on the
  // joined result rather than inferred from the input that produced it.
  if (!isUnder(derived, backupRoot, false)) {
    return { error: `must resolve inside <main-root>/${BACKUP_DIR_NAME}` };
  }
  if (value === undefined || value === null) return { value: derived };
  if (!isPlainString(value)) return { error: "must be a string" };
  if (!samePath(value, derived)) {
    return { error: `must be exactly <main-root>/${BACKUP_DIR_NAME}/<branch>` };
  }
  return { value: derived };
}

// `owner/repo` or a bare `repo`. The charset alone is not enough: `.` and `-`
// are legal repo-name characters, so `..` passes the pattern and `../etc` reads
// as a well-formed two-segment ref. Every segment is therefore checked against
// the relative-traversal names explicitly (CWE-22) rather than trusted to the
// charset — this value is interpolated into a `gh --repo` argument.
function checkRepoRef(value) {
  if (!isPlainString(value)) return { error: "must be a string" };
  if (!RE_REPO_REF.test(value)) return { error: "is not a well-formed repo reference" };
  if (value.split("/").some((seg) => seg === "." || seg === "..")) {
    return { error: "must not contain a '.' or '..' segment" };
  }
  return { value };
}

// The finalize scripts directory is DERIVED from the ACD anchor, never accepted:
// <acd>/skills/issue-close-finalize/scripts. Same rule as derived-backup-dir — a
// caller may echo it back for readability, but only the exact derived value, so
// a payload cannot redirect the chain at a script tree it controls.
function checkDerivedFinalizeScriptsDir(value, anchors) {
  const acd = anchors ? anchors.acd : null;
  if (!isPlainString(acd) || acd === "") {
    return { error: "cannot be validated without a resolved agents config dir" };
  }
  const derived = path.join(acd, ...FINALIZE_SCRIPTS_REL.split("/"));
  if (value === undefined || value === null) return { value: derived };
  if (!isPlainString(value)) return { error: "must be a string" };
  if (!samePath(value, derived)) {
    return { error: `must be exactly <agents-config-dir>/${FINALIZE_SCRIPTS_REL}` };
  }
  return { value: derived };
}

// One entry of a `closes_issues` list, in the shape hooks/lib/parse-closes-issues.js
// returns: { number } for a local issue, { number, repo } for a cross-repo one.
//
// The record shape, not a bare integer, is what the canonical parser produces and
// therefore what the dispatcher must accept (CPR-2). Projecting it down to numbers
// at the boundary would discard the repo half of each issue's identity, and two
// issues numbered 42 in two repositories would collapse into one `Closes #42` — a
// closing keyword GitHub then applies to whichever repo the PR happens to live in.
//
// `repo` reuses the repo-ref check, so the `..` segment rejection that protects
// `gh --repo` arguments applies here too.
function checkIssueRef(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { error: "must be an object of the form { number, repo? }" };
  }
  for (const key of Object.keys(value)) {
    if (key !== "number" && key !== "repo") {
      return { error: `has an unknown field '${key}' (only 'number' and 'repo' are allowed)`};
    }
  }
  const num = checkInt(value.number, { min: 1 });
  if (num.error) return { error: `field 'number' ${num.error}` };
  const out = { number: num.value };
  if (value.repo !== undefined && value.repo !== null) {
    const repo = checkRepoRef(value.repo);
    if (repo.error) return { error: `field 'repo' ${repo.error}` };
    out.repo = repo.value;
  }
  return { value: out };
}

// The multi-pass finalize state file. Every `path-under-plansdir` constraint
// applies, PLUS the basename must name THIS session and THIS root issue —
// residency in the plans dir alone would let one session's payload drive another
// session's chain, and the file is what carries the chain's authority between
// passes.
//
// CALLER CONTRACT: when checkField is driven directly rather than through
// validate(), call it in the order
//     session_id -> root_issue_number -> state_file_path
// so the two fields this derivation reads have already been rejected on their
// own terms if malformed. The two reads below re-validate the raw values anyway
// (they come from the untrusted payload, not from the accepted-value map), so
// the order affects WHICH error a caller sees, never whether a bad value passes.
function checkStateFileForSession(value, anchors, payload) {
  const sid = payload ? payload.session_id : null;
  const root = payload ? payload.root_issue_number : null;
  if (!isPlainString(sid) || !RE_SESSION_ID.test(sid)) {
    return { error: "cannot be validated without a well-formed 'session_id'" };
  }
  if (typeof root !== "number" || !Number.isInteger(root) || root < 1) {
    return { error: "cannot be validated without an integer 'root_issue_number'" };
  }
  const under = checkUnder(value, anchors.plansDir, "workflow plans directory", false);
  if (under.error) return under;
  const expected = `${sid}-finalize-state-${root}.json`;
  if (!sameString(path.basename(under.value), expected)) {
    return { error: `must be named '${expected}'` };
  }
  return { value: under.value };
}

function checkField(value, field, anchors, payload) {
  const type = field.type;
  if (type.startsWith("enum:")) return checkEnum(value, type);
  switch (type) {
    case "text":
      return checkText(value, field);
    case "text[]":
      return checkArray(value, field, checkText);
    case "rel-path-arg[]":
      return checkArray(value, field, (item) => checkRelPathArg(item));
    case "int":
      return checkInt(value, field);
    case "int[]":
      return checkArray(value, field, checkInt);
    case "issue-ref[]":
      return checkArray(value, field, (item) => checkIssueRef(item));
    case "bool":
      return typeof value === "boolean" ? { value } : { error: "must be a boolean" };
    case "branch":
      return isSafeBranch(value)
        ? { value }
        : { error: isPlainString(value) ? "is not a well-formed branch name" : "must be a string" };
    case "owner-repo":
      return checkPattern(value, RE_OWNER_REPO, "owner/repo identifier");
    case "repo-ref":
      return checkRepoRef(value);
    case "session-id":
      return checkPattern(value, RE_SESSION_ID, "session id");
    case "iso-date":
      return checkPattern(value, RE_ISO_DATE, "YYYY-MM-DD date");
    case "anchor-acd":
      return checkAnchored(value, anchors.acd, "resolved agents config dir");
    case "anchor-main-root":
      return checkAnchored(value, anchors.mainRoot, "resolved main-root");
    case "family-worktree":
      return checkFamilyMember(value, anchors.family);
    case "path-in-family":
      return checkUnderFamily(value, anchors.family);
    case "path-under-plansdir":
      return checkUnder(value, anchors.plansDir, "workflow plans directory", true);
    case "state-file-for-session":
      return checkStateFileForSession(value, anchors, payload);
    case "derived-backup-dir":
      return checkDerivedBackupDir(value, anchors, payload);
    case "derived-finalize-scripts-dir":
      return checkDerivedFinalizeScriptsDir(value, anchors);
    default:
      return { error: `has an unknown capability type '${type}'` };
  }
}

// Types whose value comes from the anchors plus other payload fields rather than
// from the caller. They are computed even when the field is absent, so a worker
// never has to re-derive what this module already knows how to derive — and so
// the derived value is available to fsguard as a write scope.
const DERIVED_TYPES = new Set(["derived-backup-dir", "derived-finalize-scripts-dir"]);

// Returns { ok, errors, value }. `value` is the accepted payload with defaults
// applied and every path-shaped field replaced by its canonical form, so a
// worker module never re-derives a path from raw input.
function validate(payload, entry, anchors) {
  const spec = entry && entry.payloadSpec ? entry.payloadSpec : {};
  const errors = [];
  const value = {};
  for (const key of Object.keys(spec)) {
    const field = spec[key];
    const present =
      Object.prototype.hasOwnProperty.call(payload, key) &&
      payload[key] !== undefined &&
      payload[key] !== null;
    if (!present) {
      if (DERIVED_TYPES.has(field.type)) {
        const derived = checkField(undefined, field, anchors, payload);
        if (derived.error) errors.push(`field '${key}' ${derived.error}`);
        else value[key] = derived.value;
        continue;
      }
      if (field.required === true) {
        errors.push(`missing required field '${key}'`);
      } else if (field.default !== undefined) {
        value[key] = Array.isArray(field.default) ? field.default.slice() : field.default;
      }
      continue;
    }
    const res = checkField(payload[key], field, anchors, payload);
    if (res.error) errors.push(`field '${key}' ${res.error}`);
    else value[key] = res.value;
  }
  // A field the spec does not declare is refused rather than dropped. Dropping is
  // safe for the worker — `value` only ever carries declared keys — but it is not
  // safe for the CALLER, who would see a payload accepted and assume the field
  // took effect. A misspelled `wip_mode`, or a `force_push` no worker implements,
  // must fail loudly at the boundary instead of silently meaning nothing.
  if (payload !== null && typeof payload === "object" && !Array.isArray(payload)) {
    for (const key of Object.keys(payload)) {
      if (!Object.prototype.hasOwnProperty.call(spec, key)) {
        errors.push(`unknown field '${key}' is not declared by this worker's payloadSpec`);
      }
    }
  }
  return { ok: errors.length === 0, errors, value };
}

module.exports = { validate, checkField, BACKUP_DIR_NAME };

#!/usr/bin/env node
// bin/github-issues/lib/validate-review-verdict.js — decide whether a reviewer's verdict may
// replace the survey's, and format the single-line note that records it. The reviewer is an LLM
// reading untrusted text, so its answer must survive a structural check against the survey
// artifact (every number one the survey saw, the shape its verdict claims); anything else folds to
// `invalid`, which upholds the survey verdict and forces the confirm gate (G4).
// CLI (always exit 0 — a classifier, not a gate):
//   --artifact <survey.json> --review-raw <raw.txt> → `valid|invalid`, reason, canonical review JSON
//   --format-note --from <final.json> → one comment-safe note read from the artifact (preferred)
//   --format-note --survey-verdict A --review-verdict B --status S --reason "<text>" → same, explicit
"use strict";

const fs = require("fs");
const path = require("path");
const { extractJsonObjects } = require(path.join(__dirname, "..", "..", "lib", "last-json-object.js"));

// The grammar the REVIEWER may answer in. Six verdicts, each with one shape.
const VERDICTS = ["none", "reopen", "sub-of", "make-parent", "sibling", "fix-in-session"];
// The grammar a survey ARTIFACT may be written in. `bulk-sub-of` is a Phase-4 route
// (N children under one known parent, --skip-survey) that no reviewer can express and
// no survey ever proposes — but the artifact still records it, so refusing to parse it
// would misreport a legitimate artifact as malformed.
const ARTIFACT_VERDICTS = VERDICTS.concat(["bulk-sub-of"]);
const RELATION_STATUSES = ["resolved", "unresolved"];
const ISSUE_STATES = ["open", "closed"];
// The reviewer's severity vocabulary (#2019), matched case-insensitively; skills/_shared/severity.md
// defines the levels and bin/lib/finding-rules.js (REVIEW_SEVERITIES) maps them to the notes vocabulary.
const REVIEW_SEVERITIES = ["HIGH", "MEDIUM", "LOW", "NOT-DEFECT", "NOT-A-DEFECT"];
const SCHEMA_VERSION = 3;
// SSOT for `same_fix` (does ONE fix resolve both the proposal and the issue the verdict names?):
// a pure function of the verdict, so both producers copy it rather than re-judge it. Prose twin:
// skills/_shared/issue-verdict-cascade.md (drift-checked by feat-1912-verdict-criterion-drift.sh).
// Only `reopen` and `fix-in-session` are true: every parent-attaching verdict names a meta parent
// that is never implemented against, so attaching resolves nothing (IC-C1 asks the one-fix question first).
// Different axis from the confirm gate's G1, which asks how destructive the action is.
const SAME_FIX_BY_VERDICT = {
  none: false,
  reopen: true,
  "fix-in-session": true,
  "sub-of": false,
  "bulk-sub-of": false,
  "make-parent": false,
  sibling: false,
};
const CANDIDATE_MAX = 25;
const REASON_MAX = 500;
const NOTE_REASON_MAX = 120;
// IC-C3 aggregates a CLASS of orphans; one member is not a class.
const MAKE_PARENT_MIN_CHILDREN = 2;

function readArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) args[key] = true;
    else { args[key] = next; i++; }
  }
  return args;
}

// numberSets(artifact) → { candidates (every surveyed issue), parents (sub-of may attach to),
// byNumber (candidate lookup) }. A verdict naming anything outside the sets is a hallucination.
// `parents` holds only the parent_is_meta parent of a `resolved` candidate (issue-verdict-cascade
// IC-C2): an unresolved candidate's parent is an unknown, and an unknown never widens an allowlist.
function numberSets(artifact) {
  const candidates = new Set();
  const parents = new Set();
  const byNumber = new Map();
  const list = Array.isArray(artifact.candidates) ? artifact.candidates : [];
  for (const c of list) {
    if (!c || !Number.isInteger(c.number)) continue;
    candidates.add(c.number);
    byNumber.set(c.number, c);
    if (c.relation_status === "resolved" && c.parent_is_meta === true &&
        Number.isInteger(c.parent_number)) {
      parents.add(c.parent_number);
    }
  }
  return { candidates, parents, byNumber };
}

// validateArtifact(artifact): the survey artifact is written by an LLM worker too, and
// it is the ONLY source of the allowlists above. A malformed artifact must therefore be
// rejected outright rather than allowed to narrow the allowlist silently — an empty or
// partial `candidates` array would otherwise make the review look "checked" while the
// check itself had nothing to check against. Coercion is deliberately absent: a string
// "true" or a stringified number is a defect in the producer, not a value to repair.
function validateArtifact(a) {
  if (!a || typeof a !== "object" || Array.isArray(a)) {
    return { ok: false, reason: "survey artifact is not a JSON object" };
  }
  if (a.schema_version !== SCHEMA_VERSION) {
    return { ok: false, reason: "survey artifact schema_version must be " + SCHEMA_VERSION + " (got: " + JSON.stringify(a.schema_version) + ")" };
  }
  if (typeof a.verdict !== "string" || ARTIFACT_VERDICTS.indexOf(a.verdict) === -1) {
    return { ok: false, reason: "survey artifact verdict is not a known verdict (got: " + JSON.stringify(a.verdict) + ")" };
  }
  // REQUIRED and strictly boolean, checked here so a bulk-sub-of artifact with the
  // wrong value is rejected FOR same_fix rather than swallowed by the grammar fold.
  if (typeof a.same_fix !== "boolean") {
    return { ok: false, reason: "survey artifact same_fix must be a boolean (got: " + JSON.stringify(a.same_fix) + ")" };
  }
  if (a.same_fix !== SAME_FIX_BY_VERDICT[a.verdict]) {
    return { ok: false, reason: "survey artifact same_fix must be " + JSON.stringify(SAME_FIX_BY_VERDICT[a.verdict]) + " for verdict " + a.verdict + " (got: " + JSON.stringify(a.same_fix) + ")" };
  }
  if (!Array.isArray(a.candidates)) {
    return { ok: false, reason: "survey artifact candidates must be an array" };
  }
  // The closes_issues issues ride outside the search cap (#3145), so only search candidates count.
  const searchCount = a.candidates.filter((c) => !c || c.closes_session !== true).length;
  if (searchCount > CANDIDATE_MAX) {
    return { ok: false, reason: "survey artifact carries " + searchCount + " search candidates (ceiling is " + CANDIDATE_MAX + ")" };
  }
  const seen = new Set();
  for (const c of a.candidates) {
    if (!c || typeof c !== "object" || Array.isArray(c)) {
      return { ok: false, reason: "survey artifact has a candidate that is not an object" };
    }
    if (!Number.isInteger(c.number) || c.number < 1) {
      return { ok: false, reason: "candidate number must be a positive integer (got: " + JSON.stringify(c.number) + ")" };
    }
    // Duplicates make the allowlist ambiguous: two entries, one number, different relations.
    if (seen.has(c.number)) {
      return { ok: false, reason: "survey artifact lists candidate #" + c.number + " more than once" };
    }
    seen.add(c.number);
    if (typeof c.title !== "string") return { ok: false, reason: "candidate #" + c.number + ": title must be a string" };
    // `state` is read by the cascade tie-break and by every downstream reopen
    // decision, so an unrecognised word is not a cosmetic defect.
    // `gh issue view --json state` returns the value uppercased (`OPEN` / `CLOSED`),
    // which is why the casing is normalized here before the allowlist test — the
    // typeof guard runs first, so a non-string state is rejected, never coerced.
    if (typeof c.state !== "string" || ISSUE_STATES.indexOf(c.state.toLowerCase()) === -1) {
      return { ok: false, reason: "candidate #" + c.number + ": state must be open or closed (got: " + JSON.stringify(c.state) + ")" };
    }
    if (typeof c.body !== "string") return { ok: false, reason: "candidate #" + c.number + ": body must be a string" };
    if (!Array.isArray(c.labels)) return { ok: false, reason: "candidate #" + c.number + ": labels must be an array" };
    if (RELATION_STATUSES.indexOf(c.relation_status) === -1) {
      return { ok: false, reason: "candidate #" + c.number + ": relation_status must be resolved or unresolved (got: " + JSON.stringify(c.relation_status) + ")" };
    }
    if (c.parent_number !== null && (!Number.isInteger(c.parent_number) || c.parent_number < 1)) {
      return { ok: false, reason: "candidate #" + c.number + ": parent_number must be null or a positive integer (got: " + JSON.stringify(c.parent_number) + ")" };
    }
    if (typeof c.parent_is_meta !== "boolean") return { ok: false, reason: "candidate #" + c.number + ": parent_is_meta must be a boolean" };
    if (typeof c.has_sub_issues !== "boolean") return { ok: false, reason: "candidate #" + c.number + ": has_sub_issues must be a boolean" };
    if (c.closes_session !== undefined && typeof c.closes_session !== "boolean") {
      return { ok: false, reason: "candidate #" + c.number + ": closes_session must be a boolean when present" };
    }
    // `unresolved` means the relation lookup did not answer. Relation facts that
    // arrive anyway are self-contradictory, and reading them would resurrect the
    // exact "unknown treated as known" the cascade forbids.
    if (c.relation_status === "unresolved" && (c.parent_number !== null || c.parent_is_meta === true)) {
      return { ok: false, reason: "candidate #" + c.number + ": relation_status is unresolved but parent data is present" };
    }
  }
  return { ok: true, reason: "" };
}

function isIntArray(v) {
  return Array.isArray(v) && v.every((n) => Number.isInteger(n));
}

function hasDuplicates(a) {
  return new Set(a).size !== a.length;
}

// validate(artifact, rawText) → { ok, reason, review }
function validate(artifact, rawText) {
  // The artifact is checked FIRST: without a trustworthy allowlist there is nothing to
  // validate the review against, and "review looks fine" would be a vacuous answer.
  const art = validateArtifact(artifact);
  if (!art.ok) return { ok: false, reason: art.reason };

  // A bulk route was decided before any survey ran, against a parent the caller
  // already knows. There is no five-verdict answer that could replace it, so a
  // review of one is not "disagreement" — it is a category error, and folding it to
  // invalid keeps the caller's verdict AND raises the confirm gate.
  if (artifact.verdict === "bulk-sub-of") {
    return { ok: false, reason: "survey verdict bulk-sub-of is outside the review grammar" };
  }

  // The reviewer may reason in the open — and with web search on, quoted excerpts can
  // carry braces of their own. The `FINAL_VERDICT_JSON:` sentinel is where the answer
  // starts; everything before the LAST one is working-out, not the answer. Without a
  // sentinel the whole text is scanned, as before (tolerates a model that omits it).
  const SENTINEL = "FINAL_VERDICT_JSON:";
  const scanText = typeof rawText === "string" && rawText.lastIndexOf(SENTINEL) !== -1
    ? rawText.slice(rawText.lastIndexOf(SENTINEL) + SENTINEL.length)
    : rawText;

  const objs = extractJsonObjects(scanText);
  // Cardinality is checked before content: two answers mean the reviewer never settled
  // on one, and "take the last" would silently pick for it.
  if (objs.length === 0) {
    // The two zero-object cases are folded to the same outcome but kept separable in
    // the reason: "no JSON at all" is a reviewer that answered in prose, while a
    // dangling `{` is a truncated or malformed answer — different things to chase.
    return {
      ok: false,
      reason: scanText && scanText.indexOf("{") !== -1
        ? "review output contained an incomplete or unparseable JSON object"
        : "review output contained no parseable JSON object",
    };
  }
  if (objs.length > 1) return { ok: false, reason: "review output contained " + objs.length + " JSON objects (expected exactly 1)" };

  const r = objs[0];
  const verdict = r.verdict;
  if (typeof verdict !== "string" || VERDICTS.indexOf(verdict) === -1) {
    return { ok: false, reason: "unknown verdict: " + JSON.stringify(verdict) };
  }
  if (typeof r.reason !== "string" || r.reason.trim().length === 0) {
    return { ok: false, reason: "reason is missing or empty" };
  }
  if (r.reason.length > REASON_MAX) {
    return { ok: false, reason: "reason exceeds " + REASON_MAX + " characters" };
  }
  // REQUIRED, and strictly boolean. This is the confirm gate's G3 input: a missing or
  // stringified value must fold the whole review to `invalid` (→ G4, confirm) rather
  // than be coerced — `"false"` is truthy and would flip the gate the wrong way.
  if (typeof r.worth_filing !== "boolean") {
    return { ok: false, reason: "worth_filing must be a boolean" };
  }
  // Same treatment for same_fix: required, strictly boolean, no coercion. The
  // verdict-consistency cross-check runs after the per-verdict shape switch below.
  if (typeof r.same_fix !== "boolean") {
    return { ok: false, reason: "same_fix must be a boolean" };
  }

  const target = r.target === undefined ? null : r.target;
  const children = r.children === undefined ? [] : r.children;
  const related = r.related === undefined ? [] : r.related;
  if (!isIntArray(children)) return { ok: false, reason: "children must be an array of integers" };
  if (!isIntArray(related)) return { ok: false, reason: "related must be an array of integers" };
  if (target !== null && !Number.isInteger(target)) return { ok: false, reason: "target must be an integer or null" };

  const { candidates, parents, byNumber } = numberSets(artifact);
  const inCand = (n) => candidates.has(n);
  const inCandOrParent = (n) => candidates.has(n) || parents.has(n);
  // IC-C3: only a candidate whose relations were actually resolved AND that has no
  // parent may be aggregated under a new one. Re-parenting an issue that already
  // has a parent is a different (destructive) operation the cascade never sanctions.
  const isOrphan = (n) => {
    const c = byNumber.get(n);
    return !!c && c.relation_status === "resolved" && c.parent_number === null;
  };

  // Per-verdict shape. Each verdict owns exactly one non-empty number field, so an
  // extra one is not "harmless extra data" — it is a verdict the caller cannot act on.
  switch (verdict) {
    case "none":
      if (target !== null) return { ok: false, reason: "none: target must be null" };
      if (children.length || related.length) return { ok: false, reason: "none: children and related must be empty" };
      break;
    case "reopen":
      // Reopen acts ON a candidate; a parent is not something the survey proposed to reopen.
      if (!Number.isInteger(target) || !inCand(target)) {
        return { ok: false, reason: "reopen: target must be one of the surveyed candidates" };
      }
      if (children.length || related.length) return { ok: false, reason: "reopen: children and related must be empty" };
      break;
    case "sub-of":
      // sub-of may name a parent the survey resolved, because attaching under an
      // existing parent is exactly what the relation data is for.
      if (!Number.isInteger(target) || !inCandOrParent(target)) {
        return { ok: false, reason: "sub-of: target must be a surveyed candidate or one of their parents" };
      }
      if (children.length || related.length) return { ok: false, reason: "sub-of: children and related must be empty" };
      break;
    case "make-parent":
      if (target !== null) return { ok: false, reason: "make-parent: target must be null" };
      if (children.length < MAKE_PARENT_MIN_CHILDREN) {
        return { ok: false, reason: "make-parent: children must name at least " + MAKE_PARENT_MIN_CHILDREN + " candidates" };
      }
      if (hasDuplicates(children)) return { ok: false, reason: "make-parent: children contains duplicates" };
      if (!children.every(inCand)) return { ok: false, reason: "make-parent: children must all be surveyed candidates" };
      if (!children.every(isOrphan)) {
        return { ok: false, reason: "make-parent: children must all be resolved candidates with no parent" };
      }
      if (related.length) return { ok: false, reason: "make-parent: related must be empty" };
      break;
    case "sibling":
      if (target !== null) return { ok: false, reason: "sibling: target must be null" };
      if (related.length === 0) return { ok: false, reason: "sibling: related must be non-empty" };
      if (hasDuplicates(related)) return { ok: false, reason: "sibling: related contains duplicates" };
      if (!related.every(inCand)) return { ok: false, reason: "sibling: related must all be surveyed candidates" };
      if (children.length) return { ok: false, reason: "sibling: children must be empty" };
      break;
    case "fix-in-session":
      // Hands the proposal back to the session whose PR closes the target issue.
      if (!Number.isInteger(target) || !byNumber.has(target) || byNumber.get(target).closes_session !== true) {
        return { ok: false, reason: "fix-in-session: target must be a surveyed candidate with closes_session true" };
      }
      if (children.length || related.length) return { ok: false, reason: "fix-in-session: children and related must be empty" };
      break;
    default:
      return { ok: false, reason: "unknown verdict" };
  }

  // A reviewer whose verdict and whose "one fix covers both" answer disagree has
  // drifted from the cascade, whatever else its shape looks like.
  if (r.same_fix !== SAME_FIX_BY_VERDICT[verdict]) {
    return { ok: false, reason: "same_fix must be " + JSON.stringify(SAME_FIX_BY_VERDICT[verdict]) + " for verdict " + verdict + " (got: " + JSON.stringify(r.same_fix) + ")" };
  }

  const review = { verdict, target, children, related, reason: r.reason, worth_filing: r.worth_filing, same_fix: r.same_fix };
  // #2019: optional. An out-of-vocabulary value is dropped, never folded to invalid — the
  // filing gate (bin/finding-filing-gate) reads a missing severity as "reviewer unavailable".
  if (typeof r.severity === "string" && REVIEW_SEVERITIES.indexOf(r.severity.toUpperCase()) !== -1) review.severity = r.severity;
  return { ok: true, reason: "", review };
}

// formatNote(...): the one line that goes into a GitHub comment. It is assembled from
// a FIXED template with only sanitized fragments interpolated — the reviewer's reason
// is untrusted text, so it is flattened to one line, stripped of HTML comment markers
// (which would otherwise let it close or open a marker comment in the body) and cut to
// a length that keeps the note readable.
// A SINGLE pass is not enough: removing `<!--` from `<!<!--- ->` leaves a `<!--`
// that was not there before, so one pass hands back exactly the marker it was asked
// to remove. Strip to a fixed point instead — each pass strictly shortens the string,
// so the loop always terminates.
function stripCommentMarkers(s) {
  let out = s;
  let prev;
  do {
    prev = out;
    out = out.replace(/<!--/g, "").replace(/-->/g, "");
  } while (out !== prev);
  return out;
}

function formatNote(surveyVerdict, reviewVerdict, status, reason) {
  const clean = (v) =>
    stripCommentMarkers(String(v === undefined || v === null ? "" : v))
      .replace(/[\r\n\t]+/g, " ")
      .replace(/\s{2,}/g, " ")
      .trim();
  let r = clean(reason);
  // Truncation is inclusive of the ellipsis, so the fragment never exceeds the budget
  // and a cut is always visible to the reader.
  if (r.length > NOTE_REASON_MAX) r = r.slice(0, NOTE_REASON_MAX - 1) + "…";
  return (
    "verdict review: survey verdict " + clean(surveyVerdict) +
    " -> review verdict " + clean(reviewVerdict) +
    " (" + clean(status) + ")" +
    (r ? " — " + r : "")
  );
}

module.exports = {
  validate, validateArtifact, formatNote, stripCommentMarkers,
  VERDICTS, ARTIFACT_VERDICTS, RELATION_STATUSES, ISSUE_STATES, REVIEW_SEVERITIES,
  SCHEMA_VERSION, SAME_FIX_BY_VERDICT,
  CANDIDATE_MAX, REASON_MAX, NOTE_REASON_MAX, MAKE_PARENT_MIN_CHILDREN,
};

if (require.main === module) {
  const args = readArgs(process.argv.slice(2));

  if (args["format-note"]) {
    if (args.from !== undefined && args.from !== true) {
      // The note is a public record of what the two graders concluded. Reading it out of
      // the artifact keeps it a record: the model that dispatches the reopen cannot
      // paraphrase, shorten or invent a reason on the way past. An unreadable artifact
      // therefore yields a note that SAYS so — never a plausible-looking blank one.
      let final = null;
      try {
        final = JSON.parse(fs.readFileSync(String(args.from), "utf8"));
      } catch (_e) {
        final = null;
      }
      if (!final || typeof final !== "object") {
        process.stdout.write("verdict review: the final verdict artifact could not be read\n");
        process.exit(0);
      }
      const review = final.review && typeof final.review === "object" ? final.review : {};
      const survey = final.survey && typeof final.survey === "object" ? final.survey : {};
      process.stdout.write(
        formatNote(
          survey.verdict,
          review.verdict === undefined || review.verdict === null ? final.verdict : review.verdict,
          review.status,
          review.reason
        ) + "\n"
      );
      process.exit(0);
    }
    process.stdout.write(
      formatNote(args["survey-verdict"], args["review-verdict"], args.status, args.reason) + "\n"
    );
    process.exit(0);
  }

  let artifact = null;
  let raw = "";
  try {
    artifact = JSON.parse(fs.readFileSync(String(args.artifact), "utf8"));
  } catch (_e) {
    process.stdout.write("invalid\nsurvey artifact is missing or unparseable\n");
    process.exit(0);
  }
  try {
    raw = fs.readFileSync(String(args["review-raw"]), "utf8");
  } catch (_e) {
    process.stdout.write("invalid\nreview output is missing or unreadable\n");
    process.exit(0);
  }

  let result;
  try {
    result = validate(artifact, raw);
  } catch (e) {
    result = { ok: false, reason: "validator error: " + (e && e.message ? e.message : String(e)) };
  }
  if (!result.ok) {
    process.stdout.write("invalid\n" + result.reason + "\n");
    process.exit(0);
  }
  process.stdout.write("valid\n\n" + JSON.stringify(result.review) + "\n");
}

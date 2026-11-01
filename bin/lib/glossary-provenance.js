"use strict";
// bin/lib/glossary-provenance.js — glossary provenance of #2529 S1: the per-category term sets,
// their before/after operations, the match against the approved intent `## Glossary` rows and
// the row checks glossary-promote runs before applying. normalizeDefinition is the only
// definition normalization; this source is one of the RULE_MODULES of the glossary fingerprint.

const fs = require("fs");
const crypto = require("crypto");
const { normalizeTerm } = require("../../hooks/lib/glossary-term");
const { parseIntentGlossary, checkIntentGlossary } = require("../../hooks/lib/intent-glossary");
const { parseGlossaryPath } = require("./glossary-format/files");
const { parseGlossaryFile, entryFields } = require("./glossary-format/entries");

const CATEGORIES = ["user", "internal"];
const other = (category) => (category === "user" ? "internal" : "user");
const lower = (s) => String(s == null ? "" : s).toLowerCase();

function normalizeDefinition(s) {
  return String(s == null ? "" : s).replace(/\s+/g, " ").trim();
}

// fieldsKey({ identifiers, homographs }) -> the order-free comparison key of the Identifier /
// Homographs fields (#2763); "" when both are empty.
function fieldsKey(f) {
  const list = (v) => (Array.isArray(v) ? v.map(String).sort() : []);
  const ids = list(f && f.identifiers);
  const homs = list(f && f.homographs);
  return ids.length === 0 && homs.length === 0 ? "" : JSON.stringify([ids, homs]);
}
const declaresFields = (r) => Array.isArray(r.identifiers) || Array.isArray(r.homographs);
const fieldsOf = (set, key) => (set.fields && set.fields.get(key)) || "";

let legacyCategoryOf = () => null;

function termSet() {
  const set = Object.defineProperty(new Map(), "headings", { value: new Map() });
  return Object.defineProperty(set, "fields", { value: new Map() });
}

// headingOf(set, key) -> the heading exactly as written, or the lowercased key for a plain Map.
const headingOf = (set, key) => (set.headings && set.headings.get(key)) || key;

// readTermSets(readFile, paths, opts) -> { user: Map, internal: Map } of lowercased term ->
// normalized Definition; each Map's `headings` maps the lowercased term to its exact heading.
// readFile(path) returns the text (null / undefined = absent).
// Both sides read alike: a pre-move glossary path counts only for a category with no
// docs/glossary/ path in `paths`, the rule listMainGlossaryFiles applies to the readers.
function readTermSets(readFile, paths) {
  const sets = { user: termSet(), internal: termSet() };
  const moved = new Set((paths || []).map(parseGlossaryPath).filter(Boolean).map((x) => x.category));
  for (const p of paths || []) {
    const parsed = parseGlossaryPath(p);
    const legacy = parsed ? null : legacyCategoryOf(p);
    const category = parsed ? parsed.category : (legacy && !moved.has(legacy) ? legacy : null);
    if (!category) continue;
    const text = readFile(p);
    if (typeof text !== "string") continue;
    for (const e of parseGlossaryFile(text).entries) {
      const def = e.bullets.find((b) => b.key === "Definition");
      sets[category].set(lower(e.term), normalizeDefinition(def ? def.value : ""));
      sets[category].headings.set(lower(e.term), e.term);
      sets[category].fields.set(lower(e.term), fieldsKey(entryFields(e)));
    }
  }
  return sets;
}

// computeOperations(base, next) -> [{ term, category, operation, definition, fields,
// fieldsChanged }], sorted. A case-only heading change is a delete of the old heading + an add of
// the new one; a change of the Definition or of the fields is a redefine.
function computeOperations(base, next) {
  const ops = [];
  const del = (term, category) => ({ term, category, operation: "delete", definition: "", fields: "", fieldsChanged: false });
  for (const category of CATEGORIES) {
    const b = base[category];
    const n = next[category];
    for (const [key, def] of n) {
      const term = headingOf(n, key);
      const fields = fieldsOf(n, key);
      const add = { term, category, operation: "add", definition: def, fields, fieldsChanged: fields !== "" };
      if (!b.has(key)) ops.push(add);
      else if (headingOf(b, key) !== term) ops.push(del(headingOf(b, key), category), add);
      else if (b.get(key) !== def || fieldsOf(b, key) !== fields) {
        ops.push({ term, category, operation: "redefine", definition: def, fields, fieldsChanged: fieldsOf(b, key) !== fields });
      }
    }
    for (const key of b.keys()) {
      if (!n.has(key)) ops.push(del(headingOf(b, key), category));
    }
  }
  const key = (o) => `${o.term}\u0000${o.category}\u0000${o.operation}`;
  return ops.sort((x, y) => (key(x) < key(y) ? -1 : key(x) > key(y) ? 1 : 0));
}

// The term is taken as written: computeOperations is case-sensitive, so `Alpha -> alpha` and
// `alpha -> Alpha` are different operation sets and must not share a fingerprint (or a grant).
// The fields join only an op that changes them, so an op without a fields change keeps its fingerprint.
function opsFingerprint(ops) {
  const lines = (ops || []).map((o) => {
    const parts = [String(o.term), o.category, o.operation, normalizeDefinition(o.definition)];
    if (o.fieldsChanged) parts.push("fields:" + (o.fields || ""));
    return parts.join("\u0000");
  }).sort();
  return crypto.createHash("sha256").update(lines.join("\n")).digest("hex");
}

function grantCovers(grants, op) {
  const norm = normalizeTerm(op.term);
  return (grants || []).some((g) => g && g.norm === norm && g.operation === op.operation && g.category === op.category);
}

function reasonFor(op, rows) {
  const same = rows.filter((r) => r.term === op.term && r.operation === op.operation);
  const exact = same.find((r) => r.category === op.category);
  if (exact) {
    if (op.operation === "delete") return null;
    if (normalizeDefinition(exact.definition) !== normalizeDefinition(op.definition)) return "definition-mismatch";
    // A V3 row states the fields; a V1 / V2 row cannot, so it cannot approve a fields change.
    if (declaresFields(exact)) return fieldsKey(exact) === (op.fields || "") ? null : "fields-mismatch";
    return op.fieldsChanged ? "fields-unrecorded" : null;
  }
  if (same.some((r) => r.category === "session")) return "session-term";
  if (same.length > 0) return "category-mismatch";
  return "not-in-intent";
}

// matchOperations(ops, intentRows, grants) -> { unmatched: [{ term, category, operation, reason }] }.
// The caller checks the grant fingerprints first.
function matchOperations(ops, intentRows, grants) {
  const rows = intentRows || [];
  const unmatched = [];
  for (const op of ops || []) {
    if (grantCovers(grants, op)) continue;
    const reason = reasonFor(op, rows);
    if (reason) unmatched.push({ term: op.term, category: op.category, operation: op.operation, reason });
  }
  return { unmatched };
}

// Pairs a delete and an add only when the terms match as written; a case-only pair is a
// heading rename (see computeOperations), mirroring useRedefine in hooks/lib/intent-glossary.js.
function useRedefinePairs(rows) {
  const key = (r) => r.term + "\u0000" + r.category;
  const dels = new Set(rows.filter((r) => r.operation === "delete").map(key));
  const adds = new Set(rows.filter((r) => r.operation === "add").map(key));
  return new Set([...dels].filter((k) => adds.has(k)));
}

// checkIntentRows(termSets, rows) -> [{ term, category, operation, reason }]: delete rows first
// (a valid one joins `removed`), then add / redefine against the sets with `removed` applied.
function checkIntentRows(termSets, rows) {
  const out = [];
  const flag = (r, reason) => out.push({ term: r.term, category: r.category, operation: r.operation, reason });
  const live = (rows || []).filter((r) => CATEGORIES.includes(r.category));
  const pairs = useRedefinePairs(live);
  const removed = new Set();
  const rest = [];
  for (const r of live) {
    const t = lower(r.term);
    if (pairs.has(r.term + "\u0000" + r.category)) { flag(r, "use-redefine"); continue; }
    if (r.operation !== "delete") { rest.push(r); continue; }
    if (termSets[r.category].has(t)) removed.add(t + "\u0000" + r.category);
    else flag(r, termSets[other(r.category)].has(t) ? "category-mismatch" : "delete-absent");
  }
  for (const r of rest) {
    const t = lower(r.term);
    const here = termSets[r.category];
    const there = termSets[other(r.category)];
    if (r.operation === "add") {
      if (!here.has(t) && there.has(t) && !removed.has(t + "\u0000" + other(r.category))) flag(r, "category-conflict");
    } else if (r.operation === "redefine") {
      if (here.has(t)) {
        const sameFields = !declaresFields(r) || fieldsKey(r) === fieldsOf(here, t);
        if (here.get(t) === normalizeDefinition(r.definition) && sameFields) flag(r, "redefine-no-change");
      } else flag(r, there.has(t) ? "category-mismatch" : "redefine-absent");
    }
  }
  return out;
}

// resolveProvenanceSession(argSid) -> { sid, source: "explicit" | "env" | "none" }.
function resolveProvenanceSession(argSid) {
  const { resolveSessionId } = require("../../hooks/workflow-state/session-id");
  const sid = resolveSessionId({ sessionIdFromInput: argSid });
  if (!sid) return { sid: null, source: "none" };
  return { sid, source: sid === argSid ? "explicit" : "env" };
}

function approvalOf(sid) {
  try {
    const { readState } = require("../../hooks/workflow-state/state-io");
    const { readPlanApproval } = require("../../hooks/workflow-state/completion-approval");
    return readPlanApproval(readState(sid), "clarify_intent");
  } catch (_) {
    return null;
  }
}

// loadIntentGlossary(sid) -> { ok: true, rows, approvalSha } | { ok: false, case, reason, detail }.
// One read of <first_session_id>-intent.md (#2748); the approval sha and the parse come from the
// same bytes. The approval record is the current session's, bound to first_session_id.
function loadIntentGlossary(sid) {
  const fail = (c, reason, detail) => ({ ok: false, case: c, reason, detail: detail || null });
  let buf;
  let firstSid;
  try {
    const owner = require("../../hooks/workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, "intent");
    firstSid = owner.ownerSid;
    buf = fs.readFileSync(owner.path);
  } catch (e) {
    return fail("A", "intent-missing", e && e.code ? e.code : String(e && e.message));
  }
  const rec = approvalOf(sid);
  if (!rec || rec.source !== "confirm-sentinel" || typeof rec.artifact_sha256 !== "string" ||
    rec.artifact_sha256 === "" || rec.artifact_session_id !== firstSid) {
    return fail("P", "intent-unapproved");
  }
  const { shaOfArtifactBuffer } = require("../../hooks/workflow-state/completion-approval");
  const sha = shaOfArtifactBuffer(Buffer.isBuffer(buf) ? buf : Buffer.from(String(buf), "utf8"), "clarify_intent");
  if (sha !== rec.artifact_sha256) return fail("P", "intent-modified");
  const text = Buffer.isBuffer(buf) ? buf.toString("utf8") : String(buf);
  const violations = checkIntentGlossary(text);
  const parsed = parseIntentGlossary(text);
  if (parsed.glossaryLines.length === 0 || violations.length > 0) {
    return fail("C", "intent-unreadable", violations.map((v) => `${v.lineNumber}: ${v.reason}`));
  }
  return { ok: true, rows: parsed.rows, approvalSha: sha };
}

module.exports = {
  normalizeDefinition, readTermSets, computeOperations, opsFingerprint, matchOperations,
  checkIntentRows, resolveProvenanceSession, loadIntentGlossary,
};

// --- BEGIN temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration added 2026-10-17 ---
// deletion-condition: remove once origin/main has no docs/glossary-user.md / docs/glossary-internal.md and no worktree in "git worktree list" still has them, together with the matching blocks in bin/lib/glossary-format/files.js (which lists the others) and tests/bin/feat-2529-glossary-legacy-read.sh
// Read on both sides: the commit that moves the files diffs as zero operations, and so does
// an untouched old-layout file while another glossary path is staged.
legacyCategoryOf = (p) => {
  const { LEGACY_NAME_RE } = require("./glossary-format/files");
  const m = LEGACY_NAME_RE.exec(String(p).replace(/\\/g, "/"));
  return m && !(m[2] !== undefined && m[2] > m[3]) ? m[1] : null;
};
// Index side: readTermSets reads no old-layout path, so a staged add / modify of one would carry
// terms no operation shows. legacyIndexBlocks(stagedNonDeletionPaths) -> the refusal lines.
module.exports.legacyIndexBlocks = (paths) => require("./glossary-format/files").legacyLayoutBlocks(paths);
// --- END temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration ---

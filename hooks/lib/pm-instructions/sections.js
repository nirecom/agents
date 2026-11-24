"use strict";
// Section contract of the PM supervisor duties SSOT md (#3019): recipient x timing -> H2 / H3.
// The keys live only in CONTRACT, never derived from the heading text, so a reworded heading
// cannot silently change a key. PM_INSTRUCTIONS_MD_PATH (absolute) replaces the md location.

const fs = require("fs");
const path = require("path");
const { stripComments } = require("../user-instructions");

const MD_REL = "skills/_shared/pm-supervisor-duties.md";
const DEFAULT_MD = path.join(__dirname, "..", "..", "..", ...MD_REL.split("/"));
const MD_ENV = "PM_INSTRUCTIONS_MD_PATH";

const CONTRACT = Object.freeze([
  { recipient: "pm", timing: "session-start", h2: "PM session", h3: "Session start" },
  { recipient: "pml2", timing: "session-start", h2: "PML2 delta", h3: "Session start" },
  { recipient: "workflow", timing: "issue-start", h2: "Workflow session", h3: "Issue start" },
  { recipient: "workflow", timing: "before-companions", h2: "Workflow session", h3: "Before companion presentation" },
  { recipient: "workflow", timing: "before-plan-confirm", h2: "Workflow session", h3: "Before plan confirmation sentinel" },
  { recipient: "workflow", timing: "before-user-verification", h2: "Workflow session", h3: "Before user verification" },
  { recipient: "workflow", timing: "after-final-report", h2: "Workflow session", h3: "After Final Report" },
]);

// session-start is a bundle per recipient; pml2 joins no bundle until #3056 enables it.
// The two review timings leave the workflow bundle (#3144): `## Review request` RR-1 fetches each at its checkpoint.
const BUNDLES = Object.freeze({
  pm: ["session-start"],
  workflow: ["issue-start"],
});

const TIMINGS = Object.freeze(["session-start", ...new Set(CONTRACT.filter((c) => c.timing !== "session-start").map((c) => c.timing))]);

class SectionError extends Error {
  constructor(reason) { super(reason); this.reason = reason; }
}

function mdPath() {
  const p = process.env[MD_ENV];
  return p ? p : DEFAULT_MD;
}

// parseSections(text) -> Map<"h2/h3", body> of the comment-free text.
function parseSections(text) {
  const out = new Map();
  let h2 = null;
  let key = null;
  for (const line of stripComments(text).split(/\r?\n/)) {
    let m = /^## (.+?)\s*$/.exec(line);
    if (m) { h2 = m[1]; key = null; continue; }
    m = /^### (.+?)\s*$/.exec(line);
    if (m) { key = h2 ? `${h2}/${m[1]}` : null; if (key) out.set(key, []); continue; }
    if (/^# /.test(line)) { h2 = null; key = null; continue; }
    if (key) out.get(key).push(line);
  }
  return new Map([...out].map(([k, v]) => [k, v.join("\n").trim()]));
}

// loadSections() -> Map<"recipient/timing", {entry, body}>; throws SectionError (md_unreadable | heading_missing).
function loadSections() {
  let text;
  try { text = fs.readFileSync(mdPath(), "utf8"); } catch (_) { throw new SectionError("md_unreadable"); }
  const parsed = parseSections(text);
  const out = new Map();
  for (const c of CONTRACT) {
    const k = `${c.h2}/${c.h3}`;
    if (!parsed.has(k)) throw new SectionError(`heading_missing: ${c.h2} / ${c.h3}`);
    out.set(`${c.recipient}/${c.timing}`, { entry: c, body: parsed.get(k) });
  }
  return out;
}

// sectionsFor(recipient, timing, loaded) -> [{entry, body}] in contract order; [] when none apply.
function sectionsFor(recipient, timing, loaded) {
  const keys = timing === "session-start" ? (BUNDLES[recipient] || []) : [timing];
  return keys.map((t) => loaded.get(`${recipient}/${t}`)).filter(Boolean);
}

module.exports = { MD_REL, MD_ENV, CONTRACT, BUNDLES, TIMINGS, SectionError, mdPath, parseSections, loadSections, sectionsFor };

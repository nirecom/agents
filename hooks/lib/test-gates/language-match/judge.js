"use strict";
// Whether a test is written in the language of the code it tests (#2507 D7; ports tlm_judge of
// bin/lib/test-language-match.sh). judge(file, match, head, { root }) -> { rc, lines }: rc 0 none,
// 1 lines printed, 2 the code-language table unreadable, 3 the test language not supported.
// file / head are paths or in-memory files; head null for a new file; root resolves targets.

const R = require("../registry");
const S = require("../source");
const { tokenLanguage } = require("../code-language");
const { headerTokens } = require("./exception");
const { cases, pair } = require("./pairing");
const { caseAddition } = require("./case-addition");

// A test entrypoint the case-marker gate also judges: exactly tests/<category>/<name>, an entry
// with a caseMarkerReader, and its helperLibrary present under root.
function isEntrypoint(match, entry, root) {
  const m = /^tests\/([^/]*)\/([^/]+)$/.exec(match);
  if (!m || !R.CATEGORIES.includes(m[1])) return false;
  const hl = R.fieldValue(entry, "helperLibrary.path");
  if (!R.fieldValue(entry, "caseMarkerReader.file") || !hl) return false;
  return S.isFile(`${root || "."}/${hl}`);
}

const dropDot = (t) => (t.startsWith("./") ? t.slice(2) : t);

function judge(file, match, head, opts = {}) {
  const root = opts.root || ".";
  let m;
  try {
    R.reg();
    m = R.match(match);
  } catch {
    return { rc: 2, lines: [] };
  }
  if (!m || m.status !== "supported") return { rc: 3, lines: [] };
  const testId = m.id;
  const lines = [];
  const seen = new Set();
  // mismatch(target) -> { lang, shape } when the target's code language is known and not testId.
  const mismatch = (target) => {
    const id = tokenLanguage(target, { root });
    if (!id || id === testId) return null;
    return { lang: id, shape: R.fieldValue(R.entryById(id), "newFileNameShape") || "-" };
  };
  const report = (line, target, mm) => {
    if (seen.has(target)) return;
    seen.add(target);
    lines.push(`HIGH: ${match}${line ? ` line ${line}` : ""}: test language ${testId} does not match code language ${mm.lang} of ${target} (new file shape: ${mm.shape}) code=TEST_LANGUAGE_MISMATCH`);
  };
  const judgeTarget = (line, target) => {
    const mm = mismatch(target);
    if (mm) report(line, target, mm);
  };
  const addition = (h) => {
    const l = caseAddition(h, file, match);
    if (l) lines.push(l);
  };
  const entry = isEntrypoint(match, m.entry, root);

  const known = new Set(head ? headerTokens(head, match, "tests").map(dropDot) : []);
  const tokens = headerTokens(file, match, "tests");
  for (const tok of tokens) if (!known.has(dropDot(tok))) judgeTarget("", tok);
  const nTok = tokens.length;

  if (!head) {
    const c = cases(file, match);
    if (entry && c.state !== "conforming" && nTok !== 1) addition(null);
    for (const k of c.cases) judgeTarget(k.line, k.target);
  } else {
    const paired = pair(head, file, match);
    if (paired) {
      for (const k of paired) {
        const mm = mismatch(k.target);
        if (!mm) continue;
        if (k.kind === "paired" && mismatch(k.headTarget)) continue;
        report(k.line, k.target, mm);
      }
    } else if (!migration(head, file, match, judgeTarget) && entry && nTok !== 1) addition(head);
  }
  return { rc: lines.length ? 1 : 0, lines };
}

// Markers put into a HEAD that was not conforming: false unless that is the shape. Otherwise every
// work case target is judged, except a key HEAD's Tests: header already held.
function migration(head, file, match, judgeTarget) {
  if (cases(head, match).state === "conforming") return false;
  const w = cases(file, match);
  if (w.state !== "conforming") return false;
  const known = new Set(headerTokens(head, match, "tests").map(dropDot));
  for (const k of w.cases) if (!known.has(k.target)) judgeTarget(k.line, k.target);
  return true;
}

module.exports = { judge, isEntrypoint };

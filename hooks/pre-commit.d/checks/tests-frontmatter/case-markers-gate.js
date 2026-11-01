"use strict";
// Case-marker gate of the tests-frontmatter check (#2507 D7; ports _precommit_check_tests_case_markers
// of hooks/lib/precommit-tests-frontmatter.sh). The staged blob of every new (no parent has it, #2812) case-marker
// entrypoint, in a repo whose index carries its entry's helperLibrary, and of every new reader-less
// one, is judged in memory. A checker infra error fails open with a stderr diagnostic.
// placedTargets is the same selection without the "new" filter; the test-runner gate uses it (#2865).

const R = require("../../../lib/test-gates/registry");
const S = require("../../../lib/test-gates/source");
const placement = require("../../../lib/test-gates/placement");
const { judge } = require("../../../lib/test-gates/case-markers");
const { git } = require("../../lib/support");
const { out, err } = require("../../output");
const { parentsOf } = require("./parents");

const ACMR = new Set(["A", "C", "M", "R"]);

// placedTargets -> [{ rel, entry }] of every staged (ACMR) target, or null when the registry is unreadable.
function placedTargets({ context, snapshot, files }) {
  const inIndex = new Map();
  const indexHas = (p) => {
    if (!inIndex.has(p)) inIndex.set(p, git(context.repoTop, ["cat-file", "-e", `:${p}`], { env: context.env }).ok);
    return inIndex.get(p);
  };
  const rels = files.filter((f) => f.startsWith("tests/") && ACMR.has(snapshot.status(f)));
  if (rels.length && !R.tryReg()) return null;
  const targets = [];
  for (const rel of rels) {
    const m = placement.placedMatch(rel);
    if (!m) continue;
    if (placement.isCaseMarkerTarget(rel)) {
      const hl = R.fieldValue(m.entry, "helperLibrary.path");
      if (!hl || !indexHas(hl)) continue;
    } else if (!placement.isReaderlessCaseMarkerTarget(rel)) continue;
    targets.asked = true;
    targets.push({ rel, entry: m.entry });
  }
  return targets;
}

// newTargets -> the placedTargets no parent has (#2812), or null when the registry is unreadable.
function newTargets(args) {
  const placed = placedTargets(args);
  if (!placed) return null;
  const targets = placed.filter(({ rel }) => parentsOf(args).record(rel).in_parent !== 1);
  if (placed.asked) targets.asked = true;
  return targets;
}

function addOnce(list, hint) {
  if (hint && !list.includes(hint)) list.push(hint);
}

function gate({ context, snapshot, files }) {
  const targets = newTargets({ context, snapshot, files });
  if (!targets) return { block: false, messages: [err("pre-commit: test language registry not readable — case-marker check skipped (commit continues)")] };
  const messages = targets.asked ? parentsOf({ context, snapshot, files }).note() : [];
  const high = [];
  const missing = [];
  const malformed = [];
  for (const { rel, entry } of targets) {
    const blob = snapshot.content(rel);
    if (!blob) {
      messages.push(err(`pre-commit: cannot read staged blob for ${rel} — case-marker check skipped for it`));
      continue;
    }
    const j = judge(S.mem(rel, blob), rel);
    const lines = j.lines.map((l) => l.text);
    const rc = j.high ? 1 : j.readerFailed ? 2 : 0;
    if (rc === 1) {
      for (const line of lines) {
        if (/^HIGH:.*code=MISSING_CASE_MARKERS/.test(line)) {
          high.push(line);
          const h = R.fieldValue(entry, "diagnostics.markerMissingHint") || R.fieldValue(entry, "diagnostics.markerWrapHint");
          if (h) addOnce(missing, `${h}.`);
        } else if (/^HIGH:.*code=MALFORMED_CASE_MARKER/.test(line)) {
          high.push(line);
          const d = R.fieldValue(entry, "diagnostics.markerDoc") || R.fieldValue(entry, "notationDoc");
          if (d) addOnce(malformed, `Fix marker placement — see ${d}.`);
        } else if (line.startsWith("HIGH:")) high.push(line);
        else if (/^WARN:.*code=/.test(line)) messages.push(err(line));
      }
    } else if (rc === 0) {
      messages.push(...lines.map(err));
    } else {
      messages.push(err(`pre-commit: check-case-markers rc=${rc} for ${rel} — case-marker check incomplete (commit continues)`));
      messages.push(...lines.map(err));
    }
  }
  if (high.length === 0) return { block: false, messages };
  return { block: true, messages: [...messages, ...high.map(out), out(""), out("Commit blocked: new test file(s) fail the case-marker gate."), ...missing.map(out), ...malformed.map(out)] };
}

module.exports = { gate, newTargets, placedTargets };

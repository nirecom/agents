"use strict";
// One file's required-runner verdict for a test entrypoint, new or existing (#2863, #2865). The entry's
// newEntrypointRunner names the caseEmbedRules skip-reason word that means "does not run under the
// required runner"; the op itself decides, so no language rule lives here.
// judge(file, name) -> { lines: [{ err, text }], high, infra }: file is a path or an in-memory file
// (source.js), name picks the entry. An err line belongs on stderr, the rest on stdout.

const R = require("./registry");
const P = require("./parts");

// runnerHint(entry) — the one hint line both layers print, or null when the entry declares no runner.
function runnerHint(entry) {
  const n = entry && entry.newEntrypointRunner;
  if (!n || !n.hint) return null;
  const doc = R.fieldValue(entry, "diagnostics.markerDoc") || R.fieldValue(entry, "notationDoc");
  return `${n.hint}${doc ? ` — see ${doc}` : ""}.`;
}

function judge(file, name) {
  const res = { lines: [], high: false, infra: false };
  let m;
  try {
    m = R.match(name);
  } catch {
    return res;
  }
  const want = m && m.status === "supported" && m.entry.newEntrypointRunner;
  if (!want) return res;
  const r = P.embed(m.entry, "skip-reason", file);
  if (r.rc === 0) {
    const words = String(r.stdout).split(/\r?\n/).map((w) => w.trim());
    if (words.includes(want.rejectSkipReason)) {
      res.lines.push({ err: false, text: `HIGH: ${name}: test entrypoint does not run under its required runner (skip-reason ${want.rejectSkipReason}) code=MISSING_TEST_RUNNER` });
      res.high = true;
    }
  } else if (r.rc === 69) {
    const runtime = R.fieldValue(m.entry, "launch.requires") || "its runtime";
    res.lines.push({ err: false, text: `WARN: ${name}: required runner not checked (${runtime} is not installed) code=TEST_RUNNER_CHECK_RUNTIME_UNAVAILABLE` });
  } else {
    res.lines.push({ err: true, text: `check-test-runner.sh: skip-reason op failed (rc=${r.rc}): ${name}` });
    res.infra = true;
  }
  return res;
}

module.exports = { judge, runnerHint };

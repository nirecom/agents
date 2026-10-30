"use strict";
// Language-match gate of the tests-frontmatter check (#2507 D7; ports _precommit_check_test_language_match
// of hooks/lib/precommit-tests-frontmatter.sh). The staged blob of every staged tests/ file (new or
// existing; tests/_archive/ and tests/lib/ excluded) is judged in memory with its parent baseline(s)
// (#2812: HEAD, or both parents and their merge-base during a merge).
// A checker infra error fails open with a stderr diagnostic.

const R = require("../../../lib/test-gates/registry");
const S = require("../../../lib/test-gates/source");
const LM = require("../../../lib/test-gates/language-match");
const { MERGE_STATE } = require("../../../lib/merge-state");
const { readAll } = require("../../../lib/test-gates/frontmatter/parents");
const { out, err } = require("../../output");
const { parentsOf } = require("./parents");

const ACMR = new Set(["A", "C", "M", "R"]);
const EXCLUDED = /^tests\/(_archive|lib)\//;

// check(rel, file, head, opts) -> { rc, lines }, as the CLI answers one file.
function check(rel, file, head, opts) {
  if (!R.tryReg()) return { rc: 2, lines: ["check-test-language-match.sh: registry unreadable"] };
  const r = LM.check(file, rel, head, opts);
  return { rc: r.violation ? 1 : r.infra ? 2 : 0, lines: r.lines.map((l) => l.text) };
}

// baselineOids(rec, state) — the parent blobs rel is judged against (ports mp_baseline_args): none
// for a copy equal to a parent during a merge (declaration only), else head1 [head2 [base]].
function baselineOids(rec, state) {
  if (rec.same === 1 && state === MERGE_STATE.MERGING) return null;
  return rec.b2 ? [rec.b1, rec.b2, rec.base] : [rec.b1];
}

// baseline(rel, par, blobs) -> { head, opts } or null when a named parent blob is unreadable.
function baseline(rel, par, blobs, root) {
  const oids = baselineOids(par.record(rel), par.state);
  if (!oids) return { head: null, opts: { root, declarationOnly: true } };
  if (oids.some((o) => o && !blobs.has(o))) return null;
  const mem = (o) => (o ? S.mem(rel, blobs.get(o)) : null);
  if (oids.length === 1) return { head: mem(oids[0]), opts: { root } };
  return { head: [mem(oids[0]), mem(oids[1])], opts: { root, base: mem(oids[2]) } };
}

function gate({ context, snapshot, files }) {
  const rels = files.filter((f) => f.startsWith("tests/") && !EXCLUDED.test(f) && ACMR.has(snapshot.status(f)));
  if (rels.length === 0) return { block: false, messages: [] };
  const par = parentsOf({ context, snapshot, files });
  const messages = [...par.note()];
  const high = [];
  const blobs = readAll([...new Set(rels.flatMap((rel) => baselineOids(par.record(rel), par.state) || []))].filter(Boolean), par.blobs);
  for (const rel of rels) {
    const blob = snapshot.content(rel);
    if (!blob) {
      messages.push(err(`pre-commit: cannot read staged blob for ${rel} — language-match check skipped for it`));
      continue;
    }
    const b = baseline(rel, par, blobs, context.repoTop);
    if (!b) {
      // Judged as new, it could block a mismatch a parent already had.
      messages.push(err(`pre-commit: cannot read a parent blob for ${rel} — language-match check skipped for it`));
      continue;
    }
    const r = check(rel, S.mem(rel, blob), b.head, b.opts);
    if (r.rc === 1 && r.lines.some((l) => /^HIGH: .* code=/.test(l))) {
      for (const line of r.lines) {
        if (/^HIGH:.*code=/.test(line)) high.push(line);
        else if (/^WARN:.*code=/.test(line)) messages.push(err(line));
      }
    } else if (r.rc === 0) {
      messages.push(...r.lines.map(err));
    } else {
      messages.push(err(`pre-commit: check-test-language-match rc=${r.rc} for ${rel} — language-match check incomplete (commit continues)`));
      messages.push(...r.lines.map(err));
    }
  }
  if (high.length === 0) return { block: false, messages };
  return {
    block: true,
    messages: [...messages, ...high.map(out), out(""), out("Commit blocked: test file(s) fail the language-match gate."),
      out("Write the test in the code's language (see the new file shape), or declare a valid test-lang-exception in Tags: (rules/test.md).")],
  };
}

module.exports = { gate };

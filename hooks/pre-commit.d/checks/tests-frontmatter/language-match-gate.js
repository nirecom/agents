"use strict";
// Language-match gate of the tests-frontmatter check (#2507 D7; ports _precommit_check_test_language_match
// of hooks/lib/precommit-tests-frontmatter.sh). The staged blob of every staged tests/ file (new or
// existing; tests/_archive/ and tests/lib/ excluded) is judged in memory with its HEAD blob, if any.
// A checker infra error fails open with a stderr diagnostic.

const R = require("../../../lib/test-gates/registry");
const S = require("../../../lib/test-gates/source");
const LM = require("../../../lib/test-gates/language-match");
const { out, err } = require("../../output");

const ACMR = new Set(["A", "C", "M", "R"]);
const EXCLUDED = /^tests\/(_archive|lib)\//;

// check(rel, file, head, root) -> { rc, lines }, as the CLI answers one file.
function check(rel, file, head, root) {
  if (!R.tryReg()) return { rc: 2, lines: ["check-test-language-match.sh: registry unreadable"] };
  const r = LM.check(file, rel, head, { root });
  return { rc: r.violation ? 1 : r.infra ? 2 : 0, lines: r.lines.map((l) => l.text) };
}

function gate({ context, snapshot, files }) {
  const rels = files.filter((f) => f.startsWith("tests/") && !EXCLUDED.test(f) && ACMR.has(snapshot.status(f)));
  const messages = [];
  const high = [];
  for (const rel of rels) {
    const blob = snapshot.content(rel);
    if (!blob) {
      messages.push(err(`pre-commit: cannot read staged blob for ${rel} — language-match check skipped for it`));
      continue;
    }
    let head = null;
    if (snapshot.status(rel) !== "A") {
      const h = snapshot.headContent(rel);
      if (!h) {
        messages.push(err(`pre-commit: cannot read HEAD blob for ${rel} — language-match check skipped for it`));
        continue;
      }
      head = S.mem(rel, h);
    }
    const r = check(rel, S.mem(rel, blob), head, context.repoTop);
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

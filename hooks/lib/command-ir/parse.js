"use strict";
// hooks/lib/command-ir/parse.js — raw command text -> IR.
//
// Returns {segments, separators, cmd0, argv, redirects, kind, rawText, parseFailure}
// plus a non-enumerable frozen `analysis` (see ./analysis.js). rawText is ALWAYS the
// original string. parseFailure===true (unclosed quote, tokenizer throw) is the
// fail-closed signal write-classifying consumers key off; `separators` is recorded at
// every split point, so its length may differ from segments.length - 1 by design.
// Ownership + consumer list: docs/architecture/claude-code/shell-command-parsing.md.

const { splitSegmentsWithSeparators } = require("../command-parser");
const { hasUnclosedQuoteSpan } = require("../quote-spans");
const { buildSegmentIR } = require("./segments");
const { scanHeredocs } = require("./heredoc");
const { buildAnalysis, attachAnalysis } = require("./analysis");

// opts.preserveSubstitutionSpans (default OFF): keeps unquoted substitution spans
// intact through split and tokenize so a write target assembled inside one survives
// as a single token. Additive at the caller — see ../command-parser.js.
function parse(cmd, opts) {
  const rawText = cmd;
  let lexText = typeof cmd === "string" ? cmd : "";
  let heredocs = [];

  const degenerate = (parseFailure) =>
    attachAnalysis(
      { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, separators: [], parseFailure },
      buildAnalysis(rawText, lexText, heredocs, opts)
    );

  try {
    if (!cmd || typeof cmd !== "string" || cmd.trim() === "") return degenerate(false);

    ({ lexText, heredocs } = scanHeredocs(cmd));

    // Fail-closed: unclosed quotes indicate malformed input.
    if (hasUnclosedQuoteSpan(lexText, ["dq", "sq", "ansic"])) return degenerate(true);

    const isSubshell = cmd.trim().startsWith("(");
    const { segs: segStrings, seps } = splitSegmentsWithSeparators(lexText, opts);
    const kind = isSubshell ? "subshell" : segStrings.length > 1 ? "pipeline" : "simple";
    const segments = segStrings.map((s) => buildSegmentIR(s, isSubshell, opts));
    const first = segments.length > 0 ? segments[0] : { cmd0: "", argv: [], redirects: [] };

    return attachAnalysis(
      {
        segments,
        separators: seps,
        cmd0: first.cmd0,
        argv: first.argv.slice(),
        redirects: first.redirects,
        kind,
        rawText,
        parseFailure: false,
      },
      buildAnalysis(rawText, lexText, heredocs, opts)
    );
  } catch (e) {
    return degenerate(true);
  }
}

module.exports = { parse };

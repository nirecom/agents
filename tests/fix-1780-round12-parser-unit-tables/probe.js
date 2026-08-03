#!/usr/bin/env node
// tests/fix-1780-round12-parser-unit-tables/probe.js
// Table evaluator for tests/fix-1780-round12-parser-unit-tables.sh.
//
// The TABLES live in the bash file (rules: skills/_shared/test-design/parser-regex-tests.md
// prescribes the bash table-driven pattern). This probe is the `eval_subject`
// half of that pattern: it reads `name|want|fn|input` rows on stdin and prints
// `name<TAB>got` lines, so ONE node process serves a whole table instead of one
// process per row.
//
// COLUMN ORDER: `want` sits SECOND, before the input, on purpose. Shell inputs
// legitimately contain `|` (pipelines), so a trailing `want` column could not be
// split off without truncating exactly the pipeline rows this suite exists to
// cover. With `want` in front, both readers take the input as "everything after
// the third field, separators included". The probe ignores `want` — comparison
// and the PASS/FAIL tally belong to the bash side.
//
// argv[2]  agents dir to load the modules under test FROM. The mutation-evidence
//          section passes a MUTATED COPY of hooks/ here, which is the whole
//          reason the root is a parameter and not `../..`.
"use strict";

const path = require("path");

const ROOT = process.argv[2];
const load = (rel) => require(path.join(ROOT, rel));

let modErr = "";
let M = null;
try {
  M = {
    bgn: load("hooks/lib/basename-glob-normalize.js"),
    brace: load("hooks/lib/basename-glob-normalize/brace-ansi-expand.js"),
    argvScan: load("hooks/block-clearance-token-write/bash-scan/argv-scan.js"),
    assign: load("hooks/block-clearance-token-write/bash-scan/assignment-text.js"),
    interp: load("hooks/block-clearance-token-write/interpreter-scan.js"),
    nested: load("hooks/block-clearance-token-write/nested-bodies.js"),
    ir: load("hooks/lib/command-ir.js"),
    pb: load("hooks/lib/protected-basenames.js"),
  };
} catch (e) {
  modErr = String((e && e.message) || e);
}

if (!M) {
  process.stdout.write("__MODULES__\tload-failed: " + modErr + "\n");
  process.exit(0);
}

// The deny suffixes are DERIVED from the SSOT, never spelled out here — a
// hardcoded copy would keep passing after a marker kind is added and silently
// stop covering it.
const SUFFIXES = M.pb.SESSION_MARKER_KINDS.map((k) => "." + k).concat(
  M.pb.OFF_CLEARANCE_TOKEN_SUFFIXES
);

const b = (x) => (x ? "true" : "false");
const segsOf = (cmd) => M.ir.parse(cmd).segments || [];
const seg0 = (cmd) => segsOf(cmd)[0] || null;
// `~` joins multi-valued results: it appears in none of the inputs below, and
// keeping the join visible in the expected column is what makes an extra or a
// missing element a FAIL rather than a silently absorbed difference.
const j = (arr) => (arr && arr.length ? arr.join("~") : "-");
// A fresh `test` on a regex that may carry /g would be stateful; reset first so
// a row's verdict never depends on the row before it.
const t = (re, s) => {
  if (!re) return "no-regex";
  re.lastIndex = 0;
  return b(re.test(s));
};

const FNS = {
  // ---- hooks/lib/basename-glob-normalize.js -------------------------------
  norm: (i) => M.bgn.normalizeCandidateBasename(i),
  hasglob: (i) => b(M.bgn.hasGlobMetachar(i)),
  match: (i) => b(M.bgn.candidateBasenameMatchesAnySuffix(i, SUFFIXES)),

  // ---- hooks/lib/basename-glob-normalize/brace-ansi-expand.js -------------
  ansi: (i) => M.brace.decodeAnsiCEscapes(i),
  ansivars: (i) => j(M.brace.ansiCVariantsOf(i)),
  braces: (i) => j(M.brace.expandBraces(i).list),
  bracecap: (i) => b(M.brace.expandBraces(i).overCap),
  spellings: (i) => j(M.brace.candidateSpellings(i).candidates),

  // ---- hooks/block-clearance-token-write/bash-scan/argv-scan.js -------------
  rocmd: (i) => t(M.argvScan.READ_ONLY_ARG_COMMAND_RE, i),
  lesslog: (i) => t(M.argvScan.LESS_LOG_OPT_RE, i),
  // input: "<cmdBase> <argv...>"
  roinv: (i) => {
    const w = i.split(/\s+/).filter(Boolean);
    return b(M.argvScan.readOnlyInvocation(w[0] || "", w.slice(1)));
  },
  varref: (i) => {
    const re = M.argvScan.VAR_REF_RE;
    if (!re) return "no-regex";
    re.lastIndex = 0;
    const m = re.exec(i);
    return m ? m[1] || m[2] || "-" : "-";
  },

  // ---- hooks/block-clearance-token-write/bash-scan/assignment-text.js -------
  pwshassign: (i) => t(M.assign.PWSH_ENV_ASSIGN_ONLY_RE, i),
  assignonly: (i) => b(M.assign.isAssignmentOnlySegment(seg0(i))),
  // Both chain readers are asked about the LAST segment of the input command,
  // so the row's input reads as the shell line an attacker would actually type.
  chain: (i) => {
    const s = segsOf(i);
    const out = M.assign.precedingAssignmentChainText(s, s.length - 1);
    return out.trim() === "" ? "-" : out.trim().split(/\s*\n\s*/).join("~");
  },
  prior: (i) => {
    const s = segsOf(i);
    const out = M.assign.priorAssignmentsText(s, s.length - 1);
    return out.trim() === "" ? "-" : out.trim().split(/\s*\n\s*/).join("~");
  },

  // ---- hooks/block-clearance-token-write/interpreter-scan.js ----------------
  interpre: (i) => t(M.interp.INTERPRETER_RE, i),
  bodyfirst: (i) => t(M.interp.BODY_FIRST_INTERPRETER_RE, i),
  inlineflag: (i) => t(M.interp.INLINE_PROGRAM_FLAG_RE, i),
  kind: (i) => M.interp.interpreterKindOfWord(i) || "-",
  lookslike: (i) => b(M.interp.looksLikeInterpreterInvocation(i)),
  pwshword: (i) => b(M.interp.isPwshWord(i)),
  // input: "<word> <interpreterWord>" — the kind-scoped predicate needs both.
  proof: (i) => {
    const w = i.split(/\s+/).filter(Boolean);
    return b(M.interp.inlineProgramFlagProof(w[0] || "", w[1] || ""));
  },
  roshape: (i) => b(M.interp.interpreterBodyIsRecognizedReadOnly(i)),
  bodies: (i) => j(M.interp.extractAllInterpreterBodies(i).bodies),
  hits: (i) => b(M.interp.hitsProtectedViaInterpreter(i)),

  // ---- hooks/block-clearance-token-write/nested-bodies.js -------------------
  evalbody: (i) => M.nested.evalBodyOf(seg0(i)) || "-",
  herestr: (i) => j(M.nested.hereStringBodiesOf(seg0(i))),
  hereval: (i) => j(M.nested.hereStringValuesOf(seg0(i))),
  nestedtexts: (i) => j(M.nested.nestedCommandTextsOf(seg0(i))),
  stdinkind: (i) => M.nested.stdinProgramInterpreterKind(seg0(i)) || "-",
  // Shape summary of the three route buckets: bodies / fileTargets / opaqueTexts.
  routes: (i) => {
    const p = M.ir.parse(i);
    const r = M.nested.stdinProgramRoutes(i, p.segments);
    return "b=" + r.bodies.length + ",f=" + r.fileTargets.length + ",o=" + r.opaqueTexts.length;
  },

  // ---- SSOT self-checks ---------------------------------------------------
  ssot: () => SUFFIXES.length + ":" + M.pb.SESSION_MARKER_KINDS.length,
};

let text = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => { text += d; });
process.stdin.on("end", () => {
  const out = [];
  for (const line of text.split("\n")) {
    const raw = line.replace(/\r$/, "");
    if (raw.trim() === "" || /^\s*#/.test(raw)) continue;
    const parts = raw.split("|");
    if (parts.length < 4) continue;
    const name = parts[0].trim();
    // parts[1] is `want` — the bash side owns that comparison.
    const fn = parts[2].trim();
    // The input is everything after the third field, `|` separators included,
    // so pipeline rows survive. Surrounding whitespace is table padding and is
    // trimmed; two escapes buy back what trimming and line-splitting cost:
    //   \n  a real newline  — heredoc rows are multi-line by nature, and a table
    //                         format that cannot express one has no heredoc coverage
    //   \s  a literal space — the only way to state a trailing space, which is
    //                         itself a normalizer rule under test (Windows strips it)
    const input = parts
      .slice(3)
      .join("|")
      .trim()
      .replace(/\\n/g, "\n")
      .replace(/\\s/g, " ");
    let got;
    try {
      got = FNS[fn] ? String(FNS[fn](input)) : "no-such-fn:" + fn;
    } catch (e) {
      got = "threw:" + String((e && e.message) || e);
    }
    out.push(name + "\t" + got.replace(/[\r\n]+/g, "\\n"));
  }
  process.stdout.write(out.join("\n") + "\n");
});

"use strict";
// tests/fixtures/quote-spans-differential.js
// Old-vs-new differential runner for #1569. Driven by
// tests/hooks/unit-quote-spans-differential.sh, which owns the diff allowlist.
//
// Usage: node quote-spans-differential.js <corpus.txt> <allowlist.tsv>
//
// Emits one `PASS: <name>` / `FAIL: <name> — <detail>` line per assertion so
// the bash caller can tally without parsing JSON. Always exits 0.
//
// Two integrity layers sit under the differential itself:
//   golden.js   — the frozen "old" implementations are pinned byte-for-byte
//                 against pre-migration golden outputs, so a corrupted oracle
//                 cannot make the comparison falsely green.
//   relation.js — every allowlisted diff must declare and PROVE a relation
//                 (unchanged / expose-more / blank-more) rather than merely
//                 being listed.

const fs = require("fs");
const path = require("path");
const { loadGolden, frozenMismatch } = require("./quote-spans-differential/golden.js");
const { checkRelation } = require("./quote-spans-differential/relation.js");

const AGENTS_DIR = path.resolve(__dirname, "..", "..");
const FROZEN = path.join(__dirname, "quote-spans-frozen");
const GOLDEN = path.join(__dirname, "quote-spans-golden.jsonl");

const corpusPath = process.argv[2];
const allowPath = process.argv[3];

let PASS = 0;
let FAIL = 0;
function pass(n) { PASS++; console.log("PASS: " + n); }
function fail(n, d) { FAIL++; console.log("FAIL: " + n + " — " + d); }

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------
const cases = [];
for (const raw of fs.readFileSync(corpusPath, "utf8").split(/\r?\n/)) {
  const t = raw.trim();
  if (!t || t.startsWith("#")) continue;
  cases.push(JSON.parse(t));
}

// Allowlist rows, tab-separated:
//   <fn>  <json-encoded input>  <direction>  class: <cls>  expose: <literal>  <reason>
const SEP = "\0";
const allow = new Map(); // key: fn + SEP + input
const allowUsed = new Set();
const allowRows = [];
if (allowPath && fs.existsSync(allowPath)) {
  for (const raw of fs.readFileSync(allowPath, "utf8").split(/\r?\n/)) {
    const t = raw.replace(/\s+$/, "");
    if (!t.trim() || t.trim().startsWith("#")) continue;
    const [fn, inputJson, direction, clsField, exposeField, reason] = t.split("\t");
    if (!fn || !inputJson) continue;
    const cls = (clsField || "").startsWith("class: ") ? clsField.slice(7).trim() : "";
    const expose = (exposeField || "").startsWith("expose: ") ? exposeField.slice(8) : "";
    const input = JSON.parse(inputJson);
    allow.set(fn + SEP + input, { direction, cls, expose, reason });
    allowRows.push({ key: fn + SEP + input, fn, input });
  }
}

// ---------------------------------------------------------------------------
// Old (frozen) implementations — must load and run green today.
// ---------------------------------------------------------------------------
const oldHUQ = require(path.join(FROZEN, "has-unclosed-quote.js")).hasUnclosedQuote;
const oldStrip = require(path.join(FROZEN, "strip-quoted-args.js"));
const oldFold = require(path.join(FROZEN, "fold-dq-newlines.js")).foldDqNewlines;

// ---------------------------------------------------------------------------
// New implementations — absent until C1/C2 land.
// ---------------------------------------------------------------------------
let spans = null;
let spansErr = null;
try {
  spans = require(path.join(AGENTS_DIR, "hooks", "lib", "quote-spans.js"));
} catch (e) {
  spansErr = e.message;
}

let newStrip = null;
let newStripErr = null;
try {
  newStrip = require(path.join(AGENTS_DIR, "hooks", "lib", "strip-quoted-args.js"));
} catch (e) {
  newStripErr = e.message;
}

function label(i, s) {
  const shown = JSON.stringify(s);
  return "[" + i + "] " + (shown.length > 60 ? shown.slice(0, 57) + '..."' : shown);
}

// ---------------------------------------------------------------------------
// Phase A — the ORACLE itself: frozen output === pre-migration golden, byte for
// byte, for every corpus row. Without this the differential could compare the
// new implementation against a silently corrupted "old" one and stay green.
// ---------------------------------------------------------------------------
const { rows: golden, problem: goldenProblem } = loadGolden(GOLDEN, cases);
if (goldenProblem) {
  fail("A0 golden record alignment", goldenProblem);
} else {
  pass("A0 golden record alignment (" + golden.length + " rows, matched by input)");
}

cases.forEach((s, i) => {
  const name = "A frozen-vs-golden " + label(i, s);
  if (!golden) { fail(name, "golden record unusable: " + goldenProblem); return; }
  let out;
  try {
    out = {
      huq: oldHUQ(s),
      sqa: oldStrip.stripQuotedArgs(s),
      sdp: oldStrip.stripDqPreservingCmdSubst(s),
      fold: oldFold(s),
    };
  } catch (e) {
    fail(name, "frozen implementation threw: " + e.message);
    return;
  }
  if (typeof out.huq !== "boolean") { fail(name, "hasUnclosedQuote did not return a boolean"); return; }
  const bad = frozenMismatch(golden[i], out);
  if (bad) fail(name, bad);
  else pass(name);
});

// ---------------------------------------------------------------------------
// Phase B — hasUnclosedQuote: ZERO diffs allowed (the allowlist does not apply).
// New call site passes the quote kinds explicitly: ["dq","sq","ansic"].
// ---------------------------------------------------------------------------
// The ONE documented exception to Phase B's zero-diff rule.
//
// Two plan requirements collide on this single input, and the structural one
// wins. The plan pins `"$(printf '"')"` as mandatory scanner structure case 6:
// an outer dq containing a correctly nested cmdsubst containing an sq. Real
// bash agrees — `echo "$(printf '"')"` passes `bash -n` and prints `"`. So the
// string has NO unclosed quote, and the frozen oracle saying otherwise is the
// #1569 false-block bug itself: it tracks single quotes only from the unquoted
// state, so the `"` inside the substitution's single quotes closes the outer
// dq and the trailing `"` is then read as an unterminated span. The plan's
// root-cause section says in as many words that the new scanner must not
// inherit that defect, which makes "byte-identical to the old answer"
// unsatisfiable here.
//
// Admitting a true->false diff is admitting a relaxation, which is exactly what
// Phase B guards, so it is pinned rather than described: input, old answer AND
// new answer are all fixed, the input must be in the corpus, and the deviation
// must actually FIRE. If the two sides ever agree again the row fails as stale
// instead of quietly passing, and every other input still requires zero diffs.
const HUQ_DEVIATIONS = [
  {
    in: '"$(printf \'"\')"',
    old: true,
    new: false,
    why: "mandatory structure case 6 — frozen oracle mis-tracks the sq nested in $() inside dq",
  },
];

HUQ_DEVIATIONS.forEach((d) => {
  const nm = "B deviation entry names a corpus case " + JSON.stringify(d.in);
  if (cases.indexOf(d.in) !== -1) pass(nm);
  else fail(nm, "documented Phase B deviation names an input the corpus does not carry");
});

cases.forEach((s, i) => {
  const name = "B hasUnclosedQuote old-vs-new " + label(i, s);
  if (!spans) { fail(name, "quote-spans.js not available: " + spansErr); return; }
  let got;
  try {
    got = spans.hasUnclosedQuoteSpan(s, ["dq", "sq", "ansic"]);
  } catch (e) {
    fail(name, "new impl threw: " + e.message);
    return;
  }
  const want = oldHUQ(s);
  const dev = HUQ_DEVIATIONS.find((d) => d.in === s);
  if (got === want) {
    if (dev) {
      fail(name, "documented deviation did NOT occur (old=new=" + want +
                 ") — the exception is stale and must be removed");
    } else {
      pass(name);
    }
  } else if (dev && want === dev.old && got === dev.new) {
    pass(name + " [documented deviation: " + dev.why + "]");
  } else {
    fail(name, "old=" + want + " new=" + got + " (ZERO diffs allowed for this function)");
  }
});

// ---------------------------------------------------------------------------
// Phase C — stripQuotedArgs / stripDqPreservingCmdSubst: diffs allowed ONLY
// when allowlisted, and only when the declared relation is machine-proved.
// ---------------------------------------------------------------------------
function differentialWithAllowlist(fnName, oldFn, newFn, unavailable) {
  cases.forEach((s, i) => {
    const name = "C " + fnName + " old-vs-new " + label(i, s);
    if (unavailable) { fail(name, fnName + " not available: " + unavailable); return; }
    let oldOut;
    let newOut;
    try {
      oldOut = oldFn(s);
      newOut = newFn(s);
    } catch (e) {
      fail(name, "threw: " + e.message);
      return;
    }
    if (oldOut === newOut) { pass(name); return; }
    const key = fnName + SEP + s;
    const entry = allow.get(key);
    if (!entry) {
      fail(name, "unlisted diff — old=" + JSON.stringify(oldOut) + " new=" + JSON.stringify(newOut));
      return;
    }
    allowUsed.add(key);
    const problem = checkRelation(entry, s, oldOut, newOut, spans);
    if (problem) {
      fail(name, "allowlisted as `" + entry.cls + "` but " + problem +
                 " (old=" + JSON.stringify(oldOut) + " new=" + JSON.stringify(newOut) + ")");
      return;
    }
    pass(name + " [allowlisted, " + entry.cls + ", proved]");
  });
}

differentialWithAllowlist(
  "stripQuotedArgs",
  oldStrip.stripQuotedArgs,
  newStrip ? newStrip.stripQuotedArgs : null,
  newStrip ? null : newStripErr
);
differentialWithAllowlist(
  "stripDqPreservingCmdSubst",
  oldStrip.stripDqPreservingCmdSubst,
  newStrip ? newStrip.stripDqPreservingCmdSubst : null,
  newStrip ? null : newStripErr
);

// ---------------------------------------------------------------------------
// Phase D — foldDqNewlines (deleted from worker-script.js) vs the quote-spans
// replacement foldNewlinesInSpans(str, ["dq"]). The kinds selector is part of
// the contract: the old function folded DQ newlines and nothing else.
// ---------------------------------------------------------------------------
differentialWithAllowlist(
  "foldDqNewlines",
  oldFold,
  spans ? (s) => spans.foldNewlinesInSpans(s, ["dq"]).out : null,
  spans ? null : spansErr
);

// ---------------------------------------------------------------------------
// Allowlist hygiene — a key that names an input the corpus does not contain can
// never be exercised, so it silently widens the allowlist. That is a real
// defect and fails. Entries that exist but never fired are reported as a NOTE
// (they may legitimately stop firing once the two sides agree).
// ---------------------------------------------------------------------------
const corpusSet = new Set(cases);
const deadKeys = allowRows.filter((r) => !corpusSet.has(r.input));
if (deadKeys.length === 0) {
  pass("E allowlist hygiene: every entry names a corpus case");
} else {
  fail("E allowlist hygiene", "allowlist entries whose input is not in the corpus: " +
       JSON.stringify(deadKeys.map((r) => r.fn + " " + JSON.stringify(r.input))));
}
const neverFired = allowRows.filter((r) => !allowUsed.has(r.key));
if (neverFired.length) {
  console.log("NOTE: " + neverFired.length + " allowlist entr" +
              (neverFired.length === 1 ? "y" : "ies") + " did not fire this run");
}

console.log("");
console.log("SUMMARY PASS=" + PASS + " FAIL=" + FAIL);

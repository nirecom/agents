// tests/enforce-protected-marker-write/round9-brace-ansi-probe.js
// Unit probe for the round-9 HIGH-2 fix, run as a FILE (never `node -e`): the
// strings under test ARE protected basenames, so a `-e` body spelling them would
// be blocked by the very hook this suite tests. argv[2] = repo root.
//
// Emits `key=value` lines; the bash side asserts on them. Three properties are
// pinned here that a hook-level verdict cannot isolate:
//
//  1. The candidate enumeration IS bash's brace expansion, not something merely
//     correlated with it. Every expected set below is RECOMPUTED here from the
//     range definition (a plain loop) and compared against candidateSpellings();
//     re-asserting the function's own output against itself would pass against
//     any implementation, including one that emits the input unchanged.
//  2. The cap is a FAIL-CLOSED boundary. 1025 alternatives is not a hook payload
//     anybody types, so only this layer can stand on both sides of it: below the
//     cap the enumeration completes and answers honestly, above it the answer is
//     "hit" even though — as recomputed here — no expansion carries the suffix.
//  3. unquoteBashWord() no longer REWRITES `\x66` into the literal `x66`. That
//     was worse than a miss: the normalizer manufactured a basename the shell
//     never creates (`…workflow-ofx66`) while the shell created the real one.
"use strict";

const path = require("path");

const root = process.argv[2];
const hooks = path.join(root, "hooks");
const expandMod = path.join(hooks, "lib", "basename-glob-normalize", "brace-ansi-expand.js");
const { candidateSpellings, expandBraces, decodeAnsiCEscapes, MAX_CANDIDATE_SPELLINGS } = require(expandMod);
const { candidateBasenameMatchesAnySuffix } = require(path.join(hooks, "lib", "basename-glob-normalize.js"));
const { unquoteBashWord, classifyProtectedBashToken } = require(path.join(hooks, "lib", "protected-basenames.js"));

const out = [];
const emit = (k, v) => out.push(k + "=" + String(v));
const sorted = (a) => a.slice().sort().join("");
const sameSet = (a, b) => sorted(Array.from(new Set(a))) === sorted(Array.from(new Set(b)));

emit("mod_loaded", typeof candidateSpellings === "function" && typeof expandBraces === "function");

// --- independent expectation builders ---------------------------------------
// Written from the bash manual's definition of a brace range, NOT from
// rangeAlternatives(): a shared helper would make the comparison circular.
function numRange(a, b, step, width) {
  const res = [];
  const pad = (v) => {
    const neg = v < 0;
    let d = String(Math.abs(v));
    while (d.length < width) d = "0" + d;
    return (neg ? "-" : "") + d;
  };
  if (a <= b) { for (let v = a; v <= b; v += step) res.push(pad(v)); }
  else { for (let v = a; v >= b; v -= step) res.push(pad(v)); }
  return res;
}
function charRange(a, b) {
  const res = [];
  const s = a.charCodeAt(0);
  const e = b.charCodeAt(0);
  if (s <= e) { for (let v = s; v <= e; v++) res.push(String.fromCharCode(v)); }
  else { for (let v = s; v >= e; v--) res.push(String.fromCharCode(v)); }
  return res;
}
const wrap = (pre, alts, post) => alts.map((a) => pre + a + post);

// --- 1. the expansion sets --------------------------------------------------
const braceCases = [
  ["a{b,c}d", wrap("a", ["b", "c"], "d")],
  ["a{b,c,d}e", wrap("a", ["b", "c", "d"], "e")],
  ["x{a..e}y", wrap("x", charRange("a", "e"), "y")],
  ["x{e..a}y", wrap("x", charRange("e", "a"), "y")],
  ["x{1..9}y", wrap("x", numRange(1, 9, 1, 0), "y")],
  ["x{1..9..3}y", wrap("x", numRange(1, 9, 3, 0), "y")],
  ["x{9..1..4}y", wrap("x", numRange(9, 1, 4, 0), "y")],
  ["x{01..10}y", wrap("x", numRange(1, 10, 1, 2), "y")],
  ["x{001..004}y", wrap("x", numRange(1, 4, 1, 3), "y")],
  // The construct this fix is actually about: the last character of a protected
  // basename re-spelled as a one-element range.
  ["s1.workflow-of{f..f}", ["s1.workflow-off"]],
  ["s1.workflow-{off,off}", ["s1.workflow-off"]],
];
let braceOk = true;
const braceBad = [];
for (const [text, expanded] of braceCases) {
  const { candidates, overCap } = candidateSpellings(text);
  const want = expanded.concat([text]);              // the raw spelling is never dropped
  if (overCap || !sameSet(candidates, want)) {
    braceOk = false;
    braceBad.push(text + " -> [" + candidates.join(",") + "]");
  }
}
emit("brace_ok", braceOk);
emit("brace_bad", braceBad.join(" | ") || "-");

// Bash fidelity: a single element with no top-level comma and no `..` is NOT a
// brace expansion — `{x}` stays literal, braces and all. Emitting `ab` here
// would FABRICATE a spelling the shell never produces, which in the detection
// direction means blocking writes that were never protected.
const singles = ["a{x}b", "a{abc}b", "a{}b", "a{"];
emit("brace_single_literal", singles.every((s) => sameSet(candidateSpellings(s).candidates, [s])));

// Nesting / multiple groups: the cartesian product, recomputed here.
const nestedWant = [];
for (const a of ["p", "q"]) for (const b of numRange(1, 3, 1, 0)) nestedWant.push("<" + a + "-" + b + ">");
emit("brace_nested", sameSet(candidateSpellings("<{p,q}-{1..3}>").candidates,
  nestedWant.concat(["<{p,q}-{1..3}>"])));

// Zero padding is a property of the SPELLING, not of the number: `{01..10}`
// yields 01..10, never 1..10.
const padded = candidateSpellings("f{08..11}").candidates;
emit("brace_padded", ["f08", "f09", "f10", "f11"].every((c) => padded.includes(c)) &&
  !padded.includes("f8") && !padded.includes("f9"));

emit("brace_keeps_raw", braceCases.every(([t]) => candidateSpellings(t).candidates.includes(t)));

// --- 2. the cap, from both sides -------------------------------------------
// MEASURED, not assumed: the cap counts the RAW spelling too, because
// candidateSpellings() appends it and only then compares against the cap. So an
// N-alternative group costs N+1 candidates and the last group that FITS has
// CAP-1 alternatives, not CAP. Pinning the edge is the point of this block — an
// off-by-one here silently moves a fail-closed boundary.
const CAP = MAX_CANDIDATE_SPELLINGS;
const SUF = [".workflow-off"];
const belowText = "x{1.." + (CAP - 1) + "}";   // CAP-1 alternatives + raw = CAP
const edgeText = "x{1.." + CAP + "}";          // CAP alternatives + raw = CAP+1
const aboveText = "x{1.." + (CAP + 1) + "}";   // refused before expanding at all
const below = candidateSpellings(belowText);
const edge = candidateSpellings(edgeText);
const above = candidateSpellings(aboveText);
// Recomputed independently: no pattern here can expand onto the suffix, so an
// enumeration that FINISHED must answer "no match" and one that did not must
// answer "hit" without looking.
const noneMatches = numRange(1, CAP + 1, 1, 0).every((n) => !("x" + n).endsWith(SUF[0]));
emit("cap_below_ok", below.overCap === false && below.candidates.length === CAP && noneMatches);
emit("cap_edge_overcap", edge.overCap === true);
emit("cap_above_overcap", above.overCap === true);
emit("cap_above_hit", candidateBasenameMatchesAnySuffix(aboveText, SUF) === true);
emit("cap_below_miss", candidateBasenameMatchesAnySuffix(belowText, SUF) === false);

// --- 3. ANSI-C decoding and the unquoteBashWord rewrite ---------------------
emit("ansi_hex", decodeAnsiCEscapes("a\\x66") === "af" &&
  decodeAnsiCEscapes("a\\146") === "af" &&
  decodeAnsiCEscapes("\\x77orkflow") === "workflow" &&
  decodeAnsiCEscapes("plain") === "plain");

// The regression itself: `$'…\x66'` used to normalize to `…x66`.
const ansiWord = "$'/wf/s1.workflow-of\\x66'";
const unq = unquoteBashWord(ansiWord);
emit("unquote_fixed", unq === "/wf/s1.workflow-off" && !unq.includes("x66"));
emit("unquote_marker", classifyProtectedBashToken(ansiWord) === "marker" &&
  classifyProtectedBashToken("$'/wf/s1." + "off-" + "clearanc\\x65'") === "token");

// PLAIN context is unchanged: outside $'…', bash's `\x` really is just `x`.
// Widening the ANSI rule into plain context would be the same rewrite defect in
// the opposite direction.
emit("unquote_plain", unquoteBashWord("a\\x66") === "ax66" &&
  unquoteBashWord("'a\\x66'") === "a\\x66");

process.stdout.write(out.join("\n") + "\n");

#!/usr/bin/env bash
# tests/enforce-clearance-token-write/mention-gate-strict-boundary-cases.sh
# Tests: hooks/lib/protected-basenames.js
# Tags: off-clearance, clearance-token, mention-gate, TOKEN_MENTION_STRICT_RE, MARKER_MENTION_STRICT_RE, boundary, unicode, refinement, table-driven, scope:common, pwsh-not-required, TL1

# mentionsProtectedNameStrict is the reading the INTERPRETER route decides on, and that
# route is terminal — it never re-classifies the path afterwards, so an over-arm here is a
# refusal the user cannot work around. The wide gate has its own matrix in the sibling
# mention-gate-boundary-cases.sh; this is the same discipline applied to the strict half,
# whose defining difference (a Unicode-aware right boundary) no row over there can see.
# TL3 gap: unit-level on the regex pair; the hook-level consequence is in the sibling
# unicode-boundary-e2e-cases.sh.

set -u

# lang-check: ignore (the literal CJK/multibyte rows below are test INPUT, not prose)

SEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SEC_DIR/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
PB="$AGENTS_DIR/hooks/lib/protected-basenames.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
report() { echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; [ "$FAIL" -gt 0 ] && exit 1; exit 0; }

# SKIPPED: bin/mutation-probe.sh kill verification for the two strict constants.
# Because: the probe only rewrites single-line `const NAME = /re/;` declarations, and both
#   strict regexes are RETURN VALUES of suffixesToMentionRe()/markerMentionRe() — the same
#   limitation already recorded in mention-gate-boundary-cases.sh for the wide pair.
# Alternative: the MGS-divergence rows are the hand-written kill test. Replacing the strict
#   boundary with the wide one reddens every one of them.
if [ ! -f "$PB" ]; then
    fail "MGS0 hooks/lib/protected-basenames.js missing — every case below would be vacuous"
    report
fi

MGS_OUT="$("$RWT" 40 node -e '
const pb = require(process.argv[1] + "/hooks/lib/protected-basenames.js");
const strict = pb.mentionsProtectedNameStrict;
const wide = pb.mentionsProtectedName;
const CLAIM = ".consuming-0123456789abcdef.tmp";
const rows = [];
const add = (want, label, text) => rows.push([want, label, text]);

// Contexts derived from the SSOT suffix lists, so a suffix added there is covered without
// a hand-copied row (CPR-SSOT). The strict reading must keep EVERY on-disk spelling the
// wide one arms on — it narrows the boundary, it does not shrink the denylist.
for (const s of pb.OFF_CLEARANCE_TOKEN_SUFFIXES) {
  add(true, "plain stem" + s,     "wsid" + s);
  add(true, "absolute path" + s,  "/tmp/wf/wsid" + s);
  add(true, "line start" + s,     s);
  add(true, "uppercased" + s,     ("WSID" + s).toUpperCase());
  add(true, "shell-quoted" + s,   "rm -f \"wsid" + s + "\"");
  add(true, "trailing comma" + s, "removing wsid" + s + ", then continuing");
  add(true, "claim over" + s,     "wsid" + s + CLAIM);
  add(true, "trailing dot" + s,   "wsid" + s + ".");
  add(true, "trailing space" + s, "wsid" + s + " ");
  add(true, "ADS spec" + s,       "wsid" + s + "::$DATA");
}
// CPR-ORTH: the marker half is a separate regex from a separate builder, so it is measured
// rather than assumed to follow the token half.
for (const ms of pb.PROTECTED_MARKER_SUFFIXES) {
  add(true, "marker" + ms,              "rm -f wf/wsid" + ms);
  add(true, "marker claim" + ms,        "wsid" + ms + CLAIM);
  add(true, "marker trailing dot" + ms, "wsid" + ms + ".");
}

// Every negative is text a session legitimately emits — and, on the terminal route, a
// refusal with no workaround if the gate arms on it. First up: the minter this hook block
// message itself tells the user to run.
const negs = [
  ["the minter, bare",        "bash bin/request-off-clearance --target workflow"],
  ["the minter, quoted var",  "bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --category x"],
  ["re-spelled minter",       "bash bin/request-off-mode-clearance --target workflow"],
  ["issue-ref suffix",        "see off-clearance-1780 for the history"],
  ["old hook filename",       "hooks/block-off-clearance-write.js"],
  ["ascii word char after",   "wsid.off-clearanceX"],
  ["underscore after",        "wsid.off-clearance_"],
  ["hyphen after",            "wsid.off-clearance-note"],
  ["no dot boundary left",    "myoff-clearance"],
  ["prose, hyphenated",       "the off-clearance workflow is documented in rules/"],
  ["marker doc path",         "see rules/workflow-off.md and skills/enforce-workflow-off/SKILL.md"],
  ["claim over plain stem",   "/tmp/notes.consuming-0123456789abcdef.tmp"],
  ["dot then word char",      "wsid.off-clearance.x"],
  ["empty string",            ""],
  ["one dot",                 "."],
];
for (const [label, text] of negs) add(false, label, text);

// ReDoS-adjacent: this gate runs on every Bash command, so a pathological input must
// return a verdict rather than hang. The decisive text sits at the very end.
add(false, "long filler, no token",   "a".repeat(100000));
add(false, "long dotted filler only", ".off-clearanc" + "e".repeat(50000));
add(true,  "long filler then token",  "x".repeat(100000) + " wsid.off-clearance");
add(true,  "long filler then marker", "y".repeat(50000) + " wsid.workflow-off");

for (const [want, label, text] of rows) {
  const got = strict(text);
  const tag = want ? "positive" : "negative";
  if (got === want) process.stdout.write("OK|MGS " + tag + " " + label + "\n");
  else process.stdout.write("NG|MGS " + tag + " " + label + " want=" + want + " got=" + got + " text=" + JSON.stringify(text).slice(0, 160) + "\n");
}

// DIVERGENCE — the whole reason the strict reading exists. JS `\w` is ASCII-only, so the
// wide boundary cannot see a multi-byte continuation and arms on a name that is NOT
// protected state. Each row asserts BOTH readings on one text, so a build where the two
// collapsed into one — in either direction — reddens here instead of passing quietly.
// The combining mark is written as an escape on purpose: as a literal, any editor
// normalizing this file to NFC folds e+U+0301 into a precomposed letter and deletes the
// very suffix the row is about, turning it green for the wrong reason.
const diverge = [
  ["CJK letter after the suffix",   "wsid.off-clearance日本語.txt"],
  ["Latin-1 accented letter after", "wsid.off-clearanceé"],
  ["combining mark after",          "wsid.off-clearance" + "́"],
  ["fullwidth digit after",         "wsid.off-clearance１"],
  ["CJK after a marker suffix",     "wsid.workflow-off日"],
  ["CJK after a claimed token",     "wsid.off-clearance" + CLAIM + "日"],
];
let divergeSeen = 0;
for (const [label, text] of diverge) {
  const w = wide(text), s = strict(text);
  if (w === true && s === false) { divergeSeen++; process.stdout.write("OK|MGS divergence " + label + " (wide=true, strict=false)\n"); }
  else process.stdout.write("NG|MGS divergence " + label + " want wide=true/strict=false, got wide=" + w + "/strict=" + s + "\n");
}
// Non-vacuity: without a witness, the refinement invariant below would also hold for a
// strict gate that is a byte-for-byte alias of the wide one.
if (divergeSeen === diverge.length) process.stdout.write("OK|MGS divergence witnessed on all " + divergeSeen + " rows\n");
else process.stdout.write("NG|MGS divergence witnessed on only " + divergeSeen + "/" + diverge.length + " rows — strict may be an alias of wide\n");

// The ORTH counterpart: narrowing on a CONTINUATION must not become silence on ordinary
// Unicode text that never named protected state to begin with.
const uniNegs = [
  ["unrelated unicode filename",   "/tmp/日本語ノート.txt"],
  ["unicode prose, no dot anchor", "資料-off-clearance-説明.md"],
  ["unicode before the stem",      "資料/myoff-clearance"],
];
for (const [label, text] of uniNegs) {
  const w = wide(text), s = strict(text);
  if (w === false && s === false) process.stdout.write("OK|MGS unicode-negative " + label + " (both false)\n");
  else process.stdout.write("NG|MGS unicode-negative " + label + " want both false, got wide=" + w + "/strict=" + s + "\n");
}

// REFINEMENT INVARIANT (CPR-E2C): strict is documented as a refinement of wide, so
// strict(t) => wide(t) must hold for EVERY text this file names. Asserted over the whole
// corpus rather than as per-row expectations, so a future edit letting the strict regex
// reach text the wide one disowns reddens automatically — that shape would leave the
// interpreter route armed on a name no other route protects.
let invChecked = 0, invBad = 0;
const corpus = rows.map((r) => r[2]).concat(diverge.map((r) => r[1]), uniNegs.map((r) => r[1]));
for (const t of corpus) {
  invChecked++;
  if (strict(t) === true && wide(t) !== true) { invBad++; process.stdout.write("NG|MGS refinement broken on " + JSON.stringify(t).slice(0, 120) + "\n"); }
}
if (invBad === 0) process.stdout.write("OK|MGS refinement strict=>wide holds over all " + invChecked + " texts\n");

// TERMINAL FAIL-CLOSED INVARIANT: the strict gate is the last word on the interpreter
// route, so anything classifyProtectedPath protects must stay visible to it — otherwise
// that route approves a write the file-path route blocks. Canonical-UUID stems keep this
// observation-free (#2108), hence env-independent.
const U = "11111111-2222-3333-4444-555555555555";
const clsRows = [
  ["bare token",                  U + ".off-clearance"],
  ["mint intermediate",           U + ".off-clearance.mint.tmp"],
  ["claimed token",               U + ".off-clearance" + CLAIM],
  ["marker",                      U + ".workflow-off"],
  ["marker .tmp",                 U + ".workflow-off.tmp"],
  ["token, trailing dot",         U + ".off-clearance."],
  ["token, trailing space",       U + ".off-clearance "],
  ["token, ADS spec",             U + ".off-clearance::$DATA"],
  ["claimed token, trailing dot", U + ".off-clearance" + CLAIM + "."],
  ["plain scratch file",          "/tmp/notes.txt"],
  ["claim over plain stem",       "/tmp/notes" + CLAIM],
];
for (const [label, text] of clsRows) {
  const cls = pb.classifyProtectedPath(text, {});
  const s = strict(text);
  if (cls === null || s === true) process.stdout.write("OK|MGS terminal-invariant " + label + " (classify=" + cls + ", strict=" + s + ")\n");
  else process.stdout.write("NG|MGS terminal-invariant " + label + " classify=" + cls + " but strict=false — the interpreter route cannot see a name the classifier protects\n");
}

// Type discipline: the gate runs on arbitrary extracted text, so a non-string is an
// answer, never a throw.
const edges = [["null", null], ["undefined", undefined], ["number", 42], ["object", {}], ["array", []], ["function", () => {}], ["symbol", Symbol("s")]];
for (const [desc, bad] of edges) {
  let got, threw = null;
  try { got = strict(bad); } catch (e) { threw = (e && e.message) || "throw"; }
  if (threw !== null) process.stdout.write("NG|MGS edge non-string " + desc + " threw: " + threw + "\n");
  else if (got === false) process.stdout.write("OK|MGS edge non-string " + desc + " -> false\n");
  else process.stdout.write("NG|MGS edge non-string " + desc + " want=false got=" + got + "\n");
}
process.stdout.write("DONE|" + rows.length + "\n");
' "$_AGENTS_DIR_NODE" 2>&1)"

echo "=== MGS: mentionsProtectedNameStrict matrix (suffix x context, negatives, unicode divergence, invariants) ==="
MGS_DONE=no
while IFS= read -r line; do
    case "$line" in
        OK\|*)   pass "${line#OK|}" ;;
        NG\|*)   fail "${line#NG|}" ;;
        DONE\|*) MGS_DONE=yes ;;
        "")      ;;
        *)       echo "  (node stderr: $line)" ;;
    esac
done <<< "$MGS_OUT"

# A node crash prints nothing, and this file would still exit 0 with "0 passed, 0 failed".
if [ "$MGS_DONE" = "yes" ]; then
    pass "MGS-run the matrix ran to completion"
else
    fail "MGS-run the matrix did NOT complete (node crashed or timed out); output=$MGS_OUT"
fi

report

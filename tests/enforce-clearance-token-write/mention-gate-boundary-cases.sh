#!/usr/bin/env bash
# tests/enforce-clearance-token-write/mention-gate-boundary-cases.sh
# Tests: hooks/lib/protected-basenames.js
# Tags: off-clearance, clearance-token, mention-gate, TOKEN_MENTION_RE, boundary, consume-claim, table-driven, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap: unit-level on the regex; the four consumers of mentionsProtectedName are
# covered behaviourally by the sibling sections and the parent suite.
# #1821: TOKEN_MENTION_RE is a bare /off-clearance/i today, so any text containing the
# substring arms Tier-1 — the minter the hook's own message advertises included. The fix
# anchors it on the dotted suffix with a [\w.-] right-boundary; this is the CPR-UNV
# boundary matrix for it. Negatives are RED before the fix. Name follows the sibling
# <topic>-cases.sh files here, not the repo-wide <area>-<issue>-<topic>.sh.

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

# SKIPPED: bin/mutation-probe.sh kill verification for TOKEN_MENTION_RE.
# Because: the probe only detects the single-line `const NAME = /re/;` form. TOKEN_MENTION_RE
#   is a return value of suffixesToMentionRe() (protected-basenames.js:100) and
#   MARKER_MENTION_RE is a multi-line new RegExp(...), so neither is reachable by it. Measured:
#   running the probe against this file detects 2 kills (CONSUMING_CLAIM_SUFFIX_RE and
#   BASH_STEM_RESIDUE_RE, both KILLED at score 100%); the 2 mention-gate constants are never probed.
# TL3 gap: none (the probe is a static mutation tool with no real-environment element).
# Alternative: the MGB negative rows below are the hand-written kill test — reverting the gate
# to a bare /off-clearance/i reddens them across the board, so the kill capability is guaranteed.
if [ ! -f "$PB" ]; then
    fail "MGB0 hooks/lib/protected-basenames.js missing — every case below would be vacuous"
    report
fi

# want=true on the MGB unicode rows below is NOT an endorsement of the behaviour — it PINS it:
# JS `\w` is ASCII-only, so `(?![\w.-])` cannot reject a multi-byte continuation and Tier-1
# over-arms on names that are not protected state. On the redirect / touch / Write-tool route
# the downstream classifyProtectedPath returns null and falls back to approve; on the
# interpreter route it does not fall back, so the over-block persists. That end-to-end
# behaviour is measured by unicode-boundary-e2e-cases.sh, which holds it RED against the
# correct contract (approve) — these rows fix Tier-1 alone, not the e2e expected value.

# The whole matrix is generated and evaluated inside one node process: the positive half
# is DERIVED from OFF_CLEARANCE_TOKEN_SUFFIXES, so a suffix added to the SSOT list is
# covered here automatically instead of needing a hand-copied row (CPR-SSOT).
MGB_OUT="$("$RWT" 40 node -e '
const pb = require(process.argv[1] + "/hooks/lib/protected-basenames.js");
const sufs = pb.OFF_CLEARANCE_TOKEN_SUFFIXES;
const rows = [];
const add = (want, label, text) => rows.push([want, label, text]);

// Six contexts per suffix, each a shape the guard genuinely sees: a bare stem, an
// absolute path, the suffix alone at line start, an upper-cased spelling (the gate is
// /i), a shell-quoted argument, and a sentence where the mention is followed by
// punctuation outside [\w.-], which must not defeat the right-boundary.
for (const s of sufs) {
  add(true, "plain stem",      "wsid" + s);
  add(true, "absolute path",   "/tmp/wf/wsid" + s);
  add(true, "line start",      s);
  add(true, "uppercased",      ("WSID" + s).toUpperCase());
  add(true, "shell-quoted",    "rm -f \"wsid" + s + "\"");
  add(true, "trailing comma",  "removing wsid" + s + ", then continuing");
}

// The negative column: every one is a legitimate string a session may emit, and every
// one arms the bare gate today. request-off-clearance is the minter the block message
// itself advertises (#1821 comment 5); the rest are the general class.
const negs = [
  ["the minter, bare",        "bash bin/request-off-clearance --target workflow"],
  ["the minter, quoted var",  "bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --category x"],
  ["re-spelled minter",       "bash bin/request-off-mode-clearance --target workflow"],
  ["issue-ref suffix",        "see off-clearance-1780 for the history"],
  ["old hook filename",       "hooks/block-off-clearance-write.js"],
  ["dot but wrong extension", "x.off-clearance.txt"],
  ["word char right after",   "wsid.off-clearanceX"],
  ["hyphen right after",      "wsid.off-clearance-note"],
  ["no dot boundary left",    "myoff-clearance"],
  ["mint lock without .tmp",  "wsid.off-clearance.mint.lock"],
  ["prose, hyphenated",       "the off-clearance workflow is documented in rules/"],
];
for (const [label, text] of negs) add(false, label, text);

// Non-regression: the marker half of mentionsProtectedName is a separate regex and must
// keep its own verdicts while the token half is narrowed (CPR-SC).
add(true,  "marker .workflow-off", "rm -f wf/wsid.workflow-off");
add(false, "marker doc path",      "see rules/workflow-off.md and skills/enforce-workflow-off/SKILL.md");

// #1821 F1 — the consume-claim wrapper. consume-exact-file.js writes
// `<path>.consuming-<16hex>.tmp` during its exclusive-open window, and the WRITE-side
// classifier strips that suffix and re-classifies, so a claim over a protected name IS
// protected state (pre-create => EEXIST DoS). Tier-1 must see the same names, or the
// interpreter route approves what the file-path route blocks. Derived from the SSOT
// suffix lists, so a new suffix is covered without a hand-copied row (CPR-SSOT).
const CLAIM = ".consuming-0123456789abcdef.tmp";
for (const s of sufs) {
  add(true, "claim over " + s,           "wsid" + s + CLAIM);
  add(true, "claim over " + s + ", abs", "/tmp/wf/wsid" + s + CLAIM);
}
// CPR-ORTH: the marker half of the gate has the identical omission.
for (const ms of pb.PROTECTED_MARKER_SUFFIXES) {
  add(true, "marker claim over " + ms, "wsid" + ms + CLAIM);
}
add(true, "claim, uppercase hex", "wsid.off-clearance.consuming-0123456789ABCDEF.tmp");

// The claim suffix is a PRECISE shape; widening the gate to cover it must not widen it
// to anything merely claim-SHAPED, or every `.tmp` scratch file arms Tier-1.
const claimNegs = [
  ["claim body not hex",        "wsid.off-clearance.consuming-ZZZZZZZZZZZZZZZZ.tmp"],
  ["claim body 15 hex",         "wsid.off-clearance.consuming-0123456789abcde.tmp"],
  ["claim body 17 hex",         "wsid.off-clearance.consuming-0123456789abcdef0.tmp"],
  ["claim without .tmp",        "wsid.off-clearance.consuming-0123456789abcdef"],
  ["claim, word char after",    "wsid.off-clearance.consuming-0123456789abcdef.tmpX"],
  ["claim over unprotected stem", "/tmp/notes.consuming-0123456789abcdef.tmp"],
];
for (const [label, text] of claimNegs) add(false, label, text);

// #1821 — the tail the FILESYSTEM discards before the file exists. Windows strips
// trailing spaces and dots from a component and an NTFS `::$DATA` spec writes the
// BASE file, so `wsid.off-clearance.` IS the token on disk; normalizeCandidateBasename
// already reads it that way, and the gate must agree or the invariant below splits.
// Derived from the SSOT suffix list, and asserted for the marker half too (CPR-ORTH).
for (const s of sufs) {
  add(true, "trailing dot after " + s,    "wsid" + s + ".");
  add(true, "trailing dots after " + s,   "wsid" + s + "...");
  add(true, "trailing space after " + s,  "wsid" + s + " ");
  add(true, "ADS spec after " + s,        "wsid" + s + "::$DATA");
  add(true, "claim + trailing dot on " + s, "wsid" + s + CLAIM + ".");
}
add(true, "marker + trailing dot", "rm -f wf/wsid.workflow-off.");
// The tail is discarded, not a wildcard: a word character after it still breaks the
// boundary, so the widening cannot leak into ordinary dotted filenames.
const tailNegs = [
  ["dot then extension",        "x.off-clearance.txt"],
  ["dot then word char",        "wsid.off-clearance.x"],
  ["dots then word char",       "wsid.off-clearance...x"],
  ["marker dot then extension", "see rules/workflow-off.md"],
];
for (const [label, text] of tailNegs) add(false, label, text);

// #1821 C4 — the ASCII-only reach of `\w`. `(?![\w.-])` rejects an ASCII letter after the
// suffix ("word char right after" above) but NOT a multibyte one, so these arm the gate on
// a name that is not protected state. Out of scope for this PR and fail-CLOSED, so the
// rows PIN today behaviour rather than demand rejection — see the Skipped-Because above.
const uniPos = [
  ["unicode CJK right after",       "wsid.off-clearance日本語.txt"],
  ["unicode Latin-1 accent after",  "wsid.off-clearanceé"],
  ["unicode combining mark after",  "wsid.off-clearancé"],
  ["unicode fullwidth digit after", "wsid.off-clearance１"],
  ["unicode marker suffix after",   "wsid.workflow-off日"],
];
for (const [label, text] of uniPos) add(true, label, text);
// The ORTH counterpart: over-arming on a *continuation* must not become over-arming on any
// Unicode text. A non-ASCII filename with no dotted protected suffix stays silent.
const uniNeg = [
  ["unrelated unicode filename", "/tmp/日本語ノート.txt"],
  ["unicode prose, no dot anchor", "資料-off-clearance-説明.md"],
  ["unicode before the stem",    "資料/myoff-clearance"],
];
for (const [label, text] of uniNeg) add(false, label, text);

// Edge inputs. mentionsProtectedName guards its own type, and the gate runs on every
// Bash command, so a pathological input must return a verdict rather than throw or hang.
// The long rows are the ReDoS-adjacent shape: a huge run of the boundary character class
// with the decisive character only at the very end.
add(false, "empty string", "");
add(false, "one dot",      ".");
add(false, "long filler, no token",   "a".repeat(100000));
add(false, "long dotted filler only", ".off-clearanc" + "e".repeat(50000));
add(true,  "long filler then token",  "x".repeat(100000) + " wsid.off-clearance");

for (const bad of [null, undefined, 42, {}, [], () => {}, Symbol("s")]) {
  const desc = typeof bad === "symbol" ? "symbol" : String(bad === null ? "null" : typeof bad);
  let got, threw = null;
  try { got = pb.mentionsProtectedName(bad); } catch (e) { threw = e && e.message; }
  if (threw !== null) process.stdout.write("NG|MGB edge non-string " + desc + " threw: " + threw + "\n");
  else if (got === false) process.stdout.write("OK|MGB edge non-string " + desc + " -> false\n");
  else process.stdout.write("NG|MGB edge non-string " + desc + " want=false got=" + got + "\n");
}

for (const [want, label, text] of rows) {
  const got = pb.mentionsProtectedName(text);
  const tag = want ? "positive" : "negative";
  if (got === want) process.stdout.write("OK|MGB " + tag + " " + label + "\n");
  else process.stdout.write("NG|MGB " + tag + " " + label + " want=" + want + " got=" + got + " text=" + JSON.stringify(text).slice(0, 160) + "\n");
}
// INVARIANT (the defect CLASS of #1821 restated, CPR-E2C): the Tier-1 mention gate and
// the write-side classifier are two readings of the same question, so
//   classifyProtectedPath(t) !== null  =>  mentionsProtectedName(t) === true
// must hold for EVERY text, or one route approves what the other blocks. Asserted as a
// cross-check rather than as hand-copied expectations, so any future divergence between
// the two readings reddens here automatically. A canonical-UUID stem is used because it
// is clearance-bearing observation-free (#2108), keeping the row env-independent.
const U = "11111111-2222-3333-4444-555555555555";
const invRows = [
  ["bare token",              U + ".off-clearance"],
  ["claimed token",           U + ".off-clearance" + CLAIM],
  ["claimed mint intermediate", U + ".off-clearance.mint.tmp" + CLAIM],
  ["claimed marker",          U + ".workflow-off" + CLAIM],
  ["claimed marker .tmp",     U + ".workflow-off.tmp" + CLAIM],
  ["claim over unprotected stem", "/tmp/notes" + CLAIM],
  ["claim body not hex",      U + ".off-clearance.consuming-ZZZZZZZZZZZZZZZZ.tmp"],
  ["plain scratch file",      "/tmp/notes.txt"],
  // The strippable tail, on both readings of the name. These were the measured
  // split: classify said "token" while the gate said "no mention", so the
  // terminal interpreter route ALLOWED a write that lands on the real token.
  ["token, trailing dot",     U + ".off-clearance."],
  ["token, trailing space",   U + ".off-clearance "],
  ["token, ADS spec",         U + ".off-clearance::$DATA"],
  ["claimed token, trailing dot", U + ".off-clearance" + CLAIM + "."],
  ["claimed token, ADS spec",     U + ".off-clearance" + CLAIM + "::$DATA"],
  ["marker, trailing dot",    U + ".workflow-off."],
];
let invChecked = 0;
for (const [label, text] of invRows) {
  const cls = pb.classifyProtectedPath(text, {});
  const mention = pb.mentionsProtectedName(text);
  invChecked++;
  if (cls === null || mention === true) {
    process.stdout.write("OK|MGB invariant " + label + " (classify=" + cls + ", mention=" + mention + ")\n");
  } else {
    process.stdout.write("NG|MGB invariant " + label + " classify=" + cls + " but mention=false — the write-side classifier protects a name Tier-1 cannot see\n");
  }
}
if (invChecked !== invRows.length) process.stdout.write("NG|MGB invariant table did not run in full\n");
process.stdout.write("DONE|" + rows.length + "\n");
' "$_AGENTS_DIR_NODE" 2>&1)"

echo "=== MGB: TOKEN_MENTION_RE boundary matrix (suffix x context + negatives + consume-claim + classifier invariant) ==="
MGB_DONE=no
while IFS= read -r line; do
    case "$line" in
        OK\|*)   pass "${line#OK|}" ;;
        NG\|*)   fail "${line#NG|}" ;;
        DONE\|*) MGB_DONE=yes ;;
        "")      ;;
        *)       echo "  (node stderr: $line)" ;;
    esac
done <<< "$MGB_OUT"

# Without this the whole matrix could vanish (a node crash prints nothing) and the file
# would still exit 0 with "0 passed, 0 failed" — the classic vacuous green.
if [ "$MGB_DONE" = "yes" ]; then
    pass "MGB-run the matrix ran to completion"
else
    fail "MGB-run the matrix did NOT complete (node crashed or timed out); output=$MGB_OUT"
fi

report

# shellcheck shell=bash
# Tests: hooks/lib/rules-policy-reader.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, policy-reader, load-policy, parse-dont-evaluate, canary, idempotency, TL2, scope:common
#
# loadPolicyAsData(): the composed entry point every consumer actually calls.
#
# WHY the canary (CPR-ORTH with P11 in tests/bin-check-on-demand-rules/cases-policy.sh and A2a in tests/cc-on-demand-skill-ownership/cases-require-safety.sh): those two pin the CONSUMERS; this group pins the READER ITSELF — the single place whose failure would make both of them wrong at once. A fixture policy whose module body writes a file is loaded, and the assertion is that the file was never created.
# The documented contract split is asserted directly: present-but-unparseable declaration -> null (scalars) / [] (arrays); unreadable file -> THROWS. A caller that cannot tell those two apart would read a mistyped policy path as a legitimately empty policy and pass every per-rule assertion vacuously.
# Assumes BASE, READER_NODE, POLICY_NODE, node_path(), run_rows(), assert_rows(), assert_eq(), pass(), fail() from the dispatcher.

echo ""
echo "=== loadPolicyAsData: fixtures, degraded declarations, and the parse-only canary ==="

LP_DIR="$BASE/lp"
mkdir -p "$LP_DIR"
LP_CANARY="$LP_DIR/POLICY-BODY-EXECUTED.txt"
# Normalized for node: a POSIX-looking path handed to node on this host would land
# somewhere the shell-side existence check never looks, and the case would pass wrongly.
LP_CANARY_NODE="$(node_path "$LP_CANARY")"

# --- fixture 1: well-formed, plus a module body that ACTS ---------------------------
cat > "$LP_DIR/policy-canary.js" <<LP_CANARY_EOF
"use strict";
// Hostile-but-well-formed: every declaration is correct, and the body writes a file.
// Only "did the body run" separates a parse from an execute, which is exactly why the
// extracted VALUES alone cannot be the assertion.
require("fs").writeFileSync("$LP_CANARY_NODE", "executed");
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_READERS = ["rules/docs.md|skills/update-docs/SKILL.md", "rules/test.md|skills/write-tests/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/git.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
LP_CANARY_EOF

# --- fixture 2: declarations PRESENT but computed, so a text parser cannot recover them
cat > "$LP_DIR/policy-degraded.js" <<'LP_DEGRADED_EOF'
"use strict";
const parts = ["rules", "docs.md"];
const ON_DEMAND_TOKEN = [".on-demand-only", "never-match"].join("/");
const ON_DEMAND_MARKER_RE = new RegExp("<!--\\s*injection:");
const ON_DEMAND_READERS = parts.map((p) => p);
const EXPECTED_UNCONDITIONAL = ON_DEMAND_READERS.slice(0, 0);
const MINIMIZED_UNCONDITIONAL = ON_DEMAND_READERS.slice();
const MINIMIZED_MAX_BYTES = String(500 * 3);
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
LP_DEGRADED_EOF

# --- fixture 3: the commented-decoy attack, at the composed level ------------------
# WHY (CPR-WPH): this file is contributor-editable data that the pre-commit checker and
# the session audit hook both read. A commented-out declaration parked ABOVE the real one
# used to win, because the parser matched the first textual occurrence of the NAME — so a
# line every reviewer skims past as "just a comment" silently became the value the gate
# ran on (a bigger byte ceiling, a decoy token, a decoy reader table). The reader now
# anchors on a real const/let/var declaration at line start, so the REAL declaration wins
# and the decoy is invisible. Pinned at the composed level as well as in cases-scalars.sh
# because loadPolicyAsData is what every consumer actually calls.
cat > "$LP_DIR/policy-comment-decoy.js" <<'LP_DECOY_EOF'
"use strict";
// const ON_DEMAND_TOKEN = ".decoy-token/never-match";
// const ON_DEMAND_READERS = ["rules/decoy.md|skills/decoy/SKILL.md"];
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_READERS = ["rules/real.md|skills/real/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/git.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
LP_DECOY_EOF

# --- fixture 4: a reader row with NO `|` separator ----------------------------------
# The composed level must preserve the malformed/empty distinction readPairArrayConst
# draws: the row keeps its key (so the rule still appears in the derived flat list) but
# carries values===null, which is what lets bin/lib/check-on-demand-rules.js NAME the
# row that forgot its readers instead of dropping it.
cat > "$LP_DIR/policy-malformed-row.js" <<'LP_MALFORMED_EOF'
"use strict";
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_READERS = ["rules/orphan.md"];
const EXPECTED_UNCONDITIONAL = ["rules/git.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
LP_MALFORMED_EOF

cat > "$BASE/h-load.js" <<'LOAD_EOF'
"use strict";
// argv: <reader> <lp-dir> <real-policy-path>
const path = require("path");
const R = require(process.argv[2]);
const LP = process.argv[3];
const REAL = process.argv[4];

const rows = [];
let pipes = 0;
function row(name, want, got) {
  if (String(want).includes("|") || String(got).includes("|")) pipes += 1;
  rows.push(["ROW", name, want, got].join("|"));
}
const encS = (v) => (v === null ? "NULL" : "S:" + v);
const encA = (v) => (v === null ? "NULL" : "A:" + JSON.stringify(v));
const MARKER = "<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->";

// --- the well-formed fixture ------------------------------------------------------
const p1 = R.loadPolicyAsData(path.join(LP, "policy-canary.js"));
row("load-token", "S:.on-demand-only/never-match", encS(p1.ON_DEMAND_TOKEN));
row("load-files", "A:[\"rules/docs.md\",\"rules/test.md\"]", encA(p1.ON_DEMAND_FILES));
row("load-unconditional", "A:[\"rules/git.md\"]", encA(p1.EXPECTED_UNCONDITIONAL));
row("load-marker-is-regexp", "yes", p1.ON_DEMAND_MARKER_RE instanceof RegExp ? "yes" : "no");
row("load-marker-has-no-g", "no", p1.ON_DEMAND_MARKER_RE.flags.includes("g") ? "yes" : "no");
row("load-marker-accepts-canonical", "true", String(p1.ON_DEMAND_MARKER_RE.test(MARKER)));
row("load-marker-rejects-near-miss", "false",
    String(p1.ON_DEMAND_MARKER_RE.test("<!-- injection: on-demand-only-ish -->")));

// --- degraded: present but unparseable -> null for scalars, [] for arrays -----------
const p2 = R.loadPolicyAsData(path.join(LP, "policy-degraded.js"));
row("degraded-token-is-null", "NULL", encS(p2.ON_DEMAND_TOKEN));
row("degraded-marker-is-null", "NULL", p2.ON_DEMAND_MARKER_RE === null ? "NULL" : "NOT_NULL");
row("degraded-files-is-empty-array", "A:[]", encA(p2.ON_DEMAND_FILES));
row("degraded-unconditional-is-empty-array", "A:[]", encA(p2.EXPECTED_UNCONDITIONAL));
// MINIMIZED_UNCONDITIONAL keeps its THIRD state: null means "the class was never
// recoverable", which is what makes bin/lib/check-on-demand-rules.js fail closed instead
// of reading a computed declaration as an empty (and therefore unchecked) class.
row("degraded-minimized-is-null", "NULL",
    p2.MINIMIZED_UNCONDITIONAL === null ? "NULL" : encA(p2.MINIMIZED_UNCONDITIONAL));
row("degraded-max-bytes-is-null", "NULL", encS(p2.MINIMIZED_MAX_BYTES));

// --- the commented decoy must LOSE at the composed level ---------------------------
const p3 = R.loadPolicyAsData(path.join(LP, "policy-comment-decoy.js"));
row("decoy-commented-token-loses-to-real", "S:.on-demand-only/never-match", encS(p3.ON_DEMAND_TOKEN));
row("decoy-commented-readers-lose-to-real", "A:[\"rules/real.md\"]", encA(p3.ON_DEMAND_FILES));

// --- the REAL repo policy: the reader must recover the shipped declarations ---------
// Non-circular: the values compared against are the canonical literals this repo's
// mechanism is defined by, not values re-derived from the same parse.
const p4 = R.loadPolicyAsData(REAL);
row("real-token", "S:.on-demand-only/never-match", encS(p4.ON_DEMAND_TOKEN));
row("real-marker-accepts-canonical", "true", String(p4.ON_DEMAND_MARKER_RE.test(MARKER)));
row("real-marker-rejects-prose", "false",
    String(p4.ON_DEMAND_MARKER_RE.test("The injection: on-demand-only convention is described here.")));
row("real-files-non-empty", "yes", p4.ON_DEMAND_FILES.length > 0 ? "yes" : "no");
row("real-unconditional-non-empty", "yes", p4.EXPECTED_UNCONDITIONAL.length > 0 ? "yes" : "no");
row("real-lists-are-disjoint", "yes",
    p4.ON_DEMAND_FILES.filter((x) => p4.EXPECTED_UNCONDITIONAL.includes(x)).length === 0 ? "yes" : "no");
row("real-every-entry-is-a-rules-md", "yes",
    p4.ON_DEMAND_FILES.concat(p4.EXPECTED_UNCONDITIONAL)
      .every((x) => /^rules\/[\w./-]+\.md$/.test(x)) ? "yes" : "no");

// --- ROUND-TRIP: all SIX declared constants come back from the REAL policy ----------
// WHY here and not only in the consumers: loadPolicyAsData is the single seam between the
// shipped declaration file and every consumer of it. A declaration reformatted onto two
// lines, or renamed, still passes JS syntax review and still exports correctly — and this
// text parser would return null for it, silently blanking the class. The rows below are
// the shipped-file round trip, so a reformat fails HERE, next to the parser, rather than
// as a mystery clean verdict in pre-commit.
row("real-readers-rows-nonzero", "yes", p4.ON_DEMAND_READERS.length > 0 ? "yes" : "no");
row("real-readers-every-row-names-a-reader", "yes",
    p4.ON_DEMAND_READERS.every((r) => Array.isArray(r.values) && r.values.length > 0) ? "yes" : "no");
row("real-minimized-is-recoverable", "yes", p4.MINIMIZED_UNCONDITIONAL !== null ? "yes" : "no");
row("real-minimized-rows-nonzero", "yes",
    (p4.MINIMIZED_UNCONDITIONAL || []).length > 0 ? "yes" : "no");
row("real-minimized-every-row-names-a-pointer", "yes",
    (p4.MINIMIZED_UNCONDITIONAL || []).every((r) => Array.isArray(r.values) && r.values.length === 1)
      ? "yes" : "no");
// DERIVED, and still able to fail: the minimized class is declared a subset of
// EXPECTED_UNCONDITIONAL and disjoint from the on-demand keys. Both sides are read from
// DIFFERENT declarations, so moving a rule out of one without the other turns these red.
row("real-minimized-subset-of-unconditional", "yes",
    (p4.MINIMIZED_UNCONDITIONAL || []).every((r) => p4.EXPECTED_UNCONDITIONAL.includes(r.key))
      ? "yes" : "no");
row("real-minimized-disjoint-from-on-demand", "yes",
    (p4.MINIMIZED_UNCONDITIONAL || []).every((r) => !p4.ON_DEMAND_FILES.includes(r.key))
      ? "yes" : "no");
// HARD-CODED on purpose (the two rows below): a value derived from the same parse would
// assert the policy equals itself. MINIMIZED_MAX_BYTES is the agreed ceiling for the
// escape hatches, and the key set is the settled membership of the class — both are
// deliberate regression floors and must be updated in the same commit as the policy.
row("real-max-bytes-literal", "S:1500", encS(p4.MINIMIZED_MAX_BYTES));
row("real-minimized-keys",
    "A:[\"rules/stop-guard-exemptions.md\",\"rules/supervisor-reporting.md\",\"rules/workflow-off.md\"]",
    encA((p4.MINIMIZED_UNCONDITIONAL || []).map((r) => r.key)));

// --- a malformed reader row survives the composition, it is not dropped -------------
const p5 = R.loadPolicyAsData(path.join(LP, "policy-malformed-row.js"));
row("malformed-row-keeps-its-key-in-derived-files", "A:[\"rules/orphan.md\"]", encA(p5.ON_DEMAND_FILES));
row("malformed-row-values-are-null-not-empty", "NULL",
    p5.ON_DEMAND_READERS[0].values === null ? "NULL" : encA(p5.ON_DEMAND_READERS[0].values));

// --- unreadable file THROWS (the other half of the contract) -----------------------
let missingVerdict = "NO_THROW";
try {
  R.loadPolicyAsData(path.join(LP, "does-not-exist.js"));
} catch (e) {
  missingVerdict = e && e.code ? e.code : "THREW";
}
row("absent-file-throws-enoent", "ENOENT", missingVerdict);

// --- idempotency: a pure parse read twice must be deeply identical -----------------
const a = R.loadPolicyAsData(path.join(LP, "policy-canary.js"));
const b = R.loadPolicyAsData(path.join(LP, "policy-canary.js"));
const norm = (p) => JSON.stringify({
  t: p.ON_DEMAND_TOKEN, f: p.ON_DEMAND_FILES, e: p.EXPECTED_UNCONDITIONAL,
  r: p.ON_DEMAND_MARKER_RE ? p.ON_DEMAND_MARKER_RE.source + "/" + p.ON_DEMAND_MARKER_RE.flags : null,
});
row("idempotent-second-load-identical", "yes", norm(a) === norm(b) ? "yes" : "no");

rows.push("PIPEGUARD=" + pipes);
console.log(rows.join("\n"));
LOAD_EOF

LP_REPORT="$(run_rows "$BASE/h-load.js" "$(node_path "$LP_DIR")" "$POLICY_NODE")"
assert_rows "S3" "$LP_REPORT" 35

# --- S3-canary: the whole point. The fixture policy above was loaded FOUR times (once
# for the value rows, twice more for idempotency). A require()-based reader would have
# executed its body on the first load and written the canary. ---
if [ -e "$LP_CANARY" ]; then
    fail "S3-canary: loadPolicyAsData EXECUTED the policy module body (canary written at $LP_CANARY) — every consumer's parse-don't-evaluate guarantee rests on this module, so a require() here defeats all of them at once"
else
    pass "S3-canary: the policy module body never executed across four loadPolicyAsData calls — no canary was written"
fi

# --- S3-throwing-body: the second half of "never executed". A module body that THROWS
# kills a require()-based reader outright; a parser never notices it is there. ---
cat > "$LP_DIR/policy-throw.js" <<'LP_THROW_EOF'
"use strict";
throw new Error("policy module body executed");
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_READERS = ["rules/thrown.md|skills/thrown/SKILL.md"];
const EXPECTED_UNCONDITIONAL = [];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
LP_THROW_EOF
LP_THROW_RC=0
LP_THROW_OUT="$( ( cd "$BASE" && node -e '
const R = require(process.argv[1]);
const p = R.loadPolicyAsData(process.argv[2]);
process.stdout.write(JSON.stringify(p.ON_DEMAND_FILES));
' "$READER_NODE" "$(node_path "$LP_DIR/policy-throw.js")" ) 2>&1 )" || LP_THROW_RC=$?
if [ "$LP_THROW_RC" = "0" ] && [ "$LP_THROW_OUT" = '["rules/thrown.md"]' ]; then
    pass "S3-throwing-body: a throwing policy module body neither ran nor propagated, and the declaration was still recovered"
else
    fail "S3-throwing-body: want rc=0 with [\"rules/thrown.md\"], got rc=$LP_THROW_RC out='$(printf '%s' "$LP_THROW_OUT" | tr '\n' ' ' | cut -c1-300)'"
fi

# --- S3-static: a reintroduced eval/require inside the reader itself would not
# necessarily trip the canary (a lazy require in an unexercised branch, for instance), so
# the reader SOURCE is asserted directly: it may read bytes, and nothing else. ---
LP_EVAL_RE='\beval[[:space:]]*\(|new[[:space:]]+Function[[:space:]]*\(|vm\.runIn|child_process|require\([[:space:]]*(policyPath|process\.argv|src)'
LP_BAD="$(grep -nE "$LP_EVAL_RE" "$READER" || true)"
if [ -n "$LP_BAD" ]; then
    fail "S3-static: the reader source reaches for an evaluation primitive — $(printf '%s' "$LP_BAD" | tr '\n' ' ')"
elif ! grep -q 'readFileSync' "$READER"; then
    fail "S3-static: the reader no longer reads the policy with readFileSync — the parse-only contract is unverifiable"
else
    pass "S3-static: the reader source reads bytes (readFileSync) and contains no eval / Function / vm / child_process / dynamic require"
fi

# --- S3-static-mut: that static guard must be able to fail, or it is a false green. ---
LP_MUT="$BASE/reader-mutant.js"
sed 's|const src = fs.readFileSync(policyPath, "utf8");|const src = eval("require")(policyPath);|' \
    "$READER" > "$LP_MUT"
LP_MUT_HITS="$(grep -cE "$LP_EVAL_RE" "$LP_MUT" || true)"
if [ "${LP_MUT_HITS:-0}" -ge 1 ]; then
    pass "S3-static-mut: the static guard fires on a reader that reintroduces an evaluation primitive (hits=$LP_MUT_HITS)"
else
    fail "S3-static-mut: the static guard did not fire on the mutant — S3-static is a false green"
fi

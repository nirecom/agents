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
const ON_DEMAND_FILES = ["rules/docs.md", "rules/test.md"];
const EXPECTED_UNCONDITIONAL = ["rules/git.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
LP_CANARY_EOF

# --- fixture 2: declarations PRESENT but computed, so a text parser cannot recover them
cat > "$LP_DIR/policy-degraded.js" <<'LP_DEGRADED_EOF'
"use strict";
const parts = ["rules", "docs.md"];
const ON_DEMAND_TOKEN = [".on-demand-only", "never-match"].join("/");
const ON_DEMAND_MARKER_RE = new RegExp("<!--\\s*injection:");
const ON_DEMAND_FILES = parts.map((p) => p);
const EXPECTED_UNCONDITIONAL = ON_DEMAND_FILES.slice(0, 0);
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
LP_DEGRADED_EOF

# --- fixture 3: KNOWN LIMITATION L3 at the composed level --------------------------
# A commented-out declaration placed before the real one. The parser has no notion of JS
# comments, so the DECOY wins. This is an accepted limitation tracked as a follow-up and
# is deliberately NOT fixed here; it is pinned so the day the reader learns about comments
# this row fails and the change is reviewed rather than absorbed silently.
cat > "$LP_DIR/policy-comment-decoy.js" <<'LP_DECOY_EOF'
"use strict";
// const ON_DEMAND_TOKEN = ".decoy-token/never-match";
// const ON_DEMAND_FILES = ["rules/decoy.md"];
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_FILES = ["rules/real.md"];
const EXPECTED_UNCONDITIONAL = ["rules/git.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
LP_DECOY_EOF

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

// --- L3 known limitation at the composed level -------------------------------------
const p3 = R.loadPolicyAsData(path.join(LP, "policy-comment-decoy.js"));
row("L3-commented-token-shadows-real", "S:.decoy-token/never-match", encS(p3.ON_DEMAND_TOKEN));
row("L3-commented-files-shadow-real", "A:[\"rules/decoy.md\"]", encA(p3.ON_DEMAND_FILES));

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
assert_rows "S3" "$LP_REPORT" 22

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
const ON_DEMAND_FILES = ["rules/thrown.md"];
const EXPECTED_UNCONDITIONAL = [];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
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

# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js, bin/check-on-demand-rules.sh
# Tags: rules-injection, policy, ssot, set-equality, parse-dont-evaluate, canary, TL2, scope:common

# Declarative SSOT assertions. Length + pathname-shape checks are false-green prone
# (any 17 well-shaped strings would satisfy them), so the allowlist is compared for
# EXACT SET EQUALITY against the real rules/ tree, in both directions:
#   EXPECTED_UNCONDITIONAL == { rules/**/*.md with no `paths:` frontmatter }
#   ON_DEMAND_READERS keys == { rules/**/*.md whose paths: is exactly the token }
# so neither a forgotten registration nor a stale entry can survive.

# PARSE, DON'T EVALUATE (CPR-ORTH with P11 below, and with A2a in
# tests/cc-on-demand-skill-ownership/cases-require-safety.sh): this harness used to obtain
# its constants by require()-ing the contributor-editable policy path. That made the very
# file asserting "the checker must not execute this file" execute it itself, on every run,
# on whatever branch a reviewer had checked out. The constants now come through the
# agents-owned reader (hooks/lib/rules-policy-reader.js), and P12 proves it with the same
# canary shape P11 uses on the checker side.

# The two declarations are read with readStringArrayConst / readPairArrayConst rather
# than taken from loadPolicyAsData, because loadPolicyAsData collapses "declaration
# absent / unparseable" to []. Keeping the raw null lets P3/P4 stay live assertions ("the
# list was actually recovered") instead of tautologies that hold for any policy file.
#
# The on-demand half is the KEY column of ON_DEMAND_READERS (#2037), not a separate
# ON_DEMAND_FILES literal: the rule name is declared exactly once, beside the skills
# required to Read it. Reading the retired literal here instead would make P4/P6 red on
# the very policy P13e demands (one where that literal is gone).

echo ""
echo "=== policy SSOT (exact set equality against the real rules/ tree) ==="

cat > "$BASE/policy-report.js" <<'POLICY_REPORT_EOF'
"use strict";
// argv: <reader> <repo-root> <policy-path> <canonical-marker>
const fs = require('fs'), path = require('path');
const R = require(process.argv[2]);
const repo = process.argv[3];
const policyPath = process.argv[4];

const src = fs.readFileSync(policyPath, 'utf8');
const p = R.loadPolicyAsData(policyPath);
const token = p.ON_DEMAND_TOKEN;

const files = [];
(function walk(d) {
  for (const n of fs.readdirSync(d)) {
    const fp = path.join(d, n);
    if (fs.statSync(fp).isDirectory()) walk(fp);
    else if (n.endsWith('.md')) files.push(fp);
  }
})(path.join(repo, 'rules'));

const plain = [], onDemand = [], mixed = [];
for (const fp of files.sort()) {
  const rel = path.relative(repo, fp).split(path.sep).join('/');
  const text = fs.readFileSync(fp, 'utf8');
  const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (!m || !/^paths:/m.test(m[1])) { plain.push(rel); continue; }
  const items = m[1].split(/\r?\n/)
    .filter((l) => /^\s+-\s/.test(l))
    .map((l) => l.replace(/^\s+-\s+/, '').trim().replace(/^["']|["']$/g, ''));
  if (items.length === 1 && items[0] === token) onDemand.push(rel);
  else if (items.includes(token)) mixed.push(rel);
}

const eq = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());
const diff = (a, b) => a.filter((x) => !b.includes(x));
// null when the declaration could not be recovered from the source text at all.
const eu = R.readStringArrayConst(src, 'EXPECTED_UNCONDITIONAL');
const odRows = typeof R.readPairArrayConst === 'function'
  ? R.readPairArrayConst(src, 'ON_DEMAND_READERS')
  : null;
const od = odRows ? odRows.map((r) => r.key) : null;

const out = [];
out.push('TOKEN=' + p.ON_DEMAND_TOKEN);
out.push('MARKER_MATCH=' + (p.ON_DEMAND_MARKER_RE instanceof RegExp
  && p.ON_DEMAND_MARKER_RE.test(process.argv[5]) ? 'yes' : 'no'));
out.push('EU_IS_ARRAY=' + (eu ? 'yes' : 'no'));
out.push('OD_IS_ARRAY=' + (od ? 'yes' : 'no'));
out.push('EU_EQ_PLAIN=' + (eu && eq(eu, plain) ? 'yes' : 'no'));
out.push('OD_EQ_ANNOTATED=' + (od && eq(od, onDemand) ? 'yes' : 'no'));
out.push('EU_DISJOINT_OD=' + (eu && od && eu.filter((x) => od.includes(x)).length === 0 ? 'yes' : 'no'));
out.push('MIXED_TOKEN_FILES=' + mixed.length);
out.push('EU_ONLY=' + JSON.stringify(eu ? diff(eu, plain) : null));
out.push('PLAIN_ONLY=' + JSON.stringify(eu ? diff(plain, eu) : null));
out.push('OD_ONLY=' + JSON.stringify(od ? diff(od, onDemand) : null));
out.push('ANNOTATED_ONLY=' + JSON.stringify(od ? diff(onDemand, od) : null));
console.log(out.join('\n'));
POLICY_REPORT_EOF

# pol_report <repo-root> <policy-path> -> the harness stdout+stderr
pol_report() {
    node "$(node_path "$BASE/policy-report.js")" "$(node_path "$READER")" \
        "$(node_path "$1")" "$(node_path "$2")" "$MARKER" 2>&1
}

POLICY_REPORT="$(pol_report "$AGENTS_DIR" "$POLICY")"

pfield() { printf '%s\n' "$POLICY_REPORT" | grep "^$1=" | head -1 | cut -d= -f2-; }

check_p() {
    local label="$1" key="$2" want="$3" got
    got="$(pfield "$key")"
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label — $key=$got (want $want); report: $(printf '%s' "$POLICY_REPORT" | tr '\n' ' ')"; fi
}

check_p "P1: ON_DEMAND_TOKEN is the canonical literal" TOKEN "$TOKEN"
check_p "P2: ON_DEMAND_MARKER_RE matches the canonical marker comment" MARKER_MATCH yes
check_p "P3: EXPECTED_UNCONDITIONAL is an array" EU_IS_ARRAY yes
check_p "P4: ON_DEMAND_READERS is a recoverable pair array" OD_IS_ARRAY yes
check_p "P5: EXPECTED_UNCONDITIONAL equals exactly the paths-less rules/**/*.md set" EU_EQ_PLAIN yes
check_p "P6: the ON_DEMAND_READERS key column equals exactly the token-annotated rules/**/*.md set" OD_EQ_ANNOTATED yes
check_p "P7: the two allowlists are disjoint" EU_DISJOINT_OD yes
check_p "P8: no rule mixes the reserved token with other globs" MIXED_TOKEN_FILES 0

# --- P9: the checker itself must reject a token+marker rule that nobody registered.
# This is the bidirectional half the policy comparison cannot cover on its own: the
# real tree has no such file, so only a fixture can exercise it. ---
CASE_N=$((CASE_N + 1)); d="$BASE/pol-rogue$CASE_N"
fx_base "$d"
wr "$d/rules/rogue.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# Correctly annotated, deliberately absent from ON_DEMAND_READERS
EOF
rogue_rc="$(run_checker "$d" all)"
rogue_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$rogue_rc" != "1" ]; then
    fail "P9: an annotated rule missing from ON_DEMAND_READERS must exit 1, got $rogue_rc"
elif ! printf '%s' "$rogue_out" | grep -q 'rules/rogue.md'; then
    fail "P9: exit 1 but the diagnostic never names rules/rogue.md — output: $(printf '%s' "$rogue_out" | head -3 | tr '\n' ' ')"
else
    pass "P9: an annotated rule absent from ON_DEMAND_READERS is rejected"
fi

# --- P10: the mirror image — a registered file that lost its annotation. ---
CASE_N=$((CASE_N + 1)); d="$BASE/pol-stale$CASE_N"
fx_base "$d"
write_policy "$d" '["rules/od.md","rules/plain.md"]' '[]'
stale_rc="$(run_checker "$d" all)"
stale_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$stale_rc" = "1" ] && printf '%s' "$stale_out" | grep -q 'rules/plain.md'; then
    pass "P10: a registered-but-unannotated file is rejected and named"
else
    fail "P10: want exit 1 naming rules/plain.md, got $stale_rc — output: $(printf '%s' "$stale_out" | head -3 | tr '\n' ' ')"
fi

# --- P11: the policy file is DATA, not a program. ---------------------------------
# Why this matters: rules-injection-policy.js is a contributor-editable file that the
# checker reads on every pre-commit run. If the checker obtains its constants by
# `require()`-ing that path, then whatever a contributor writes in the module body runs
# — before review, with the developer's full ambient privileges, on every commit in the
# repository. That is arbitrary code execution reachable through an ordinary pull
# request, and no other case in this suite would notice: a hostile module can export
# exactly the right constants and still have done its work on the way there.

# The canary is a module body with an observable side effect (a file written next to
# the fixture). The assertion is that the side effect did NOT happen.

# STATED PLAINLY, per the review ruling: if the implementation is expected to
# `require()` this module, this case WILL fail, and that failure is not a bug in the
# test. It is the standing record that the constant-shape contract — "the policy file
# contains only literal constant declarations and a module.exports" — has to be
# enforced by some other mechanism (a parse-don't-evaluate reader, or a checker that
# refuses a policy file containing anything beyond constant declarations). The
# assertion is deliberately NOT weakened to "requires are fine as long as the exports
# are right", because that formulation cannot distinguish a policy file from a payload.
CASE_N=$((CASE_N + 1)); d="$BASE/pol-exec$CASE_N"
fx_base "$d"
CANARY="$d/POLICY-BODY-EXECUTED.txt"
# The canary path is normalized for node (cygpath -m on Windows): a POSIX-looking
# /tmp/... path handed to node on this host would land somewhere the shell-side
# existence check never looks, and the case would pass for the wrong reason.
CANARY_NODE="$(node_path "$CANARY")"
cat > "$d/hooks/lib/rules-injection-policy.js" <<POLICY_EXEC_EOF
"use strict";
// Hostile-but-well-formed policy: correct exports, plus a module body that acts.
require("fs").writeFileSync("$CANARY_NODE", "executed");
const ON_DEMAND_TOKEN = "$TOKEN";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_READERS = ["rules/od.md|skills/owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
POLICY_EXEC_EOF
exec_rc="$(run_checker "$d" all)"
exec_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ -e "$CANARY" ]; then
    fail "P11: the checker EXECUTED the contributor-editable policy file (canary written) — a pull request can run code on every commit; the constant-shape contract must be enforced by parsing, not by require() (checker rc=$exec_rc)"
else
    pass "P11: the policy file was read as data — its module body did not execute (rc=$exec_rc)"
fi
unset exec_out

# --- P12: the same contract, applied to THIS SUITE's own harness. ------------------
# Why a second canary: P11 covers the checker. But every assertion P1-P8 above is
# produced by policy-report.js, which also has to obtain the policy constants somehow.
# When that harness used require(), running this suite on a checked-out branch executed
# that branch's policy body — so the file that proves "never execute the policy" was
# itself the execution vector. CPR-ORTH: a symmetric member of the class gets the same
# treatment. The canary shape is identical to P11's; the assertion is the ABSENCE of the
# side effect, plus proof that the harness still recovered the constants (an aborted
# harness would leave no canary either, and must not read as a pass).
CASE_N=$((CASE_N + 1)); d="$BASE/pol-harness-exec$CASE_N"
fx_base "$d"
H_CANARY="$d/HARNESS-EXECUTED-POLICY.txt"
H_CANARY_NODE="$(node_path "$H_CANARY")"
cat > "$d/hooks/lib/rules-injection-policy.js" <<HARNESS_EXEC_EOF
"use strict";
require("fs").writeFileSync("$H_CANARY_NODE", "executed");
const ON_DEMAND_TOKEN = "$TOKEN";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_READERS = ["rules/od.md|skills/owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
HARNESS_EXEC_EOF
H_REPORT="$(pol_report "$d" "$d/hooks/lib/rules-injection-policy.js")"
h_token="$(printf '%s\n' "$H_REPORT" | grep '^TOKEN=' | head -1 | cut -d= -f2-)"
h_od="$(printf '%s\n' "$H_REPORT" | grep '^OD_IS_ARRAY=' | head -1 | cut -d= -f2-)"
if [ -e "$H_CANARY" ]; then
    fail "P12: this suite's own harness EXECUTED the contributor-editable policy file (canary written) — it must read it as data through hooks/lib/rules-policy-reader.js"
elif [ "$h_token" != "$TOKEN" ] || [ "$h_od" != "yes" ]; then
    fail "P12: no canary, but the harness did not recover the constants either (TOKEN=$h_token OD_IS_ARRAY=$h_od) — absence of the side effect proves nothing when the harness aborted; report: $(printf '%s' "$H_REPORT" | tr '\n' ' ' | cut -c1-300)"
else
    pass "P12: the harness read the policy as data — constants recovered, module body did not execute"
fi
unset H_REPORT h_token h_od

# --- P13/P14: ON_DEMAND_READERS is the SSOT; ON_DEMAND_FILES is derived from it (#2037) ---
# WHY: the rule name used to be written twice — once in ON_DEMAND_FILES, once in the
# hand-written ownership table. It now lives once, as the KEY half of each ON_DEMAND_READERS
# row, and the reader republishes ON_DEMAND_FILES as a derived value so existing consumers
# keep working. A derivation bug (dropping a row, keeping the whole `key|readers` string as
# the "file name", deriving from a stale second declaration) would leave every consumer
# grading the tree against a set that no longer matches the declaration, and P5-P8 above
# cannot see it: they compare the derived set to the tree, so both sides move together.
# P14 pins the other half — a row whose separator is missing must surface as MALFORMED
# (values === null) rather than being silently dropped from the derived set.
cat > "$BASE/readers-derivation.js" <<'READERS_DERIV_EOF'
"use strict";
// argv: <reader> <policy-path>
const fs = require("fs");
const R = require(process.argv[2]);
const src = fs.readFileSync(process.argv[3], "utf8");
const out = [];
const have = typeof R.readPairArrayConst === "function";
out.push("HAVE_PAIR_READER=" + (have ? "yes" : "no"));
const pairs = have ? R.readPairArrayConst(src, "ON_DEMAND_READERS") : null;
out.push("READERS_DECLARED=" + (pairs === null ? "no" : "yes"));
out.push("READERS_ROWS=" + (pairs ? pairs.length : -1));
const derived = R.loadPolicyAsData(process.argv[3]).ON_DEMAND_FILES || [];
out.push("DERIVED_COUNT=" + derived.length);
const keys = pairs ? pairs.map((p) => p.key) : null;
// SEQUENCE equality, not set equality: the derived list must be the key column itself.
out.push("KEYS_EQ_DERIVED=" + (keys && JSON.stringify(keys) === JSON.stringify(derived) ? "yes" : "no"));
out.push("EVERY_ROW_HAS_READERS=" +
  (pairs && pairs.every((p) => Array.isArray(p.values) && p.values.length > 0) ? "yes" : "no"));
// The retired declaration must be gone: while both exist, "derived" cannot be proven.
out.push("OLD_FILES_DECL=" + (R.readStringArrayConst(src, "ON_DEMAND_FILES") === null ? "absent" : "present"));
// P14: an element without the separator is MALFORMED, never silently dropped.
const mal = have
  ? R.readPairArrayConst('const ON_DEMAND_READERS = ["rules/a.md|skills/x/SKILL.md","rules/b.md"];', "ON_DEMAND_READERS")
  : null;
out.push("MALFORMED_KEPT=" + (mal && mal.length === 2 ? "yes" : "no"));
out.push("MALFORMED_VALUES_NULL=" + (mal && mal.length === 2 && mal[1].values === null ? "yes" : "no"));
console.log(out.join("\n"));
READERS_DERIV_EOF

RD_REPORT="$(node "$(node_path "$BASE/readers-derivation.js")" "$(node_path "$READER")" "$(node_path "$POLICY")" 2>&1)"
rdfield() { printf '%s\n' "$RD_REPORT" | grep "^$1=" | head -1 | cut -d= -f2-; }
check_rd() {
    local label="$1" key="$2" want="$3" got
    got="$(rdfield "$key")"
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label — $key=$got (want $want); report: $(printf '%s' "$RD_REPORT" | tr '\n' ' ' | cut -c1-400)"; fi
}

check_rd "P13a: the reader exposes readPairArrayConst" HAVE_PAIR_READER yes
check_rd "P13b: ON_DEMAND_READERS is declared in the real policy" READERS_DECLARED yes
check_rd "P13c: derived ON_DEMAND_FILES is exactly the ON_DEMAND_READERS key column, in order" KEYS_EQ_DERIVED yes
check_rd "P13d: every declared row names at least one reader" EVERY_ROW_HAS_READERS yes
check_rd "P13e: the retired ON_DEMAND_FILES literal is gone, so the derived value cannot be shadowed by it" OLD_FILES_DECL absent
check_rd "P14a: a row missing its separator is kept, not silently dropped" MALFORMED_KEPT yes
check_rd "P14b: that row reports values === null (malformed), not [] (zero readers)" MALFORMED_VALUES_NULL yes

# Non-vacuity: an empty declaration would make P13c trivially true (both sides []).
RD_ROWS="$(rdfield READERS_ROWS)"
if [ "${RD_ROWS:-0}" -ge 1 ] 2>/dev/null; then
    pass "P13f: ON_DEMAND_READERS declares $RD_ROWS row(s), so the derivation comparison is live"
else
    fail "P13f: ON_DEMAND_READERS parsed to $RD_ROWS row(s) — P13c would hold for any policy whatsoever"
fi
unset RD_REPORT RD_ROWS

# --- P15: the DEFAULT policy path. Every other harness in this suite exports
# RULES_INJECTION_POLICY, so the documented `<root>/hooks/lib/rules-injection-policy.js`
# fallback is never exercised — a checker that honoured only the env var would pass the
# whole suite and then grade every real pre-commit run against nothing at all. ---
d="$BASE/p15-fallback"
rd_base "$d"
P15_RC="$(run_checker_nopin "$d")"
P15_OUT="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$P15_RC" = "0" ]; then
    pass "P15a: with RULES_INJECTION_POLICY unset, a clean tree passes — the checker found the tree's own policy at the default path"
else
    fail "P15a: want rc=0 from the default-path fallback, got $P15_RC — output: $(printf '%s' "$P15_OUT" | head -6 | tr '\n' ' ' | cut -c1-400)"
fi

# Non-vacuity: rc=0 above would also be produced by a checker that read no policy and
# graded nothing. The same tree with a violation its OWN policy defines must fail.
d="$BASE/p15-fallback-dirty"
rd_base "$d"
rd_policy "$d" '["rules/od.md|skills/ghost/SKILL.md"]' '["rules/plain.md"]'
P15B_RC="$(run_checker_nopin "$d")"
P15B_OUT="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$P15B_RC" = "0" ]; then
    fail "P15b: the default-path fallback returned rc=0 on a tree whose own policy names a nonexistent reader — P15a proves nothing if the checker grades nothing"
elif printf '%s\n' "$P15B_OUT" | grep -q 'rules/od\.md'; then
    pass "P15b: the default-path fallback graded the tree against the tree's OWN policy (rc=$P15B_RC, names rules/od.md)"
else
    fail "P15b: rc=$P15B_RC but the diagnostic never names rules/od.md — the failure may come from the agents repo's policy, not the fixture's; output: $(printf '%s' "$P15B_OUT" | head -6 | tr '\n' ' ' | cut -c1-400)"
fi

# --- P16: the reader matches a constant NAME unanchored (pinned in
# tests/unit-rules-policy-reader/cases-collections.sh). The consequence the checker owns:
# a policy whose real ON_DEMAND_READERS is absent must never be graded against a
# same-suffixed decoy — that would silently declare every on-demand rule owned. ---
d="$BASE/p16-decoy"
rd_base "$d"
cat > "$d/hooks/lib/rules-injection-policy.js" <<DECOY_EOF
"use strict";
const ON_DEMAND_TOKEN = "$TOKEN";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const X_ON_DEMAND_READERS = ["rules/od.md|skills/owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, EXPECTED_UNCONDITIONAL };
DECOY_EOF
P16_RC="$(run_checker "$d" all)"
P16_OUT="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$P16_RC" = "0" ]; then
    fail "P16: ON_DEMAND_READERS is not declared, yet the checker passed the tree (rc=0) — the same-suffixed X_ON_DEMAND_READERS was consumed as the declaration, so rules/od.md reads as owned by a table nobody wrote"
elif printf '%s\n' "$P16_OUT" | grep -q 'rules/od\.md'; then
    pass "P16: an absent ON_DEMAND_READERS fails closed and names the unregistered rule (rc=$P16_RC), rather than borrowing the decoy constant"
else
    fail "P16: rc=$P16_RC but the diagnostic never names rules/od.md — output: $(printf '%s' "$P16_OUT" | head -6 | tr '\n' ' ' | cut -c1-400)"
fi

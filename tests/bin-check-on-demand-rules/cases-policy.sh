# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js, bin/check-on-demand-rules.sh
# Tags: rules-injection, policy, ssot, set-equality, parse-dont-evaluate, canary, TL2, scope:common

# Declarative SSOT assertions. Length + pathname-shape checks are false-green prone
# (any 17 well-shaped strings would satisfy them), so the allowlist is compared for
# EXACT SET EQUALITY against the real rules/ tree, in both directions:
#   EXPECTED_UNCONDITIONAL == { rules/**/*.md with no `paths:` frontmatter }
#   ON_DEMAND_FILES        == { rules/**/*.md whose paths: is exactly the token }
# so neither a forgotten registration nor a stale entry can survive.

# PARSE, DON'T EVALUATE (CPR-ORTH with P11 below, and with A2a in
# tests/cc-on-demand-skill-ownership/cases-require-safety.sh): this harness used to obtain
# its constants by require()-ing the contributor-editable policy path. That made the very
# file asserting "the checker must not execute this file" execute it itself, on every run,
# on whatever branch a reviewer had checked out. The constants now come through the
# agents-owned reader (hooks/lib/rules-policy-reader.js), and P12 proves it with the same
# canary shape P11 uses on the checker side.

# The two array declarations are read with readStringArrayConst rather than taken from
# loadPolicyAsData, because loadPolicyAsData collapses "declaration absent / unparseable"
# to []. Keeping the raw null lets P3/P4 stay live assertions ("the list was actually
# recovered") instead of tautologies that hold for any policy file whatsoever.

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
const od = R.readStringArrayConst(src, 'ON_DEMAND_FILES');

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
check_p "P4: ON_DEMAND_FILES is an array" OD_IS_ARRAY yes
check_p "P5: EXPECTED_UNCONDITIONAL equals exactly the paths-less rules/**/*.md set" EU_EQ_PLAIN yes
check_p "P6: ON_DEMAND_FILES equals exactly the token-annotated rules/**/*.md set" OD_EQ_ANNOTATED yes
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

# Correctly annotated, deliberately absent from ON_DEMAND_FILES
EOF
rogue_rc="$(run_checker "$d" all)"
rogue_out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
if [ "$rogue_rc" != "1" ]; then
    fail "P9: an annotated rule missing from ON_DEMAND_FILES must exit 1, got $rogue_rc"
elif ! printf '%s' "$rogue_out" | grep -q 'rules/rogue.md'; then
    fail "P9: exit 1 but the diagnostic never names rules/rogue.md — output: $(printf '%s' "$rogue_out" | head -3 | tr '\n' ' ')"
else
    pass "P9: an annotated rule absent from ON_DEMAND_FILES is rejected"
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
const ON_DEMAND_FILES = ["rules/od.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
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
const ON_DEMAND_FILES = ["rules/od.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
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

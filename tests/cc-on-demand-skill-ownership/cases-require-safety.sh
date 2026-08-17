# shellcheck shell=bash
# Tests: hooks/lib/rules-policy-reader.js, hooks/lib/rules-injection-policy.js, tests/cc-on-demand-skill-ownership.sh
# Tags: rules-injection, policy, require-safety, arbitrary-code-execution, security, canary, TL2, scope:common

# WHY (CPR-WPH): hooks/lib/rules-injection-policy.js is a contributor-editable declaration file,
# and this suite's ownership reporter reads it on every run — on whatever branch a reviewer has
# checked out. If the reporter obtained its constants by require()-ing that path, merely checking out
# a pull request and running the test suite would execute that PR's module body with the reviewer's
# full ambient privileges — arbitrary code execution reachable through an ordinary pull request.

# The checker side of the same contract is pinned by P11 in
# tests/bin-check-on-demand-rules/cases-policy.sh — this group is its CPR-ORTH sibling for the
# reporter side: same canary shape, same standing record. Assumes BASE, READER, run_owners(),
# node_path(), pass(), fail() from the entry file.

echo ""
echo "=== A: the ownership reporter reads the policy as DATA, never as a program ==="

# rs_fixture <dir> — a minimal owned-rule tree; the caller writes the policy file.
rs_fixture() {
    local d="$1"
    mkdir -p "$d/hooks/lib" "$d/skills/owner" "$d/rules"
    printf '# the owned rule\n' > "$d/rules/owned.md"
    printf '# Owner skill\n\n## Step 1\n\nRead `rules/owned.md` before continuing.\n' \
        > "$d/skills/owner/SKILL.md"
}

# rs_field <report> <field> -> the field's value from the first RULE= row, or "-"
rs_field() {
    local rep="$1" field="$2" v
    v="$(printf '%s\n' "$rep" | grep '^RULE=' | head -1 | tr ' ' '\n' | grep "^$field=" | head -1 | cut -d= -f2-)"
    printf '%s' "${v:--}"
}
# rs_top <report> <key> -> a top-level KEY=value line (OD_COUNT / EU_COUNT), or "-"
rs_top() {
    local v
    v="$(printf '%s\n' "$1" | grep "^$2=" | head -1 | cut -d= -f2-)"
    printf '%s' "${v:--}"
}

# --- A2a: a hostile-but-well-formed policy. Its module body writes a canary file; the
# declarations it exports are entirely correct. Only "did the body run" separates a
# parse from an execute — a require()-based reporter would still produce the right
# numbers, which is exactly why the numbers alone cannot be the assertion. ---
RS_EXEC="$BASE/rs-exec"
rs_fixture "$RS_EXEC"
RS_CANARY="$RS_EXEC/POLICY-BODY-EXECUTED.txt"
# Normalized for node: a POSIX-looking path handed to node on this host would land
# where the shell-side existence check never looks, and the case would pass wrongly.
RS_CANARY_NODE="$(node_path "$RS_CANARY")"
cat > "$RS_EXEC/hooks/lib/rules-injection-policy.js" <<RS_EXEC_EOF
"use strict";
require("fs").writeFileSync("$RS_CANARY_NODE", "executed");
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only\b/;
const ON_DEMAND_READERS = ["rules/owned.md|skills/owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md", "rules/other.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
RS_EXEC_EOF
RS_EXEC_REP="$(run_owners "$RS_EXEC" "$RS_EXEC/hooks/lib/rules-injection-policy.js")"

if [ -e "$RS_CANARY" ]; then
    fail "A2a: the ownership reporter EXECUTED the contributor-editable policy file (canary written) — running this suite on a checked-out branch runs that branch's code; the reporter must obtain its constants through hooks/lib/rules-policy-reader.js"
else
    pass "A2a: the policy module body did not execute — no canary was written"
fi

# --- A2b: the declared values are still extracted correctly. Without this, A2a could
# be satisfied by a reporter that reads nothing at all. ---
if [ "$(rs_top "$RS_EXEC_REP" OD_COUNT)" = "1" ] \
   && [ "$(rs_top "$RS_EXEC_REP" EU_COUNT)" = "2" ] \
   && [ "$(rs_field "$RS_EXEC_REP" RULE)" = "rules/owned.md" ] \
   && [ "$(rs_field "$RS_EXEC_REP" SKILL_READ)" = "1" ]; then
    pass "A2b: ON_DEMAND_READERS(1) and EXPECTED_UNCONDITIONAL(2) were extracted by parsing, and the owner was still resolved"
else
    fail "A2b: parsing lost the declarations — OD_COUNT=$(rs_top "$RS_EXEC_REP" OD_COUNT) EU_COUNT=$(rs_top "$RS_EXEC_REP" EU_COUNT) RULE=$(rs_field "$RS_EXEC_REP" RULE) SKILL_READ=$(rs_field "$RS_EXEC_REP" SKILL_READ); report: $(printf '%s' "$RS_EXEC_REP" | tr '\n' ' ')"
fi

# --- A2c: the second half of "never executed" — a module body that THROWS. A require()
# based reporter dies here and reports nothing; a parser never notices. ---
RS_THROW="$BASE/rs-throw"
rs_fixture "$RS_THROW"
cat > "$RS_THROW/hooks/lib/rules-injection-policy.js" <<'RS_THROW_EOF'
"use strict";
throw new Error("policy module body executed");
const ON_DEMAND_TOKEN = ".on-demand-only/never-match";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only\b/;
const ON_DEMAND_READERS = ["rules/owned.md|skills/owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = [];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
RS_THROW_EOF
RS_THROW_REP="$(run_owners "$RS_THROW" "$RS_THROW/hooks/lib/rules-injection-policy.js")"
if [ "$(rs_top "$RS_THROW_REP" OD_COUNT)" = "1" ] \
   && [ "$(rs_field "$RS_THROW_REP" SKILL_READ)" = "1" ] \
   && ! printf '%s' "$RS_THROW_REP" | grep -q 'policy module body executed'; then
    pass "A2c: a throwing policy module body neither ran nor propagated — the declarations were still read"
else
    fail "A2c: the throw escaped or the declarations were lost — report: $(printf '%s' "$RS_THROW_REP" | tr '\n' ' ')"
fi

# --- A2d: idempotency. Reading the policy is a pure parse, so a second run over the
# same fixture must produce byte-identical output and still leave no canary. A reader
# that cached state, or a require() reached only on a later call, shows up here. ---
RS_EXEC_REP2="$(run_owners "$RS_EXEC" "$RS_EXEC/hooks/lib/rules-injection-policy.js")"
if [ "$RS_EXEC_REP2" = "$RS_EXEC_REP" ] && [ ! -e "$RS_CANARY" ]; then
    pass "A2d: a repeat run is byte-identical and still writes no canary"
else
    fail "A2d: repeat run diverged (canary present: $([ -e "$RS_CANARY" ] && echo yes || echo no)) — second report: $(printf '%s' "$RS_EXEC_REP2" | tr '\n' ' ')"
fi

# --- A3: static guard. A2 catches a require() of the policy PATH as passed; it cannot
# catch a reintroduction routed through a different spelling that happens to avoid the
# canary (a lazy require inside an unexercised branch, for instance). So the reporter
# SOURCE is asserted directly: it must reach the constants via loadPolicyAsData, and
# must contain no require() of the policy path in any spelling. ---
RS_SRC="$BASE/owners.js"
RS_BAD_REQUIRE="$(grep -nE "require\(\s*(POLICY_PATH|process\.argv\[3\]|policyPath|policy\b|[\"'][^\"']*rules-injection-policy)" "$RS_SRC" || true)"
if [ -n "$RS_BAD_REQUIRE" ]; then
    fail "A3: the reporter source require()s the policy path — $(printf '%s' "$RS_BAD_REQUIRE" | tr '\n' ' ')"
elif ! grep -q 'loadPolicyAsData(POLICY_PATH)' "$RS_SRC"; then
    fail "A3: the reporter does not obtain its constants via loadPolicyAsData(POLICY_PATH) — the parse-don't-evaluate contract is unenforced"
else
    pass "A3: the reporter source contains no require() of a policy path and parses via loadPolicyAsData"
fi

# --- A3b: the static guard must be able to fail, otherwise it is a false green. Run the
# same two greps over a deliberately-bad copy of the reporter. ---
RS_MUT="$BASE/owners-mutant.js"
sed 's|const policy = loadPolicyAsData(POLICY_PATH);|const policy = require(POLICY_PATH);|' \
    "$RS_SRC" > "$RS_MUT"
RS_MUT_HIT="$(grep -cE "require\(\s*(POLICY_PATH|process\.argv\[3\]|policyPath|policy\b|[\"'][^\"']*rules-injection-policy)" "$RS_MUT" || true)"
if [ "${RS_MUT_HIT:-0}" -ge 1 ] && ! grep -q 'loadPolicyAsData(POLICY_PATH)' "$RS_MUT"; then
    pass "A3b: the static guard fires on a reporter that reintroduces require(POLICY_PATH)"
else
    fail "A3b: the static guard did not fire on the mutant (hits=$RS_MUT_HIT) — A3 is a false green"
fi

# --- A4: degraded policy. A file that exists but whose declarations cannot be extracted
# must NOT silently look like a well-formed empty policy that passes every per-rule
# assertion vacuously. The documented failure mode of loadPolicyAsData is [] for arrays,
# which the entry file's M0 turns into a loud failure — so what is asserted here is that
# the reporter reaches M0's tripwire (OD_COUNT=0, zero RULE rows) instead of crashing
# or inventing rows. ---
RS_DEGRADED="$BASE/rs-degraded"
rs_fixture "$RS_DEGRADED"
cat > "$RS_DEGRADED/hooks/lib/rules-injection-policy.js" <<'RS_DEGRADED_EOF'
"use strict";
// Declarations computed at runtime: legal JS, but outside the one-line-literal shape
// the policy file is required to keep, so a text parser cannot recover them.
const parts = ["rules/owned.md|skills/owner/SKILL.md"];
const ON_DEMAND_READERS = parts.map((p) => p);
const EXPECTED_UNCONDITIONAL = ON_DEMAND_READERS.slice(0, 0);
module.exports = { ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
RS_DEGRADED_EOF
RS_DEG_REP="$(run_owners "$RS_DEGRADED" "$RS_DEGRADED/hooks/lib/rules-injection-policy.js")"
RS_DEG_ROWS="$(printf '%s\n' "$RS_DEG_REP" | grep -c '^RULE=' || true)"
if [ "$(rs_top "$RS_DEG_REP" OD_COUNT)" = "0" ] && [ "${RS_DEG_ROWS:-0}" -eq 0 ]; then
    pass "A4a: an unparseable policy yields OD_COUNT=0 and zero rule rows — M0's tripwire, not a vacuous pass"
else
    fail "A4a: want OD_COUNT=0 with no RULE rows, got OD_COUNT=$(rs_top "$RS_DEG_REP" OD_COUNT) rows=$RS_DEG_ROWS — report: $(printf '%s' "$RS_DEG_REP" | tr '\n' ' ')"
fi

# --- A4b: a policy file that is absent altogether. loadPolicyAsData deliberately throws
# on an unreadable file so "no policy" is distinguishable from "empty policy"; the
# reporter must therefore fail loudly and print no OD_COUNT line at all. A silent
# OD_COUNT= here would let a mistyped policy path read as a legitimately empty one. ---
RS_MISSING="$BASE/rs-missing"
rs_fixture "$RS_MISSING"
rm -f "$RS_MISSING/hooks/lib/rules-injection-policy.js"
rs_missing_rc=0
RS_MISS_REP="$(run_owners "$RS_MISSING" "$RS_MISSING/hooks/lib/rules-injection-policy.js")" || rs_missing_rc=$?
if [ "$rs_missing_rc" -ne 0 ] && ! printf '%s\n' "$RS_MISS_REP" | grep -q '^OD_COUNT='; then
    pass "A4b: an absent policy file aborts the reporter loudly (rc=$rs_missing_rc) instead of reading as an empty policy"
else
    fail "A4b: want a non-zero rc and no OD_COUNT line, got rc=$rs_missing_rc — report: $(printf '%s' "$RS_MISS_REP" | tr '\n' ' ')"
fi

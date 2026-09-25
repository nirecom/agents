# shellcheck shell=bash
# Tests: hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js, bin/check-on-demand-rules.sh
# Tags: rules-injection, on-demand-rules, marker-regex, near-miss, mutation-probe, table-driven, parse-dont-evaluate, canary, TL2, scope:common

# ON_DEMAND_MARKER_RE is the only thing standing between "this rule was deliberately
# de-injected" and "this rule went missing". Testing it against the one canonical
# marker string proves almost nothing: /on-demand/ passes that test, and so does
# /injection/. What has to be pinned is the boundary — the near-misses a typo or a
# copy-paste produces, and the placements a real file puts the comment in.

# CONTRACT NOTE (asserted here, and DELIBERATELY STRICTER than a bare \b suffix guard):
#   - The comment opener `<!--` is part of the marker — the same words in prose are not a marker, or every doc that
#     DESCRIBES the mechanism would silently self-annotate.
#   - The `injection:` key is required; `<!-- on-demand-only -->` alone is not a marker.
#   - Matching is case-sensitive and suffix-tight: neither `ON-DEMAND-ONLY` nor `on-demand-only-ish` nor
#     `on-demand-onlyx` may match. `\b` alone does NOT close the hyphen case (`y` -> `-` IS a word boundary), so a
#     correct implementation needs an explicit negative lookahead such as (?![-\w]).
#   - The regex must be stateless: a `g` flag makes .test() alternate true/false across calls, so the same file would
#     be marked on one pass and unmarked on the next.

# PARSE, DON'T EVALUATE (CPR-ORTH with P11/P12 in cases-policy.sh): this harness reads the
# contributor-editable policy through the agents-owned reader (loadPolicyAsData) instead of
# require()-ing it, so running this suite on a checked-out branch cannot run that branch's
# module body. K6 is the canary that keeps that true.

# Consequence for the /g check: the reader REBUILDS the regex without /g, so RE.global is
# always false once it has been through loadPolicyAsData — an assertion on that alone would
# be a tautology. The declared flags are therefore ALSO recovered straight from the policy
# source text by this harness's own literal scanner, and K1/K1b assert both halves: the
# value the consumers receive is stateless (K1) AND the declaration itself never asked for
# /g (K1b, which is what a contributor could actually get wrong).

echo ""
echo "=== ON_DEMAND_MARKER_RE: near-miss and placement boundary ==="

cat > "$BASE/marker.js" <<'MARKER_EOF'
"use strict";
// argv[2] = hooks/lib/rules-policy-reader.js, argv[3] = the policy path under test
const fs = require("fs");
const R = require(process.argv[2]);
const policyPath = process.argv[3];
const p = R.loadPolicyAsData(policyPath);
const RE = p.ON_DEMAND_MARKER_RE;

// Independent of the reader: the flags as WRITTEN in the policy source.
const declared = /ON_DEMAND_MARKER_RE\s*=\s*\/((?:[^/\\\n]|\\.|\[[^\]\n]*\])+)\/([a-z]*)/
  .exec(fs.readFileSync(policyPath, "utf8"));

// id | subject | want ("yes" = must match)
const ROWS = [
  ["canonical",        "<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->", "yes"],
  ["minimal",          "<!-- injection: on-demand-only -->", "yes"],
  ["tight-spacing",    "<!--injection:on-demand-only-->", "yes"],
  ["wide-spacing",     "<!--   injection:   on-demand-only   -->", "yes"],
  ["indented",         "    <!-- injection: on-demand-only -->", "yes"],
  ["trailing-prose",   "<!-- injection: on-demand-only --> and some words after", "yes"],
  ["prose-no-comment", "The injection: on-demand-only convention is described here.", "no"],
  ["no-key",           "<!-- on-demand-only -->", "no"],
  ["wrong-key",        "<!-- inject: on-demand-only -->", "no"],
  ["uppercase",        "<!-- INJECTION: ON-DEMAND-ONLY -->", "no"],
  ["mixed-case",       "<!-- Injection: On-Demand-Only -->", "no"],
  ["value-truncated",  "<!-- injection: on-demand -->", "no"],
  ["suffix-word",      "<!-- injection: on-demand-onlyx -->", "no"],
  ["suffix-hyphen",    "<!-- injection: on-demand-only-ish -->", "no"],
  ["underscore-value", "<!-- injection: on_demand_only -->", "no"],
  ["closing-comment",  "--> injection: on-demand-only", "no"],
  ["empty",            "", "no"],
];

const test1 = (re, s) => { const r = new RegExp(re.source, re.flags.replace("g", "")); return r.test(s); };

const out = [];
out.push("IS_REGEXP=" + (RE instanceof RegExp ? "yes" : "no"));
out.push("GLOBAL_FLAG=" + (RE instanceof RegExp && RE.global ? "yes" : "no"));
out.push("DECLARED_FOUND=" + (declared ? "yes" : "no"));
out.push("DECLARED_G=" + (declared && declared[2].includes("g") ? "yes" : "no"));

if (!(RE instanceof RegExp)) { console.log(out.join("\n")); process.exit(0); }

// statelessness: the SAME subject tested twice must answer the same way.
const a = RE.test(ROWS[0][1]);
const b = RE.test(ROWS[0][1]);
out.push("STATELESS=" + (a === b ? "yes" : "no"));

for (const [id, subject, want] of ROWS) {
  out.push("ROW=" + id + " WANT=" + want + " GOT=" + (test1(RE, subject) ? "yes" : "no"));
}

// --- mutation probes: each deliberately-wrong regex must be KILLED by at least one
// row above. A row set that cannot kill a mutant is a row set that would not have
// noticed the corresponding implementation mistake. ---
const MUTANTS = [
  ["m-no-opener",    /injection:\s*on-demand-only\b/],
  ["m-no-key",       /<!--\s*on-demand-only\b/],
  ["m-no-boundary",  /<!--\s*injection:\s*on-demand-only/],
  ["m-no-space-cls", /<!--injection:on-demand-only\b/],
  ["m-case-insens",  /<!--\s*injection:\s*on-demand-only\b/i],
  ["m-value-loose",  /<!--\s*injection:\s*on-demand/],
  ["m-anchored",     /^<!--\s*injection:\s*on-demand-only\b/],
  ["m-substring",    /on-demand-only/],
];

for (const [mid, mre] of MUTANTS) {
  const killers = ROWS.filter(([, subject, want]) => {
    const got = test1(mre, subject) ? "yes" : "no";
    return got !== want;
  }).map(([id]) => id);
  out.push("MUTANT=" + mid + " KILLED=" + (killers.length ? "yes" : "no") + " BY=" + (killers.join(",") || "-"));
}
console.log(out.join("\n"));
MARKER_EOF

# mk_report <policy-path> -> the harness stdout+stderr
mk_report() { node "$(node_path "$BASE/marker.js")" "$(node_path "$READER")" "$(node_path "$1")" 2>&1; }

MK_REPORT="$(mk_report "$POLICY")"

mkfield() { printf '%s\n' "$MK_REPORT" | grep "^$1=" | head -1 | cut -d= -f2-; }

check_mk() {
    local label="$1" key="$2" want="$3" got
    got="$(mkfield "$key")"
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label — $key='$got' (want $want); report: $(printf '%s' "$MK_REPORT" | tr '\n' ' ' | cut -c1-400)"; fi
}

check_mk "K0: ON_DEMAND_MARKER_RE is a RegExp" IS_REGEXP yes
check_mk "K1: it carries no /g flag (a stateful .test() would flip verdicts per call)" GLOBAL_FLAG no
# K1a guards K1b: if the literal scanner stopped finding the declaration, K1b would read
# "no /g" from nothing at all and pass for the wrong reason.
check_mk "K1a: the marker regex literal is recoverable from the policy source text" DECLARED_FOUND yes
check_mk "K1b: the policy source itself declares no /g flag (the mistake a contributor can actually make)" DECLARED_G no
check_mk "K2: repeated .test() on one subject is stable" STATELESS yes

# --- K3: the near-miss / placement table ---
MK_ROWS=0; MK_BAD=0
while IFS= read -r line; do
    case "$line" in ROW=*) ;; *) continue ;; esac
    r_id="$(printf '%s' "$line" | tr ' ' '\n' | grep '^ROW=' | cut -d= -f2-)"
    r_want="$(printf '%s' "$line" | tr ' ' '\n' | grep '^WANT=' | cut -d= -f2-)"
    r_got="$(printf '%s' "$line" | tr ' ' '\n' | grep '^GOT=' | cut -d= -f2-)"
    MK_ROWS=$((MK_ROWS + 1))
    if [ "$r_want" != "$r_got" ]; then
        MK_BAD=$((MK_BAD + 1))
        fail "K3 [$r_id]: marker regex answered '$r_got', want '$r_want'"
    fi
done <<MK_TABLE
$MK_REPORT
MK_TABLE
if [ "$MK_ROWS" -lt 17 ]; then
    fail "K3: only $MK_ROWS boundary rows were evaluated (want 17) — the table did not run"
elif [ "$MK_BAD" = "0" ]; then
    pass "K3: all $MK_ROWS near-miss / placement rows answered as specified"
fi

# --- K4: the mutation-probe score. Every wrong regex must be killed by the row set
# above; a surviving mutant means the table has a hole, not that the mutant is fine. ---
MK_MUT=0; MK_ALIVE=0
while IFS= read -r line; do
    case "$line" in MUTANT=*) ;; *) continue ;; esac
    m_id="$(printf '%s' "$line" | tr ' ' '\n' | grep '^MUTANT=' | cut -d= -f2-)"
    m_killed="$(printf '%s' "$line" | tr ' ' '\n' | grep '^KILLED=' | cut -d= -f2-)"
    MK_MUT=$((MK_MUT + 1))
    if [ "$m_killed" != "yes" ]; then
        MK_ALIVE=$((MK_ALIVE + 1))
        fail "K4 [$m_id]: this wrong regex survives every row — the boundary table cannot detect that implementation mistake"
    fi
done <<MK_TABLE2
$MK_REPORT
MK_TABLE2
if [ "$MK_MUT" -lt 8 ]; then
    fail "K4: only $MK_MUT mutants were scored (want 8) — the probe set did not run"
elif [ "$MK_ALIVE" = "0" ]; then
    pass "K4: mutation score 8/8 — every deliberately-wrong marker regex is killed by the table"
fi

# --- K5: placement inside the real checker. The regex answering correctly on a string
# is not the same as the checker finding the marker where a real file puts it. Each
# fixture below moves the SAME canonical marker to a different location; the verdict
# must follow the contract, not the byte count. ---
mk_place() {
    local label="$1" variant="$2"
    local want_rc="$3"
    CASE_N=$((CASE_N + 1))
    local d="$BASE/mk-$variant$CASE_N"
    fx_base "$d"
    case "$variant" in
        after-frontmatter)
            wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# body
EOF
            ;;
        blank-line-between)
            wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---

$MARKER

# body
EOF
            ;;
        deep-in-body)
            wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---

# body

Some prose, then much later:

$MARKER
EOF
            ;;
        inside-frontmatter)
            # the marker is an HTML comment; buried in the YAML block it is not part of
            # the rendered document and must not count as annotation
            wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
# $MARKER
---

# body
EOF
            ;;
        near-miss-only)
            wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---
<!-- injection: on-demand-only-ish -->

# body
EOF
            ;;
    esac
    local rc out
    rc="$(run_checker "$d" all)"
    out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
    if [ "$rc" = "$want_rc" ]; then
        pass "$label (exit $rc)"
    else
        fail "$label: want exit $want_rc, got $rc — checker said: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    fi
}

mk_place "K5a: marker immediately after the frontmatter is accepted"        after-frontmatter  0
mk_place "K5b: a blank line before the marker is still accepted"            blank-line-between 0
mk_place "K5c: the marker further down the body is still accepted"          deep-in-body       0
mk_place "K5d: a marker buried inside the YAML frontmatter does not count"  inside-frontmatter 1
mk_place "K5e: only a near-miss marker present is rejected"                 near-miss-only     1

# --- K6: this harness reads the policy as DATA. -----------------------------------
# Same contract and same canary shape as P11/P12 in cases-policy.sh, applied to the
# marker harness (CPR-ORTH: a symmetric member of the class gets the same treatment).
# The assertion is the ABSENCE of the module body's side effect, guarded by proof that
# the harness still recovered the regex — an aborted harness also leaves no canary.
CASE_N=$((CASE_N + 1)); d="$BASE/mk-exec$CASE_N"
fx_base "$d"
MK_CANARY="$d/MARKER-HARNESS-EXECUTED-POLICY.txt"
MK_CANARY_NODE="$(node_path "$MK_CANARY")"
cat > "$d/hooks/lib/rules-injection-policy.js" <<MK_EXEC_EOF
"use strict";
require("fs").writeFileSync("$MK_CANARY_NODE", "executed");
const ON_DEMAND_TOKEN = "$TOKEN";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_READERS = ["rules/od.md|skills/fx-owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
MK_EXEC_EOF
MK6_REPORT="$(mk_report "$d/hooks/lib/rules-injection-policy.js")"
mk6_is_re="$(printf '%s\n' "$MK6_REPORT" | grep '^IS_REGEXP=' | head -1 | cut -d= -f2-)"
if [ -e "$MK_CANARY" ]; then
    fail "K6: the marker harness EXECUTED the contributor-editable policy file (canary written) — it must read it as data through hooks/lib/rules-policy-reader.js"
elif [ "$mk6_is_re" != "yes" ]; then
    fail "K6: no canary, but the harness did not recover the marker regex either (IS_REGEXP=$mk6_is_re) — absence of the side effect proves nothing when the harness aborted; report: $(printf '%s' "$MK6_REPORT" | tr '\n' ' ' | cut -c1-300)"
else
    pass "K6: the marker harness read the policy as data — regex recovered, module body did not execute"
fi
unset MK6_REPORT mk6_is_re

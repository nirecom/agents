# tests/feature-2124-tool-selection-priority/injection-policy.sh
# Tests: hooks/lib/rules-injection-policy.js, skills/write-code/SKILL.md, skills/write-tests/SKILL.md
# Tags: rules, prompt, injection, dispatch, scope:issue-specific, pwsh-not-required, TL2

# U4 / U8: how the norm is delivered, and how many dispatch sites must carry it.

# U4 rests on the DECLARATION, not on a quoted string, so a declaration moved to another array
# cannot read as still present -- but read it as DATA via hooks/lib/rules-policy-reader.js, never
# `require(POLICY)`: the policy file is contributor-editable, so require()-ing it would run a
# pull request's module body just because a reviewer ran this suite. Contract + canaries:
# tests/cc-on-demand-skill-ownership/cases-require-safety.sh (A2/A3) -- CPR-ORTH sibling.
POLICY_READER="$AGENTS_DIR/hooks/lib/rules-policy-reader.js"

policy_field() { # <includes-in-expected|listed-in-on-demand> -> yes|no|ERROR
    node -e '
      try {
        const { loadPolicyAsData } = require(process.argv[1]);
        const p = loadPolicyAsData(process.argv[2]);
        const rel = "rules/shell-commands.md";
        if (process.argv[3] === "includes-in-expected") {
          console.log((p.EXPECTED_UNCONDITIONAL || []).includes(rel) ? "yes" : "no");
        } else {
          console.log((p.ON_DEMAND_READERS || []).some((row) => row.key === rel) ? "yes" : "no");
        }
      } catch (e) { console.log("ERROR"); }
    ' "$(node_path "$POLICY_READER")" "$(node_path "$POLICY")" "$1" 2>/dev/null || printf 'ERROR'
}

u4_unconditional_injection() {
    assert_eq "U4a: $RULES_REL is declared in EXPECTED_UNCONDITIONAL" \
        "yes" "$(policy_field includes-in-expected)"
    assert_eq "U4b: $RULES_REL is NOT registered as an on-demand rule" \
        "no" "$(policy_field listed-in-on-demand)"
}

# U6/U7 are pinned to two named files, so U8 pins the population those two are drawn from --
# from BOTH ends. The count catches a THIRD dispatch site added later, which would inherit none
# of the timing wiring and say nothing about it. The names catch the opposite drift: a site
# renamed or moved keeps the count at 2 while U6 quietly stops testing a live dispatch, and
# `dispatch_timing_updated` answers `no` on a missing file exactly as it does on a stale one.
u8_dispatch_sites() {
    local n rel label got
    n="$(grep -rhoE 'mode: *"default"' "$AGENTS_DIR/skills" --include='SKILL.md' 2>/dev/null | grep -c . || true)"
    assert_eq "U8a: skills/**/SKILL.md declares exactly 2 general-purpose dispatch sites" \
        "2" "${n:-0}"
    while IFS='#' read -r rel label; do
        [ -n "$rel" ] || continue
        ROWS=$((ROWS + 1))
        got="absent"
        grep -qE 'mode: *"default"' "$AGENTS_DIR/$rel" 2>/dev/null && got="present"
        assert_eq "U8b[$rel]: $label" "present" "$got"
    done <<'U8_CASES'
skills/write-code/SKILL.md#WCD-4 is one of the two expected general-purpose dispatch sites
skills/write-tests/SKILL.md#WT-6 is the other (a rename keeps U8a at 2 but must not pass here)
U8_CASES
}

# U10 (#2140/#2141): row-level membership on ON_DEMAND_READERS, not just presence of the rule
# as a row key (U4b already covers that for rules/shell-commands.md). Same parse-don't-evaluate
# reader as policy_field above, so a reader moved to a different row still reads as
# "not in this row" without the policy body ever running.
policy_row_includes() { # <rule-path> <reader-path> -> yes|no|ERROR
    node -e '
      try {
        const { loadPolicyAsData } = require(process.argv[1]);
        const p = loadPolicyAsData(process.argv[2]);
        const row = (p.ON_DEMAND_READERS || []).find((r) => r.key === process.argv[3]);
        if (!row || !row.values) { console.log("no"); process.exit(0); }
        console.log(row.values.map((s) => s.trim()).includes(process.argv[4]) ? "yes" : "no");
      } catch (e) { console.log("ERROR"); }
    ' "$(node_path "$POLICY_READER")" "$(node_path "$POLICY")" "$1" "$2" 2>/dev/null || printf 'ERROR'
}

u10_write_tests_coding_row_promotion() {
    assert_eq "U10a: rules/coding.md row includes skills/write-tests/SKILL.md (WT-6's new Read)" \
        "yes" "$(policy_row_includes "rules/coding.md" "skills/write-tests/SKILL.md")"
    assert_eq "U10b: rules/ops.md row does NOT include skills/write-tests/SKILL.md (deliberate C4 omission)" \
        "no" "$(policy_row_includes "rules/ops.md" "skills/write-tests/SKILL.md")"
    assert_eq "U10c: rules/test.md row still includes skills/write-tests/SKILL.md (unchanged invariant)" \
        "yes" "$(policy_row_includes "rules/test.md" "skills/write-tests/SKILL.md")"
    assert_eq "U10d: NEGATIVE CONTROL -- a known-absent rule/reader pair reads as absent" \
        "no" "$(policy_row_includes "rules/coding.md" "skills/no-such-skill/SKILL.md")"
}

# U11 STATIC GUARD: the two readers above must never regress to `require(POLICY)`. A canary
# fixture would only catch the spelling actually exercised, so the source is asserted directly
# (same shape as cases-require-safety.sh A3, and U11b proves the grep can still fire).
SELF="$AGENTS_DIR/tests/feature-2124-tool-selection-priority/injection-policy.sh"

# Scanning the whole file would count the guard's OWN pattern and mutation literals, so the scan
# stops at this marker -- everything above it is the predicate region where the node -e programs
# that actually touch the policy live.
U11_BOUNDARY='# --- U11 boundary: the guard scans only above this line. ---'

predicate_region() { # <file> -> the file's content above the U11 boundary
    local n
    n="$(grep -n -m1 -F -- "$U11_BOUNDARY" "$1" 2>/dev/null | cut -d: -f1)"
    [ -n "$n" ] || n="$(wc -l < "$1")"
    head -n "$((n - 1))" "$1"
}

# argv[1] is the READER (agents-owned, require() is correct there); argv[2] is the POLICY.
policy_require_hits() { # <file> -> count of forbidden require() spellings of the policy path
    # Comment lines are dropped first: prose ABOUT require(POLICY) -- the U4 rationale above says
    # the words -- is not a call site, and counting it would make the guard unable to reach 0.
    predicate_region "$1" | grep -v '^[[:space:]]*#' \
        | grep -cE 'require\(process\.argv\[2\]\)|require\([^)]*rules-injection-policy|require\("?\$?POLICY' || true
}

policy_reader_hits() { # <file> -> count of sanctioned loadPolicyAsData(POLICY) call sites
    predicate_region "$1" | grep -cF 'loadPolicyAsData(process.argv[2])' || true
}

u11_no_require_of_the_policy() {
    local mutant="${TMPDIR:-/tmp}/ip-2140-mutant.$$"
    assert_eq "U11a: this file obtains the policy via loadPolicyAsData, never require(POLICY)" \
        "0:2" "$(policy_require_hits "$SELF"):$(policy_reader_hits "$SELF")"
    sed 's|loadPolicyAsData(process.argv\[2\])|require(process.argv[2])|' "$SELF" > "$mutant"
    assert_eq "U11b: NEGATIVE CONTROL -- the SAME guard reports a copy that reintroduces require(POLICY)" \
        "2:0" "$(policy_require_hits "$mutant"):$(policy_reader_hits "$mutant")"
    rm -f "$mutant"
}

u4_unconditional_injection
u8_dispatch_sites
u10_write_tests_coding_row_promotion
u11_no_require_of_the_policy

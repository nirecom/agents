#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/combination-escalation-cases.sh
# Tests: hooks/workflow-state/complexity-routing.js, bin/workflow/derive-complexity-level
# Tags: complexity, routing, combination-escalation, set-membership, table-driven, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# #2460 retired outline/detail's only combination row (S1b-wide-change + S6-long-plan):
# S6-long-plan is no longer a signal, so combination_escalation is empty at every stage.
# These rows pin that NO multi-signal set of individually-low signals escalates, and
# that a retired id escalates only through the undecidable route — in any order,
# with duplicates, at the module and at the CLI boundary.

# CE-1: outline and detail verdicts for sets that used to hinge on the pair.
d2099c_combination_membership() {
    local got
    got=$(run_with_timeout node - 2>&1 <<'JS'
const m = require(process.env.CR_MOD_N);
// [label, signals, expected]. outline/detail: solo = {S2-architecture, S5-breaking},
// combination = [], undecidable = high. S1b/S3/S4 are individually low there.
const CASES = [
  // --- individually-low signals, alone and together: no combination escalates
  ["s1b-alone",               ["S1b-wide-change"], "low"],
  ["s1b-duplicated",          ["S1b-wide-change", "S1b-wide-change", "S1b-wide-change"], "low"],
  ["s1b-with-s4",             ["S1b-wide-change", "S4-installer"], "low"],
  ["s4-with-s1b",             ["S4-installer", "S1b-wide-change"], "low"],
  ["all-low-signals",         ["S1b-wide-change", "S3-security", "S4-installer"], "low"],
  ["all-low-with-blanks",     ["  S1b-wide-change ", "", "S4-installer", " ", "S3-security"], "low"],
  // --- a solo signal escalates regardless of companions ----------------------
  ["s1b-with-s2",             ["S1b-wide-change", "S2-architecture"], "high"],
  ["s5-with-low-noise",       ["S4-installer", "S5-breaking", "S1b-wide-change"], "high"],
  // --- the retired former pair member: undecidable, never a combination -----
  ["former-pair-ordered",     ["S1b-wide-change", "S6-long-plan"], "high"],
  ["former-pair-reversed",    ["S6-long-plan", "S1b-wide-change"], "high"],
  ["retired-s6-alone",        ["S6-long-plan"], "high"],
  ["retired-s1-alone",        ["S1-multi-file"], "high"],
  ["retired-s1-with-low",     ["S1-multi-file", "S4-installer"], "high"],
  ["retired-s6-duplicated",   ["S6-long-plan", "S6-long-plan"], "high"],
];
for (const stage of ["outline", "detail"]) {
  for (const c of CASES) {
    let out;
    try { out = m.deriveStageLevel(stage, c[1]); }
    catch (e) { out = "THREW:" + (e && e.name); }
    console.log(stage + " " + c[0] + " " + out + (out === c[2] ? "" : " WANT=" + c[2]));
  }
}
JS
)
    assert_block "CE-1 outline/detail: no set of individually-low signals escalates; retired ids escalate only as undecidable" "$got" <<'EOF'
outline s1b-alone low
outline s1b-duplicated low
outline s1b-with-s4 low
outline s4-with-s1b low
outline all-low-signals low
outline all-low-with-blanks low
outline s1b-with-s2 high
outline s5-with-low-noise high
outline former-pair-ordered high
outline former-pair-reversed high
outline retired-s6-alone high
outline retired-s1-alone high
outline retired-s1-with-low high
outline retired-s6-duplicated high
detail s1b-alone low
detail s1b-duplicated low
detail s1b-with-s4 low
detail s4-with-s1b low
detail all-low-signals low
detail all-low-with-blanks low
detail s1b-with-s2 high
detail s5-with-low-noise high
detail former-pair-ordered high
detail former-pair-reversed high
detail retired-s6-alone high
detail retired-s1-alone high
detail retired-s1-with-low high
detail retired-s6-duplicated high
EOF
}

# CE-2: exhaustive permutation sweep. Order must never decide the verdict, for a
# low set, a solo-escalating set and a set carrying a retired (undecidable) id.
d2099c_permutation_invariance() {
    local got
    got=$(run_with_timeout node - 2>&1 <<'JS'
const m = require(process.env.CR_MOD_N);
function permutations(a) {
  if (a.length <= 1) { return [a]; }
  const out = [];
  a.forEach(function (x, i) {
    const rest = a.slice(0, i).concat(a.slice(i + 1));
    permutations(rest).forEach(function (p) { out.push([x].concat(p)); });
  });
  return out;
}
const SETS = [
  ["all-low", ["S1b-wide-change", "S3-security", "S4-installer"], "low"],
  ["low+solo", ["S1b-wide-change", "S4-installer", "S2-architecture"], "high"],
  // The retired sets never pair S1b with S6 (the former combination row), so
  // "high" here is attributable to the undecidable route alone.
  ["low+retired", ["S3-security", "S4-installer", "S6-long-plan"], "high"],
  ["low+2retired", ["S3-security", "S4-installer", "S1-multi-file", "S6-long-plan"], "high"],
];
for (const stage of ["outline", "detail"]) {
  for (const s of SETS) {
    const perms = permutations(s[1]);
    const levels = perms.map(function (p) { return m.deriveStageLevel(stage, p); });
    const disagreeing = levels.filter(function (l) { return l !== s[2]; }).length;
    console.log(stage + " " + s[0] + " perms=" + perms.length + " want=" + s[2] + " disagreeing=" + disagreeing);
  }
}
JS
)
    assert_block "CE-2 the outline/detail verdict is invariant under every permutation of the same signal set" "$got" <<'EOF'
outline all-low perms=6 want=low disagreeing=0
outline low+solo perms=6 want=high disagreeing=0
outline low+retired perms=6 want=high disagreeing=0
outline low+2retired perms=24 want=high disagreeing=0
detail all-low perms=6 want=low disagreeing=0
detail low+solo perms=6 want=high disagreeing=0
detail low+retired perms=6 want=high disagreeing=0
detail low+2retired perms=24 want=high disagreeing=0
EOF
}

# CE-3: the same question at the CLI boundary — the consumers' fallback path goes
# through a CSV parse, where an ordering or dedup bug would not reach the module.
d2099c_cli_membership() {
    local row label stage csv want got rest
    for row in \
        "cli-s1b-s4|detail|S1b-wide-change,S4-installer|low" \
        "cli-s4-s1b-duplicated|detail|S4-installer,S1b-wide-change,S1b-wide-change|low" \
        "cli-outline-all-low|outline|S3-security,S1b-wide-change,S4-installer|low" \
        "cli-former-pair|detail|S1b-wide-change,S6-long-plan|high" \
        "cli-former-pair-reversed|outline|S6-long-plan,S1b-wide-change|high" \
        "cli-retired-s1-with-low|detail|S1-multi-file,S4-installer|high" \
        "cli-solo-with-low|detail|S4-installer,S5-breaking|high"; do
        label="${row%%|*}"
        rest="${row#*|}"
        stage="${rest%%|*}"
        rest="${rest#*|}"
        csv="${rest%|*}"
        want="${row##*|}"
        got=$(run_with_timeout node "$BIN_DERIVE" --stage "$stage" --signals "$csv" 2>/dev/null | head -1)
        assert_eq "CE-3 $label: derive-complexity-level --stage $stage --signals '$csv'" \
            "level=$want" "$got"
    done
}

# CE-4: no stage carries a combination row any more; V-1's singleton rejection
# (validate-table-cases.sh) stays reachable through a mutated clone only.
d2099c_no_combination_rows() {
    local got
    got=$(run_with_timeout node - 2>&1 <<'JS'
const m = require(process.env.CR_MOD_N);
const rows = [];
for (const s of m.ROUTING_STAGES) {
  const combos = m.STAGE_ROUTING[s].combination_escalation;
  rows.push(s + "=" + (!Array.isArray(combos) ? "NOT_ARRAY" : combos.length ? combos.length + "_rows" : "none"));
}
console.log(rows.join(" "));
JS
)
    assert_eq "CE-4 combination_escalation is an empty array at every stage" \
        "outline=none detail=none write_tests=none write_code=none" "$got"
}

case_begin "combination-membership-set-semantics" "hooks/workflow-state/complexity-routing.js"
d2099c_combination_membership
case_end

case_begin "combination-permutation-invariance" "hooks/workflow-state/complexity-routing.js"
d2099c_permutation_invariance
case_end

case_begin "combination-cli-membership" "bin/workflow/derive-complexity-level"
d2099c_cli_membership
case_end

case_begin "combination-rows-absent-at-every-stage" "hooks/workflow-state/complexity-routing.js"
d2099c_no_combination_rows
case_end

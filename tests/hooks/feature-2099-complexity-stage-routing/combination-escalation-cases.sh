#!/bin/bash
# tests/feature-2099-complexity-stage-routing/combination-escalation-cases.sh
# Tests: hooks/workflow-state/complexity-routing.js, bin/workflow/derive-complexity-level
# Tags: complexity, routing, combination-escalation, set-membership, table-driven, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# detail.md D1 step 8 escalates when ALL combination elements are CONTAINED in the
# signal set. D-4 feeds only the exact ordered pair, which a list-EQUALITY or an
# order-sensitive implementation passes too; these rows separate the two readings.

# CE-1: order, supersets, duplicates and near-miss controls for detail's only
# combination row (D2) — neither member escalates that stage alone.
d2099c_combination_membership() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
// [label, signals, expected]. Expectations come from the D2 detail row:
// solo = {S2-architecture, S5-breaking}; combination = [S1b-wide-change, S6-long-plan].
// Neither S1b nor S6 is a detail solo signal, so ONLY the full pair reaches high.
const CASES = [
  // --- the pair, in every arrangement ---------------------------------------
  ["pair-ordered",            ["S1b-wide-change", "S6-long-plan"], "high"],
  ["pair-reversed",           ["S6-long-plan", "S1b-wide-change"], "high"],
  // --- supersets. Extra signals that escalate detail on their OWN are excluded
  // on purpose, so a high verdict can only have come from the combination.
  ["superset-leading",        ["S1-multi-file", "S1b-wide-change", "S6-long-plan"], "high"],
  ["superset-trailing",       ["S1b-wide-change", "S6-long-plan", "S4-installer"], "high"],
  ["superset-interleaved",    ["S1b-wide-change", "S4-installer", "S6-long-plan"], "high"],
  ["superset-reversed",       ["S4-installer", "S6-long-plan", "S1-multi-file", "S1b-wide-change"], "high"],
  ["superset-all-non-detail", ["S1-multi-file", "S3-security", "S4-installer", "S1b-wide-change", "S6-long-plan"], "high"],
  // --- duplicates inside the list ------------------------------------------
  ["dup-first-member",        ["S1b-wide-change", "S1b-wide-change", "S6-long-plan"], "high"],
  ["dup-second-member",       ["S1b-wide-change", "S6-long-plan", "S6-long-plan"], "high"],
  ["dup-both-members",        ["S6-long-plan", "S1b-wide-change", "S6-long-plan", "S1b-wide-change"], "high"],
  ["dup-with-blanks",         ["  S1b-wide-change ", "", "S1b-wide-change", " ", "S6-long-plan"], "high"],
  // --- non-matching controls: one member only, duplicated members, other pairs
  ["only-first",              ["S1b-wide-change"], "low"],
  ["only-second",             ["S6-long-plan"], "low"],
  ["only-first-duplicated",   ["S1b-wide-change", "S1b-wide-change", "S1b-wide-change"], "low"],
  ["only-second-duplicated",  ["S6-long-plan", "S6-long-plan"], "low"],
  ["half-pair-plus-noise",    ["S1b-wide-change", "S1-multi-file", "S4-installer"], "low"],
  ["other-half-plus-noise",   ["S6-long-plan", "S1-multi-file", "S4-installer"], "low"],
  ["different-pair",          ["S1-multi-file", "S4-installer"], "low"],
  ["near-miss-S1-for-S1b",    ["S1-multi-file", "S6-long-plan"], "low"],
  ["no-members-at-all",       ["S1-multi-file", "S3-security", "S4-installer"], "low"],
];
for (const c of CASES) {
  let out;
  try { out = m.deriveStageLevel("detail", c[1]); }
  catch (e) { out = "THREW:" + (e && e.name); }
  console.log(c[0] + " " + out + (out === c[2] ? "" : " WANT=" + c[2]));
}
')
    assert_block "CE-1 detail's combination row escalates on SET MEMBERSHIP — any order, any superset, duplicates included — and on nothing less" "$got" <<'EOF'
pair-ordered high
pair-reversed high
superset-leading high
superset-trailing high
superset-interleaved high
superset-reversed high
superset-all-non-detail high
dup-first-member high
dup-second-member high
dup-both-members high
dup-with-blanks high
only-first low
only-second low
only-first-duplicated low
only-second-duplicated low
half-pair-plus-noise low
other-half-plus-noise low
different-pair low
near-miss-S1-for-S1b low
no-members-at-all low
EOF
}

# CE-2: exhaustive permutation sweep. An implementation comparing `signals.join()`
# to a canonical string passes CE-1's ordered row and fails 5 of 6 permutations here.
d2099c_permutation_invariance() {
    local got
    got=$(run_node '
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
  ["pair", ["S1b-wide-change", "S6-long-plan"], "high"],
  ["pair+noise", ["S1b-wide-change", "S6-long-plan", "S1-multi-file"], "high"],
  ["pair+2noise", ["S1b-wide-change", "S6-long-plan", "S1-multi-file", "S4-installer"], "high"],
  ["half+noise", ["S1b-wide-change", "S1-multi-file", "S4-installer"], "low"],
];
for (const s of SETS) {
  const perms = permutations(s[1]);
  const levels = perms.map(function (p) { return m.deriveStageLevel("detail", p); });
  const disagreeing = levels.filter(function (l) { return l !== s[2]; }).length;
  console.log(s[0] + " perms=" + perms.length + " want=" + s[2] + " disagreeing=" + disagreeing);
}
')
    assert_block "CE-2 the combination verdict is invariant under every permutation of the same signal set" "$got" <<'EOF'
pair perms=2 want=high disagreeing=0
pair+noise perms=6 want=high disagreeing=0
pair+2noise perms=24 want=high disagreeing=0
half+noise perms=6 want=low disagreeing=0
EOF
}

# CE-3: the same question at the CLI boundary — the consumers' fallback path goes
# through a CSV parse, where an ordering or dedup bug would not reach the module.
d2099c_cli_membership() {
    local row label csv want got
    for row in \
        "cli-pair-ordered|S1b-wide-change,S6-long-plan|high" \
        "cli-pair-reversed|S6-long-plan,S1b-wide-change|high" \
        "cli-superset|S4-installer,S6-long-plan,S1-multi-file,S1b-wide-change|high" \
        "cli-duplicated|S6-long-plan,S1b-wide-change,S6-long-plan|high" \
        "cli-only-first|S1b-wide-change|low" \
        "cli-only-second-duplicated|S6-long-plan,S6-long-plan|low" \
        "cli-different-pair|S1-multi-file,S4-installer|low"; do
        label="${row%%|*}"
        csv="${row#*|}"; csv="${csv%|*}"
        want="${row##*|}"
        got=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals "$csv" 2>/dev/null | head -1)
        assert_eq "CE-3 $label: derive-complexity-level --stage detail --signals '$csv'" \
            "level=$want" "$got"
    done
}

# CE-4: combination_escalation stays structurally reserved for real combinations,
# so V-1's singleton rejection (validate-table-cases.sh) stays reachable.
d2099c_combination_is_multi_member_only() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const rows = [];
for (const s of m.ROUTING_STAGES) {
  const combos = m.STAGE_ROUTING[s].combination_escalation || [];
  rows.push(s + "=" + (combos.length
    ? combos.map(function (c) { return c.length; }).join("/")
    : "none"));
}
console.log(rows.join(" "));
')
    assert_eq "CE-4 only detail carries a combination row, and every combination has 2+ members" \
        "detail=2 write_tests=none write_code=none" "$got"
}

d2099c_combination_membership
d2099c_permutation_invariance
d2099c_cli_membership
d2099c_combination_is_multi_member_only

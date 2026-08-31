# tests/feature-2124-tool-selection-priority/injection-policy.sh
# Tests: hooks/lib/rules-injection-policy.js, skills/write-code/SKILL.md, skills/write-tests/SKILL.md
# Tags: rules, prompt, injection, dispatch, scope:issue-specific, pwsh-not-required, TL2

# U4 / U8: how the norm is delivered, and how many dispatch sites must carry it.

# The whole distribution argument rests on U4: the norm reaches main conversation, named
# dispatch and general-purpose dispatch only because the file is injected with no condition.
# Read through the module itself, not by grepping for a quoted string, so a declaration moved
# into a different array cannot read as still present.
policy_field() { # <includes-in-expected|listed-in-on-demand> -> yes|no|ERROR
    node -e '
      try {
        const p = require(process.argv[1]);
        const rel = "rules/shell-commands.md";
        if (process.argv[2] === "includes-in-expected") {
          console.log((p.EXPECTED_UNCONDITIONAL || []).includes(rel) ? "yes" : "no");
        } else {
          const hit = (p.ON_DEMAND_READERS || []).some((e) => String(e).split("|")[0] === rel);
          console.log(hit ? "yes" : "no");
        }
      } catch (e) { console.log("ERROR"); }
    ' "$(node_path "$POLICY")" "$1" 2>/dev/null || printf 'ERROR'
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

u4_unconditional_injection
u8_dispatch_sites

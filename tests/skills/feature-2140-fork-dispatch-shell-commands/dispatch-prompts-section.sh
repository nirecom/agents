# tests/skills/feature-2140-fork-dispatch-shell-commands/dispatch-prompts-section.sh
# Tests: rules/shell-commands.md
# Tags: rules, prompt, dispatch, subagent, canonical-line, scope:issue-specific, pwsh-not-required, TL2
# S1-S8 + SN1-SN12 (#2263): the Subagent Dispatch Prompts section and the three added discipline
# lines. Sourced by the dispatcher (owns marker_lineno, range_block, directive_lineno, $FIXROOT),
# so the canonical line is judged by the same two-trigger predicate (CPR-SSOT).

# Canonical-line extraction contract (the hook's line-sync test reads the rule the same way): the
# one section line starting, after optional indent and `> `/`- `, with Read `<AGENTS_MAIN_ROOT>/rules/shell-commands.md`.
SDP_RULES_FILE="$SCRIPT_CHECKOUT_ROOT/rules/shell-commands.md"
SDP_HEADING='^## Subagent Dispatch Prompts[[:space:]]*$'
SDP_CANON_ERE='^[[:space:]]*([>-][[:space:]]*)?Read `<AGENTS_MAIN_ROOT>/rules/shell-commands\.md`'

sdp_section_body() { # <file> <heading-ere> -> lines strictly after the heading, up to the next `## ` (or EOF)
    local f="$1" start next
    start="$(marker_lineno "$f" "$2")"
    [ "$start" != "0" ] || return 0
    next="$(tail -n +$((start + 1)) "$f" | grep -n -m1 -E '^## ' | cut -d: -f1)"
    if [ -n "$next" ]; then range_block "$f" $((start + 1)) $((start + next))
    else range_block "$f" $((start + 1)) 0; fi
}

sdp_canonical_lines() { sdp_section_body "$1" "$SDP_HEADING" | grep -E -- "$SDP_CANON_ERE"; }
sdp_canonical_count() { local n; n="$(sdp_canonical_lines "$1" | grep -c '')"; printf '%s' "${n:-0}"; }
sdp_canonical_text() { # <file> -> the first canonical line, marker and edge whitespace stripped
    sdp_canonical_lines "$1" | head -n1 | sed -E 's/^[[:space:]]*([>-][[:space:]]*)?//; s/[[:space:]]+$//'
}

sdp_canonical_two_trigger() { # <file> -> yes|no : the canonical line satisfies directive_lineno
    local text probe="$FIXROOT/sdp-canon-probe.md"
    text="$(sdp_canonical_text "$1")"
    [ -n "$text" ] || { printf 'no'; return; }
    printf '%s\n' "$text" > "$probe"
    [ "$(directive_lineno "$probe")" = "1" ] && printf 'yes' || printf 'no'
}

sdp_canonical_tokens() { # <file> -> yes|no : deviations section, the `0` rule, and the output-contract unless clause
    local t
    t="$(sdp_canonical_text "$1")"
    if printf '%s' "$t" | grep -qF -- '`Command-form deviations`' \
        && printf '%s' "$t" | grep -qF -- 'write `0` when none' \
        && printf '%s' "$t" | grep -qE -- 'unless .*output contract.*exact shape'; then printf 'yes'; else printf 'no'; fi
}

# S4a: verb-object pairs are pinned so a sentence keeping the nouns but flipping the verb fails;
# U2's own negation tokens ("governed by this section", "no ... exempt") are refused on the line.
sdp_interpreter_line() { # <file> -> yes|no
    local cands
    cands="$(sdp_section_body "$1" '^## Tool Selection Priority[[:space:]]*$' \
        | grep -F -- 'interpreter script' | grep -F -- 'counts as a shell-syntax write' \
        | grep -E -- 'use the (Edit and Write|Write and Edit) tools' \
        | grep -Ev -- 'governed by (this|the) section|no .*exempt')"
    [ -n "$cands" ] || { printf 'no'; return; }
    has_unnegated_line_verb "$cands" 'use'
}

sdp_after_interrupted() { # <file> -> Issuance Discipline lines AFTER the "interrupted or rejected" line
    sdp_section_body "$1" '^## Command-Line Issuance Discipline[[:space:]]*$' \
        | sed -n '/A Bash call interrupted or rejected/,$p' | tail -n +2
}

sdp_reissue_line() { # <file> -> yes|no : S4b, folding is the only sanctioned reissue
    local cands
    cands="$(sdp_after_interrupted "$1" | grep -F -- 'the only sanctioned reissue' \
        | grep -F -- 'never re-issue a blocked command' | grep -F -- 'in another shape')"
    [ -n "$cands" ] && printf 'yes' || printf 'no'
}

sdp_stop_line() { # <file> -> yes|no : S4c, an unfoldable blocked command is reported, then work stops
    local cands
    cands="$(sdp_after_interrupted "$1" | grep -F -- 'cannot be folded' | grep -F -- 'report it and stop')"
    [ -n "$cands" ] || { printf 'no'; return; }
    has_unnegated_line_verb "$cands" 'report'
}

sdp_fence_count() { local n; n="$(sdp_section_body "$1" "$SDP_HEADING" | grep -c -E '^[[:space:]]*```')"; printf '%s' "${n:-0}"; }
sdp_table_row_count() { local n; n="$(sdp_section_body "$1" "$SDP_HEADING" | grep -c -E '^[[:space:]]*\|')"; printf '%s' "${n:-0}"; }

# S7: the exemption line names all three tools, a negation over them, and an omission of the line.
sdp_exemption_line() { # <file> -> yes|no
    local cands
    cands="$(sdp_section_body "$1" "$SDP_HEADING" | grep -Ev -- "$SDP_CANON_ERE" \
        | grep -E -- '\bBash\b' | grep -E -- '\bWrite\b' | grep -E -- '\bEdit\b' \
        | grep -Ei -- 'none of|neither|lacks|without' \
        | grep -Ei -- 'omit|do not (add|include|insert|put)|never (add|include|insert)|leave (it )?out|exempt|carry no')"
    [ -n "$cands" ] && printf 'yes' || printf 'no'
}

sdp_json_line() { # <file> -> yes|no : S8
    local cands
    cands="$(sdp_section_body "$1" "$SDP_HEADING" | grep -F -- 'dispatch_directive' | grep -F -- 'JSON object')"
    [ -n "$cands" ] && printf 'yes' || printf 'no'
}

# --- S1-S8 against the real rule file ---
SDP_H_ISSUE="$(marker_lineno "$SDP_RULES_FILE" '^## Command-Line Issuance Discipline[[:space:]]*$')"
SDP_H_SDP="$(marker_lineno "$SDP_RULES_FILE" "$SDP_HEADING")"
SDP_H_HOST="$(marker_lineno "$SDP_RULES_FILE" '^## Host Shell Defaults[[:space:]]*$')"
assert_eq "S1: rules/shell-commands.md has a \`## Subagent Dispatch Prompts\` heading after Issuance Discipline and before Host Shell Defaults" \
    "yes" "$([ "$SDP_H_SDP" != "0" ] && [ "$SDP_H_ISSUE" != "0" ] && [ "$SDP_H_SDP" -gt "$SDP_H_ISSUE" ] && [ "$SDP_H_SDP" -lt "$SDP_H_HOST" ] && echo yes || echo no)"
assert_eq "S2: the section carries exactly one canonical line" "1" "$(sdp_canonical_count "$SDP_RULES_FILE")"
assert_eq "S2: the canonical line satisfies the two-trigger Read predicate (directive_lineno)" \
    "yes" "$(sdp_canonical_two_trigger "$SDP_RULES_FILE")"
assert_eq "S3: the canonical line carries \`Command-form deviations\`, the write-\`0\` rule and the output-contract unless clause" \
    "yes" "$(sdp_canonical_tokens "$SDP_RULES_FILE")"
assert_eq "S4a: Tool Selection Priority counts an interpreter-script rewrite as a shell-syntax write" \
    "yes" "$(sdp_interpreter_line "$SDP_RULES_FILE")"
assert_eq "S4b: after the 'interrupted or rejected' line, folding is the only sanctioned reissue" \
    "yes" "$(sdp_reissue_line "$SDP_RULES_FILE")"
assert_eq "S4c: after the 'interrupted or rejected' line, an unfoldable blocked command is reported and work stops" \
    "yes" "$(sdp_stop_line "$SDP_RULES_FILE")"
assert_eq "S5: the section adds no fenced code block" "0" "$(sdp_fence_count "$SDP_RULES_FILE")"
assert_eq "S6: the section re-enumerates no generated table row" "0" "$(sdp_table_row_count "$SDP_RULES_FILE")"
assert_eq "S7: the section exempts named agents with none of Bash, Write, Edit" "yes" "$(sdp_exemption_line "$SDP_RULES_FILE")"
assert_eq "S8: the section puts the canonical line under \`dispatch_directive\` for a JSON object prompt" \
    "yes" "$(sdp_json_line "$SDP_RULES_FILE")"

# --- SN1-SN12: negative controls over throwaway fixtures (never the real rule file) ---
SDP_GOOD_CANON='Read `<AGENTS_MAIN_ROOT>/rules/shell-commands.md` before the first Bash command and before writing a file, follow its Subagent Dispatch Prompts section, and end the final report with a `Command-form deviations` section counting every blocked or rejected command (write `0` when none) unless your own output contract fixes the exact shape of your reply.'
SDP_GOOD_INTERP='Rewriting files through an interpreter script (`node`, `python`, …) counts as a shell-syntax write; use the Edit and Write tools.'
SDP_GOOD_REISSUE='Folding into the default procedure is the only sanctioned reissue; never re-issue a blocked command in another shape (another interpreter, an inline script, split chaining).'
SDP_GOOD_STOP='When a blocked command cannot be folded, report it and stop.'
SDP_GOOD_EXEMPT='Omit the canonical line when dispatching a named agent whose tool list has none of Bash, Write, Edit.'
SDP_GOOD_JSON='When the prompt is a JSON object, put the canonical line under the top-level `dispatch_directive` key instead of appending text.'

# sdp_fixture <path> <canon> <interp> <reissue> <stop> <exempt> [<extra-section-line>] [early]
sdp_fixture() {
    local reissue_early="" reissue_late="$4"
    [ "${8:-}" = "early" ] && { reissue_early="$4"; reissue_late=""; }
    printf '%s\n' '# Shell Commands' '' '## Tool Selection Priority' '' 'Reading defaults to Read.' "$3" '' \
        '## Command-Line Issuance Discipline' '' "$reissue_early" \
        'A Bash call interrupted or rejected with no stated reason means a prohibited literal.' \
        "$reissue_late" "$5" '' '## Subagent Dispatch Prompts' '' "$2" "$6" "$SDP_GOOD_JSON" "${7:-}" '' \
        '## Host Shell Defaults' '' 'pwsh.' > "$1"
}

sdp_all_verdicts() { # <file> -> count|two-trigger|tokens|interp|reissue|stop|exempt|json|fences|rows
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$(sdp_canonical_count "$1")" "$(sdp_canonical_two_trigger "$1")" \
        "$(sdp_canonical_tokens "$1")" "$(sdp_interpreter_line "$1")" "$(sdp_reissue_line "$1")" "$(sdp_stop_line "$1")" \
        "$(sdp_exemption_line "$1")" "$(sdp_json_line "$1")" "$(sdp_fence_count "$1")" "$(sdp_table_row_count "$1")"
}

SDP_FX="$FIXROOT/sdp"
mkdir -p "$SDP_FX"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/good.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT"
assert_eq "SN1: a fully-correct fixture passes every S predicate at once (anti-vacuity)" \
    "1|yes|yes|yes|yes|yes|yes|yes|0|0" "$(sdp_all_verdicts "$SDP_FX/good.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/no-write-trigger.md" \
    'Read `<AGENTS_MAIN_ROOT>/rules/shell-commands.md` before the first Bash command, follow its Subagent Dispatch Prompts section, and end the final report with a `Command-form deviations` section (write `0` when none) unless your own output contract fixes the exact shape of your reply.' \
    "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT"
assert_eq "SN2: a canonical line missing the before-writing trigger fails the two-trigger predicate" \
    "no" "$(sdp_canonical_two_trigger "$SDP_FX/no-write-trigger.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/dup-canon.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" "$SDP_GOOD_STOP" \
    "$SDP_GOOD_EXEMPT" "- $SDP_GOOD_CANON"
assert_eq "SN3: a second canonical line in the section is counted (exactly-one cannot pass vacuously)" \
    "2" "$(sdp_canonical_count "$SDP_FX/dup-canon.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/no-unless.md" \
    'Read `<AGENTS_MAIN_ROOT>/rules/shell-commands.md` before the first Bash command and before writing a file, follow its Subagent Dispatch Prompts section, and end the final report with a `Command-form deviations` section counting every blocked or rejected command (write `0` when none).' \
    "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT"
assert_eq "SN4: a canonical line without the output-contract unless clause fails S3" \
    "no" "$(sdp_canonical_tokens "$SDP_FX/no-unless.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/interp-inverted.md" "$SDP_GOOD_CANON" \
    'Rewriting files through an interpreter script (`node`, `python`, …) counts as a shell-syntax write; do not use the Edit and Write tools for it.' \
    "$SDP_GOOD_REISSUE" "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT"
assert_eq "SN5: an interpreter line that forbids the Edit and Write tools fails S4a" \
    "no" "$(sdp_interpreter_line "$SDP_FX/interp-inverted.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/interp-exempt.md" "$SDP_GOOD_CANON" \
    'Rewriting files through an interpreter script (`node`, `python`, …) is not governed by this section, so it counts as a shell-syntax write only nominally; use the Edit and Write tools when convenient.' \
    "$SDP_GOOD_REISSUE" "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT"
assert_eq "SN6: an interpreter line carrying U2's exemption token fails S4a" \
    "no" "$(sdp_interpreter_line "$SDP_FX/interp-exempt.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/reissue-inverted.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" \
    'Folding into the default procedure is one sanctioned reissue; you may re-issue a blocked command in another shape (another interpreter, an inline script).' \
    "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT"
assert_eq "SN7: a reissue line that permits another shape fails S4b" "no" "$(sdp_reissue_line "$SDP_FX/reissue-inverted.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/reissue-early.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" \
    "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT" "" early
assert_eq "SN8: the reissue line placed BEFORE the 'interrupted or rejected' line fails S4b" \
    "no" "$(sdp_reissue_line "$SDP_FX/reissue-early.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/stop-inverted.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" \
    'When a blocked command cannot be folded, do not report it and stop; keep trying other shapes.' "$SDP_GOOD_EXEMPT"
assert_eq "SN9: a stop line that forbids reporting fails S4c" "no" "$(sdp_stop_line "$SDP_FX/stop-inverted.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/exempt-no-negation.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" \
    "$SDP_GOOD_STOP" 'A named agent whose tool list has Bash, Write, or Edit also takes the canonical line.'
assert_eq "SN10: an exemption line without a negation over Bash/Write/Edit fails S7" \
    "no" "$(sdp_exemption_line "$SDP_FX/exempt-no-negation.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/exempt-no-omission.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" \
    "$SDP_GOOD_STOP" 'A named agent with none of Bash, Write, Edit must also receive the canonical line.'
assert_eq "SN11: an exemption line that negates the tools but never omits the line fails S7" \
    "no" "$(sdp_exemption_line "$SDP_FX/exempt-no-omission.md")"

ROWS=$((ROWS + 1))
sdp_fixture "$SDP_FX/fence-and-row.md" "$SDP_GOOD_CANON" "$SDP_GOOD_INTERP" "$SDP_GOOD_REISSUE" \
    "$SDP_GOOD_STOP" "$SDP_GOOD_EXEMPT" '```bash
| `&&` / `;` | command chaining |
```'
assert_eq "SN12: a fence and a generated-table row inside the section are counted by S5/S6" \
    "2|1" "$(sdp_fence_count "$SDP_FX/fence-and-row.md")|$(sdp_table_row_count "$SDP_FX/fence-and-row.md")"

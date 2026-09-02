# tests/feature-2124-tool-selection-priority/dispatch-timing.sh
# Tests: skills/write-code/SKILL.md, skills/write-tests/SKILL.md, rules/shell-commands.md
# Tags: rules, prompt, dispatch, orthogonality, scope:issue-specific, pwsh-not-required, TL2

# U6 / U7: both general-purpose dispatch sites order the Read on the RIGHT TIMING, IN THE BLOCK
# THAT DISPATCHES. A whole-file search cannot make that second claim: a stale timing sentence
# anywhere in a 200-line SKILL.md would keep answering yes after the dispatch step itself lost
# its directive. So the block is extracted first and the directive is required inside it.
STEP_MARKER_ERE='^(## |[A-Za-z][A-Za-z0-9]*-[0-9]+[a-z]*\.)'

# The general-purpose dispatch block: the step that carries `mode: "default"`, from its own step
# marker (`WCD-4.`, `WT-6.`, `## `…) down to the next marker. Both real sites put `mode:
# "default"` on the marker line itself, but walking backwards costs nothing and survives a site
# that puts it a line or two into the step body.
dispatch_block() { # <skill-file> -> the general-purpose dispatch block, or empty
    local f="$1" n total start rel end
    [ -f "$f" ] || return 0
    n="$(grep -n -m1 -E 'mode: *"default"' "$f" 2>/dev/null | cut -d: -f1)"
    [ -n "$n" ] || return 0
    total="$(wc -l < "$f" | tr -d ' ')"
    start="$(head -n "$n" "$f" | grep -n -E "$STEP_MARKER_ERE" | tail -n 1 | cut -d: -f1)"
    [ -n "$start" ] || start=1
    rel="$(tail -n +"$((start + 1))" "$f" | grep -n -m1 -E "$STEP_MARKER_ERE" | cut -d: -f1)"
    if [ -n "$rel" ]; then end=$((start + rel - 1)); else end="$total"; fi
    sed -n "${start},${end}p" "$f"
}

# The predicate both sites go through (CPR-SSOT): two triggers must appear on the SAME line as
# the `rules/shell-commands.md` Read directive -- "before the first Bash command" and "before
# writing a file", the latter because the Bash trigger alone never reaches a subagent that is
# about to use the Write tool.
dispatch_timing_updated() { # <skill-file> -> yes|no
    local blk hits ln filtered=""
    blk="$(dispatch_block "$1")"
    [ -n "$blk" ] || { printf 'no'; return; }
    hits="$(printf '%s\n' "$blk" | grep -F -- 'rules/shell-commands.md' | grep -F -- 'Read')"
    [ -n "$hits" ] || { printf 'no'; return; }
    # A line that FORBIDS the Read carries the same tokens the two greps below match on, so it
    # must be dropped before the trigger check -- same per-line guard as dispatch_block_reads_rule
    # (tests/lib/read-directive-negation.sh); a whole-blob check would let one negated line veto
    # a real directive sitting elsewhere in the block.
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        [ "$(line_negates_read "$ln")" = "no" ] && filtered="$filtered$ln"$'\n'
    done <<HITS
$hits
HITS
    [ -n "$filtered" ] || { printf 'no'; return; }
    if printf '%s' "$filtered" \
        | grep -Ei -- 'before (the )?(first )?Bash command' \
        | grep -Eiq -- 'before (writing|you write|it writes|any (file )?write|creating or writing)'; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# Both greps above run over the SAME filtered line stream, so two lines each carrying one
# trigger cannot add up to a pass; requiring `before` in front of the write word is what
# rejects "after writing a file"; and the stream itself is now block-scoped, which is what
# rejects a correctly-worded directive sitting outside the dispatch step.

# CPR-ORTH as a single verdict: two symmetric sites, one answer. Updating one of the pair is
# the failure this returns FAIL for.
orth_verdict() { # <file-a> <file-b> -> PASS|FAIL
    if [ "$(dispatch_timing_updated "$1")" = "yes" ] && [ "$(dispatch_timing_updated "$2")" = "yes" ]; then
        printf 'PASS'
    else
        printf 'FAIL'
    fi
}

u6_both_sites_updated() {
    local id file label
    while IFS='#' read -r id file label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "U6[$id]: $label" "yes" "$(dispatch_timing_updated "$AGENTS_DIR/$file")"
    done <<'U6_CASES'
write-code#skills/write-code/SKILL.md#WCD-4 orders the Read before the first Bash command AND before writing a file
write-tests#skills/write-tests/SKILL.md#WT-6 orders the same Read on the same two triggers (CPR-ORTH)
U6_CASES
}

# The spellings the U7 fixtures are built from. `old` is today's wording in substance (the
# Bash-command trigger only); `after` carries both words with the write trigger pointing the
# WRONG WAY; `unrelated` pairs the old directive with a second shell-commands.md line that
# mentions writing, so both triggers exist in the file but never on one line.
OLD_LINE='   The subagent prompt MUST instruct: Read `rules/shell-commands.md` before the first Bash command.'
NEW_LINE='   The subagent prompt MUST instruct: Read `rules/shell-commands.md` before the first Bash command, or before writing a file.'
AFTER_LINE='   The subagent prompt MUST instruct: Read `rules/shell-commands.md` before the first Bash command, and again after writing a file.'
UNRELATED_LINE='   Note: re-Read `rules/shell-commands.md` at session close, before writing a file summary.'
NEGATED_LINE='   Do not Read `rules/shell-commands.md` before the first Bash command, or before writing a file.'

# Step-marker structure, not a bare pair of lines: the fixture must have the same shape the
# block extractor keys on, or the `out-of-block` kind could not be expressed at all. FX-2 is
# the dispatch step; FX-1 and FX-3 bracket it so "elsewhere in the file" is a real place.
make_site_fixture() { # <path> <kind: yes|no|after|unrelated|out-of-block>
    local path="$1" kind="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' '# fixture SKILL.md (never the real file)' > "$path"
    printf '%s\n' 'FX-1. Preceding step, ahead of the dispatch block.' >> "$path"
    printf '%s\n' 'FX-2. Launch a subagent (Agent tool, mode: "default").' >> "$path"
    case "$kind" in
        yes)   printf '%s\n' "$NEW_LINE" >> "$path" ;;
        after) printf '%s\n' "$AFTER_LINE" >> "$path" ;;
        unrelated)
               printf '%s\n' "$OLD_LINE" >> "$path"
               printf '%s\n' "$UNRELATED_LINE" >> "$path" ;;
        negated) printf '%s\n' "$NEGATED_LINE" >> "$path" ;;
        mixed)
               printf '%s\n' "$NEGATED_LINE" >> "$path"
               printf '%s\n' "$NEW_LINE" >> "$path" ;;
        *)     printf '%s\n' "$OLD_LINE" >> "$path" ;;
    esac
    printf '%s\n' 'FX-3. Following step, past the end of the dispatch block.' >> "$path"
    [ "$kind" = "out-of-block" ] && printf '%s\n' "$NEW_LINE" >> "$path"
    printf '%s\n' '   Trailing body.' >> "$path"
}

# U7 -- NEGATIVE CONTROL. U6 alone cannot tell "both sites are updated" apart from "the
# predicate lost the ability to say no". These rows run the SAME orth_verdict over throwaway
# fixture pairs (never the real files): the half-done update, the reversed timing, the
# two-triggers-on-different-lines case, and the correctly-worded directive that sits OUTSIDE the
# dispatch block are each built on purpose and must come back FAIL. The `both-updated` row is
# the anti-vacuity half -- it fails if the predicate lost its yes.
u7_orth_negative_control() {
    local id a b want dir
    while IFS='#' read -r id a b want; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        dir="$FIXROOT/u7/$id"
        make_site_fixture "$dir/write-code.md" "$a"
        make_site_fixture "$dir/write-tests.md" "$b"
        assert_eq "U7[$id]: fixture pair (write-code=$a, write-tests=$b) -> $want" \
            "$want" "$(orth_verdict "$dir/write-code.md" "$dir/write-tests.md")"
    done <<'U7_CASES'
both-updated#yes#yes#PASS
only-write-code#yes#no#FAIL
only-write-tests#no#yes#FAIL
after-writing-timing#after#yes#FAIL
unrelated-write-mention#yes#unrelated#FAIL
out-of-block-timing#yes#out-of-block#FAIL
U7_CASES
}

# U6c/U6d/U6e/U6f (#2140/#2141): the same dispatch-block extractor, pinning the write-code /
# write-tests rule-Read additions that shipped alongside the shell-commands.md timing fix --
# WCD-4 orders a Read of rules/ops.md (self-repair may run a destructive command); WT-6 orders
# Reads of rules/coding.md and rules/test.md (the subagent writes test-file code and must know
# both the language-convention hub and the test-design rules); WT-6 deliberately does NOT gain
# rules/ops.md (approved decision C4 -- write-tests never runs a destructive command itself).
dispatch_block_reads_rule() { # <skill-file> <rule-path> -> yes|no
    local blk hits
    blk="$(dispatch_block "$1")"
    [ -n "$blk" ] || { printf 'no'; return; }
    hits="$(printf '%s\n' "$blk" | grep -F -- "$2" | grep -F -- 'Read')"
    [ -n "$hits" ] || { printf 'no'; return; }
    # A line that FORBIDS the Read carries the same tokens, and a block may hold several
    # candidates -- so the verdict is per line (tests/lib/read-directive-negation.sh).
    printf '%s' "$(has_unnegated_line "$hits")"
}

u6cdef_wcd4_wt6_rule_reads() {
    assert_eq "U6c: WCD-4 orders a Read of rules/ops.md inside the dispatch block" \
        "yes" "$(dispatch_block_reads_rule "$AGENTS_DIR/skills/write-code/SKILL.md" "rules/ops.md")"
    assert_eq "U6d: WT-6 orders a Read of rules/coding.md inside the dispatch block" \
        "yes" "$(dispatch_block_reads_rule "$AGENTS_DIR/skills/write-tests/SKILL.md" "rules/coding.md")"
    assert_eq "U6e: WT-6 orders a Read of rules/test.md inside the dispatch block" \
        "yes" "$(dispatch_block_reads_rule "$AGENTS_DIR/skills/write-tests/SKILL.md" "rules/test.md")"
    assert_eq "U6f: WT-6 carries NO rules/ops.md reference (pins the deliberate C4 omission)" \
        "no" "$(dispatch_block_reads_rule "$AGENTS_DIR/skills/write-tests/SKILL.md" "rules/ops.md")"
}

# U6g -- NEGATIVE CONTROL for dispatch_block_reads_rule: the SAME predicate must answer "no"
# when the rule reference sits outside the dispatch block (FX-1, ahead of the `mode: "default"`
# marker) and "yes" for the in-block fixture (FX-2, the marker line itself) -- otherwise a
# passing U6c-f tells us nothing about block-scoping.
# The `negated` position is C3's inversion row: the Read sits INSIDE the block with the right
# rule path, but the line forbids it -- the predicate must still answer "no". `mixed` puts both
# lines in the block: a whole-blob negation check would let the forbidding line veto the real
# directive, so the verdict has to be reached per line.
make_rule_position_fixture() { # <path> <rule> <position: in-block|out-of-block|negated|mixed>
    local path="$1" rule="$2" pos="$3"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' 'FX-1. Preceding step, ahead of the dispatch block.' > "$path"
    [ "$pos" = "out-of-block" ] && printf '   Read `%s` here, outside the block.\n' "$rule" >> "$path"
    printf '%s\n' 'FX-2. Launch a subagent (Agent tool, mode: "default").' >> "$path"
    [ "$pos" = "negated" ] || [ "$pos" = "mixed" ] \
        && printf '   Do not Read `%s` — the orchestrator already did.\n' "$rule" >> "$path"
    [ "$pos" = "in-block" ] || [ "$pos" = "mixed" ] \
        && printf '   Read `%s` inside the block.\n' "$rule" >> "$path"
    printf '%s\n' 'FX-3. Following step, past the end of the dispatch block.' >> "$path"
}

u6g_rule_reference_position_control() {
    local id rule pos want file
    while IFS='#' read -r id rule pos want; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        file="$FIXROOT/u6g/$id.md"
        make_rule_position_fixture "$file" "$rule" "$pos"
        assert_eq "U6g[$id]: a $rule Read placed $pos -> $want" \
            "$want" "$(dispatch_block_reads_rule "$file" "$rule")"
    done <<'U6G_CASES'
in-block#rules/ops.md#in-block#yes
out-of-block#rules/ops.md#out-of-block#no
negated#rules/ops.md#negated#no
mixed#rules/ops.md#mixed#yes
U6G_CASES
}

# U6h -- NEGATIVE CONTROL for dispatch_timing_updated (#2141 review finding): the two-trigger
# check alone cannot tell a real directive from its negation, since a forbidding line carries the
# same "before Bash command" / "before writing" tokens the greps match on. `negated` proves the
# guard now drops that line (must answer "no"); `mixed` proves it does not let the negated line
# veto a real directive sitting alongside it in the same block (per-line, not whole-blob).
u6h_timing_negation_control() {
    local id kind want file
    while IFS='#' read -r id kind want; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        file="$FIXROOT/u6h/$id.md"
        make_site_fixture "$file" "$kind"
        assert_eq "U6h[$id]: dispatch_timing_updated with a $kind directive -> $want" \
            "$want" "$(dispatch_timing_updated "$file")"
    done <<'U6H_CASES'
negated#negated#no
mixed#mixed#yes
U6H_CASES
}

# U-AL (#2140/#2141 review finding C1): pins WT-6's A-layer language essence reference. A bare
# whole-file substring check cannot tell "the applicability list, the referenced heading, and
# the 'before the first Edit' timing all land INSIDE the dispatch block, on the SAME line" apart
# from a stale mention sitting elsewhere in a 200-line SKILL.md -- same rationale as
# dispatch_timing_updated above. `deleted` (line absent) and `out-of-block` (line present but
# outside the dispatch step) are the negative fixtures a whole-file grep could not distinguish.
# NOTE: `grep -Fi` (fixed-string + case-insensitive together) on a line containing multibyte
# UTF-8 (these SKILL.md files carry em/en dashes) crashes GNU grep 3.0 (SIGABRT) on this host --
# plain `grep -i` is used below instead; none of these literals need -F's metacharacter safety.
A_LAYER_LINE='   The subagent prompt MUST instruct: for Bash, PowerShell, JSON, or YAML test files, apply the A-layer language essence section before the first Edit.'

dispatch_block_has_a_layer_ref() { # <skill-file> -> yes|no
    local blk hits
    blk="$(dispatch_block "$1")"
    [ -n "$blk" ] || { printf 'no'; return; }
    hits="$(printf '%s\n' "$blk" \
        | grep -F -- 'A-layer language essence' \
        | grep -i -- 'Bash' \
        | grep -i -- 'PowerShell' \
        | grep -i -- 'JSON' \
        | grep -i -- 'YAML' \
        | grep -Ei -- 'before (the )?first Edit')"
    [ -n "$hits" ] && printf 'yes' || printf 'no'
}

make_a_layer_fixture() { # <path> <position: in-block|out-of-block|deleted>
    local path="$1" pos="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' 'FX-1. Preceding step, ahead of the dispatch block.' > "$path"
    [ "$pos" = "out-of-block" ] && printf '%s\n' "$A_LAYER_LINE" >> "$path"
    printf '%s\n' 'FX-2. Launch a subagent (Agent tool, mode: "default").' >> "$path"
    [ "$pos" = "in-block" ] && printf '%s\n' "$A_LAYER_LINE" >> "$path"
    printf '%s\n' 'FX-3. Following step, past the end of the dispatch block.' >> "$path"
}

u_al_a_layer_directive_pin() {
    local id pos want file
    while IFS='#' read -r id pos want; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        if [ "$pos" = "real" ]; then
            assert_eq "UAL[$id]: WT-6 dispatch block carries the A-layer applicability+heading+timing reference" \
                "$want" "$(dispatch_block_has_a_layer_ref "$AGENTS_DIR/skills/write-tests/SKILL.md")"
            continue
        fi
        file="$FIXROOT/ual/$id.md"
        make_a_layer_fixture "$file" "$pos"
        assert_eq "UAL[$id]: A-layer reference $pos -> $want" \
            "$want" "$(dispatch_block_has_a_layer_ref "$file")"
    done <<'UAL_CASES'
real-write-tests#real#yes
in-block#in-block#yes
out-of-block#out-of-block#no
deleted#deleted#no
UAL_CASES

    ROWS=$((ROWS + 1))
    # heading_lineno() matches a WHOLE line (grep -Fx), so the literal here must be the exact
    # heading text in skills/write-code/SKILL.md, not merely a prefix of it.
    assert_eq "UAL[heading]: write-code/SKILL.md still carries the referenced A-layer language essence heading" \
        "yes" "$([ "$(heading_lineno "$AGENTS_DIR/skills/write-code/SKILL.md" '## A-layer language essence (complement of B-layer — zero overlap with `rules/coding/*.md`)')" != "0" ] && echo yes || echo no)"
}

# U6i (#2140/#2141 review finding C2): TIMING/ORDERING for dispatch_block_reads_rule. Presence +
# non-negation cannot tell "Read X before Y" from "Read X after Y" -- both carry the same rule
# path, the same "Read" token, and neither is a grammatical negation of the Read itself. Each
# real-site row below pins the actual timing phrase; each wrong-way row swaps "before" for
# "after" while keeping every other token, and must be rejected.
dispatch_block_reads_rule_ordered() { # <skill-file> <rule-path> <timing-ERE> -> yes|no
    local blk hits ln filtered=""
    blk="$(dispatch_block "$1")"
    [ -n "$blk" ] || { printf 'no'; return; }
    hits="$(printf '%s\n' "$blk" | grep -F -- "$2" | grep -F -- 'Read')"
    [ -n "$hits" ] || { printf 'no'; return; }
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        [ "$(line_negates_read "$ln")" = "no" ] && filtered="$filtered$ln"$'\n'
    done <<HITS
$hits
HITS
    [ -n "$filtered" ] || { printf 'no'; return; }
    if printf '%s' "$filtered" | grep -Eiq -- "$3"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

OPS_TIMING_ERE='before[[:space:]]+(any|the)[^.]*self-repair'
CODING_TIMING_ERE='before[[:space:]]+(the[[:space:]]+)?first[[:space:]]+Edit'
TEST_TIMING_ERE='before[[:space:]]+writing[[:space:]]+or[[:space:]]+running[[:space:]]+tests'

make_ordered_rule_fixture() { # <path> <line-text>
    local path="$1" line="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' 'FX-1. Preceding step, ahead of the dispatch block.' > "$path"
    printf '%s\n' 'FX-2. Launch a subagent (Agent tool, mode: "default").' >> "$path"
    printf '   %s\n' "$line" >> "$path"
    printf '%s\n' 'FX-3. Following step, past the end of the dispatch block.' >> "$path"
}

u6i_dispatch_reads_rule_ordering() {
    local id file rule timing want
    while IFS='#' read -r id file rule timing want; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "U6i[$id]: real dispatch site timing for $rule" \
            "$want" "$(dispatch_block_reads_rule_ordered "$AGENTS_DIR/$file" "$rule" "$timing")"
    done <<U6I_REAL_CASES
wcd4-ops#skills/write-code/SKILL.md#rules/ops.md#$OPS_TIMING_ERE#yes
wcd4-coding#skills/write-code/SKILL.md#rules/coding.md#$CODING_TIMING_ERE#yes
wt6-coding#skills/write-tests/SKILL.md#rules/coding.md#$CODING_TIMING_ERE#yes
wt6-test#skills/write-tests/SKILL.md#rules/test.md#$TEST_TIMING_ERE#yes
U6I_REAL_CASES

    ROWS=$((ROWS + 1))
    make_ordered_rule_fixture "$FIXROOT/u6i/wrong-ops.md" \
        'Read `rules/ops.md` after any destructive or system-state-changing command inside self-repair.'
    assert_eq "U6i[wrong-ops]: a wrong-way 'after ... self-repair' ordering for rules/ops.md is rejected" \
        "no" "$(dispatch_block_reads_rule_ordered "$FIXROOT/u6i/wrong-ops.md" 'rules/ops.md' "$OPS_TIMING_ERE")"

    ROWS=$((ROWS + 1))
    make_ordered_rule_fixture "$FIXROOT/u6i/wrong-coding.md" \
        'Read `rules/coding.md` after the first Edit, once changes are already made.'
    assert_eq "U6i[wrong-coding]: a wrong-way 'after the first Edit' ordering for rules/coding.md is rejected" \
        "no" "$(dispatch_block_reads_rule_ordered "$FIXROOT/u6i/wrong-coding.md" 'rules/coding.md' "$CODING_TIMING_ERE")"

    ROWS=$((ROWS + 1))
    make_ordered_rule_fixture "$FIXROOT/u6i/wrong-test.md" \
        'Read `rules/test.md` after writing or running tests, to confirm compliance.'
    assert_eq "U6i[wrong-test]: a wrong-way 'after writing or running tests' ordering for rules/test.md is rejected" \
        "no" "$(dispatch_block_reads_rule_ordered "$FIXROOT/u6i/wrong-test.md" 'rules/test.md' "$TEST_TIMING_ERE")"
}

u6_both_sites_updated
u7_orth_negative_control
u6cdef_wcd4_wt6_rule_reads
u6g_rule_reference_position_control
u6h_timing_negation_control
u_al_a_layer_directive_pin
u6i_dispatch_reads_rule_ordering

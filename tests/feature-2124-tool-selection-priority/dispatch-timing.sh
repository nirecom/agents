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
    local blk hits
    blk="$(dispatch_block "$1")"
    [ -n "$blk" ] || { printf 'no'; return; }
    hits="$(printf '%s\n' "$blk" | grep -F -- 'rules/shell-commands.md' | grep -F -- 'Read')"
    [ -n "$hits" ] || { printf 'no'; return; }
    if printf '%s\n' "$hits" \
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

u6_both_sites_updated
u7_orth_negative_control

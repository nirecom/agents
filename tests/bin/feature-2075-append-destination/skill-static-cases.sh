#!/usr/bin/env bash
# Tests: skills/write-tests/SKILL.md, skills/review-tests/SKILL.md, skills/_shared/test-design.md, skills/_shared/test-design/append-vs-new.md, install/settings-allow-commands.txt, skills/review-tests/scripts/select-staged-files.sh, skills/run-tests/SKILL.md, bin/lib/test-frontmatter-fix.sh
# Tags: scope:issue-specific
# Part of tests/feature-2075-append-destination.sh (rules/coding/file-split.md).
# Cases S1-S13: the static / script-level half of the contract. The reviewer LLM
# actually raising the gap is TL4 and stays out of scope (plan: Confirmed non-goals),
# so these pin the SHAPE RT-1a and WT-5 must keep for that judgement to be possible.

# label_block <file> <start-ere> <stop-ere> — the step body from its label line up
# to the next sibling label. Sub-labels are indented, so `^WT-[0-9]` stops only at
# the next integer step.
label_block() {
    awk -v s="$2" -v e="$3" '
        $0 ~ s { on = 1; print; next }
        on && $0 ~ e { on = 0 }
        on { print }
    ' "$1" 2>/dev/null
}

assert_match() {
    if printf '%s\n' "$3" | grep -qE "$2"; then pass "$1"; else fail "$1 — nothing matched /$2/"; fi
}
assert_no_match() {
    if printf '%s\n' "$3" | grep -qE "$2"; then fail "$1 — /$2/ matched but must not"; else pass "$1"; fi
}

WT_TEXT="$(cat "$WT_SKILL" 2>/dev/null)"
RT_TEXT="$(cat "$RT_SKILL" 2>/dev/null)"
WT5_BLOCK="$(label_block "$WT_SKILL" '^WT-5\.' '^WT-[0-9]')"
WT7_BLOCK="$(label_block "$WT_SKILL" '^WT-7\.' '^WT-[0-9]')"
RT1A_BLOCK="$(label_block "$RT_SKILL" '^RT-1a\.' '^RT-[0-9]')"

# ── S1 the new WT-5 exists and delegates the decision to the helper ────────
case_ran S1
assert_match "S1 write-tests SKILL.md has a WT-5 step" '^WT-5\.' "$WT_TEXT"
assert_match "S1 WT-5 runs bin/find-tests-for-source.sh" 'find-tests-for-source\.sh' "$WT5_BLOCK"

# ── S2 the +1 renumber landed on every sibling ────────────────────────────
case_ran S2
for _lbl in '^WT-6\.' '^WT-7\.' '^WT-8\.'; do
    assert_match "S2 write-tests SKILL.md has $_lbl" "$_lbl" "$WT_TEXT"
done
for _sub in 'WT-7a\.' 'WT-7b\.' 'WT-7c\.' 'WT-7d\.' 'WT-7e\.'; do
    assert_match "S2 dispatch sub-step $_sub survived the renumber" "$_sub" "$WT_TEXT"
done
assert_no_match "S2 the pre-renumber WT-6a label is gone" 'WT-6a\.' "$WT_TEXT"

# ── S3 no decimal step labels (rules/prompt.md 4.1) ───────────────────────
case_ran S3
assert_no_match "S3 no decimal WT label" '^WT-[0-9]+\.[0-9]' "$WT_TEXT"

# ── S4 the dispatch block carries the new structured field ────────────────
case_ran S4
assert_match "S4 WT-7 dispatch block declares test_destinations" 'test_destinations' "$WT7_BLOCK"
assert_match "S4 planned_cases still travels with it" 'planned_cases' "$WT7_BLOCK"

# ── S5 RT-1a exists and drives both commands ──────────────────────────────
case_ran S5
assert_match "S5 review-tests SKILL.md has an RT-1a step" '^RT-1a\.' "$RT_TEXT"
assert_match "S5 RT-1a calls select-staged-files.sh --added-only" '\-\-added-only' "$RT1A_BLOCK"
assert_match "S5 RT-1a calls the helper with --test-file" '\-\-test-file' "$RT1A_BLOCK"

# ── S6 fork context: each RT-1a command span is one standalone command ────
# Only the backticked command spans are inspected — the surrounding prose may
# legitimately contain a semicolon.
case_ran S6
S6_SPANS="$(printf '%s\n' "$RT1A_BLOCK" | grep -oE '`bash "[^`]*`')"
S6_COUNT="$(printf '%s' "$S6_SPANS" | grep -c . || true)"
if [[ "$S6_COUNT" -ge 2 ]]; then
    pass "S6 RT-1a spells out both command spans"
else
    fail "S6 RT-1a has $S6_COUNT backticked bash command spans, expected at least 2"
fi
S6_BAD="$(printf '%s\n' "$S6_SPANS" | grep -cE '&&|\||;' || true)"
assert_eq "S6 no RT-1a command span chains or pipes" "0" "$S6_BAD"

# ── S7 the shared prompt gained the pointer and stayed under its HARD limit ─
case_ran S7
assert_match "S7 test-design.md points at test-design/append-vs-new.md" \
    'test-design/append-vs-new\.md' "$(cat "$TD_SHARED" 2>/dev/null)"
S7_LINES="$(grep -c '' "$TD_SHARED" 2>/dev/null || echo 0)"
if [[ "$S7_LINES" -le 200 && "$S7_LINES" -gt 0 ]]; then
    pass "S7 test-design.md is $S7_LINES lines, within the 200-line HARD limit"
else
    fail "S7 test-design.md is $S7_LINES lines (HARD limit 200, and it must not be empty)"
fi

# ── S8 the new detail file follows the detail-file opening convention ──────
case_ran S8
assert_match "S8 append-vs-new.md opens with the detail-file quote line" \
    '^> Detail file of' "$(head -n 1 "$TD_APPEND" 2>/dev/null)"

# ── S9 the helper is admitted to the allow-list SSOT ───────────────────────
case_ran S9
assert_match "S9 settings-allow-commands.txt admits bin/find-tests-for-source.sh" \
    '^bin/find-tests-for-source\.sh$' "$(cat "$ALLOW_TXT" 2>/dev/null)"

# ── S10 select-staged-files.sh --added-only, on a real staged fixture ──────
case_ran S10
S10REPO="$(make_repo)"
printf 'one\n' > "$S10REPO/tracked.txt"
git -C "$S10REPO" add -A >/dev/null 2>&1
git -C "$S10REPO" commit -q --no-verify -m fixture >/dev/null 2>&1
printf 'two\n' >> "$S10REPO/tracked.txt"
printf 'new\n' > "$S10REPO/added.txt"
git -C "$S10REPO" add -A >/dev/null 2>&1

SOUT=""
SRC=0
run_select() {
    local outf errf
    outf="$(mktemp)"; errf="$(mktemp)"
    (
        cd "$S10REPO" || exit 1
        SESSION_ID="" \
        CLAUDE_SESSION_ID="" \
        CLAUDE_CODE_SESSION_ID="feature-2075-nostate-sid" \
        CLAUDE_ENV_FILE="" \
        AGENTS_CONFIG_DIR="$AGENTS_ROOT" \
            bash "$RUN_TIMEOUT" 60 bash "$SELECT_SH" "$@"
    ) >"$outf" 2>"$errf"
    SRC=$?
    SOUT="$(cat "$outf" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
    rm -f "$outf" "$errf"
}

run_select
assert_eq "S10 default selection exit code" "0" "$SRC"
assert_eq "S10 default selection lists the added and the modified file" "added.txt tracked.txt" "$SOUT"
run_select --added-only
assert_eq "S10 --added-only exit code" "0" "$SRC"
assert_eq "S10 --added-only lists the added file alone" "added.txt" "$SOUT"

# ── S11 the gap predicate reads `viable`, never `verdict` (C1 regression) ──
case_ran S11
assert_match "S11 RT-1a names the viable column as the gap predicate" 'viable' "$RT1A_BLOCK"
assert_match "S11 RT-1a rules the verdict column out explicitly" \
    'never.*verdict|verdict.*never' "$RT1A_BLOCK"

# ── S12 the escape hatch stays shut (C2 regression) ───────────────────────
case_ran S12
TDA_TEXT="$(cat "$TD_APPEND" 2>/dev/null)"
S12_MENTIONS="$(printf '%s\n' "$TDA_TEXT" | grep -cE 'cross-hook|distinct-layer' || true)"
if [[ "$S12_MENTIONS" -ge 1 ]]; then
    pass "S12 append-vs-new.md addresses cross-hook / distinct-layer at all"
else
    fail "S12 append-vs-new.md never mentions cross-hook / distinct-layer, so it never rules them out"
fi
S12_LOOSE="$(printf '%s\n' "$TDA_TEXT" | grep -E 'cross-hook|distinct-layer' | grep -cvE 'not|never|Not|NOT|only' || true)"
assert_eq "S12 every cross-hook / distinct-layer mention is a negation" "0" "$S12_LOOSE"
assert_match "S12 RT-1a denies any dup-group-keep waiver" \
    'dup-group-keep.*(NOT|not|never)|(NOT|not|never).*dup-group-keep' "$RT1A_BLOCK"
assert_match "S12 RT-1a validates the tag against the excluded column" 'excluded' "$RT1A_BLOCK"
assert_match "S12 RT-1a validates the tag against the reason column" 'reason' "$RT1A_BLOCK"
assert_match "S12 RT-1a names the size-hard-limit claim it validates" 'size-hard-limit' "$RT1A_BLOCK"

# ── S13 both git diff --cached call sites honour the added-only filter ─────
# Counted rather than spelled out: the filter may be applied literally or through
# a variable, but a call site that carries neither is the forgotten-path bug.
case_ran S13
SEL_TEXT="$(cat "$SELECT_SH" 2>/dev/null)"
S13_SITES="$(printf '%s\n' "$SEL_TEXT" | grep -c 'diff --cached' || true)"
S13_FILTERED="$(printf '%s\n' "$SEL_TEXT" | grep 'diff --cached' | grep -cE 'diff-filter|FILTER|ADDED' || true)"
if [[ "$S13_SITES" -ge 2 ]]; then
    pass "S13 select-staged-files.sh still has $S13_SITES git diff --cached call sites"
else
    fail "S13 expected at least 2 git diff --cached call sites, found $S13_SITES"
fi
assert_eq "S13 every call site applies the added-only filter" "$S13_SITES" "$S13_FILTERED"
assert_match "S13 the script knows the --diff-filter=A spelling" '\-\-diff-filter=A' "$SEL_TEXT"
assert_match "S13 the script accepts the --added-only flag" '\-\-added-only' "$SEL_TEXT"

# ── S14-S19 the RULES the steps must carry, not merely their labels ────────
# S1-S13 pin that WT-5 / RT-1a exist and which COLUMNS they read. The rules a
# reader has to obey once there — append is mandatory, groups are keyed by the
# complete source set, each source set's `new` verdict generates one independent new file, the gate is presented after the
# decision — live in prose and are what a well-meaning rewrite loses first.
TDA_FULL="$(cat "$TD_APPEND" 2>/dev/null)"

# ── S14 append is the default and the mandatory outcome ───────────────────
case_ran S14
assert_match "S14 WT-5 states that append is mandatory" \
    '[Aa]ppend.*(mandatory|MUST|must)|(mandatory|MUST|must).*append' "$WT5_BLOCK"
assert_match "S14 WT-5 names the sole permitted new file when a target exists" \
    'size-hard-limit' "$WT5_BLOCK"
assert_match "S14 WT-5 forbids deciding by eye" 'by eye|do not decide|never decide' "$WT5_BLOCK"
assert_match "S14 append-vs-new.md states the append-by-default rule" \
    '[Dd]efault.*append|[Aa]ppend.*default' "$TDA_FULL"

# ── S15 every group is keyed by its COMPLETE source set ───────────────────
case_ran S15
assert_match "S15 WT-5 requires the complete source set per planned case" \
    'complete source set|source set S' "$WT5_BLOCK"
assert_match "S15 the dispatch block keys test_destinations by that set" \
    'source set' "$WT7_BLOCK"

# ── S16 each source set's `new` verdict generates one independent new file ──
case_ran S16
assert_match "S16 each source set's new verdict generates one independent new file" \
    'generates its own independent new file|independent new file' "$WT7_BLOCK"
assert_match "S16 crossing the HARD limit tags a new file instead of splitting" \
    'one new file per source set' "$WT7_BLOCK"

# ── S17 the CONFIRM_TESTS gate is presented WITH the destinations ─────────
case_ran S17
assert_match "S17 the gate branch lives in WT-5, after the decision" \
    'GATE_CONFIRM_TESTS' "$WT5_BLOCK"
assert_match "S17 WT-5 waits for confirmation before the next step" \
    'wait|confirm' "$WT5_BLOCK"

# ── S18 the ranking order is written down where the decision is explained ─
case_ran S18
assert_match "S18 append-vs-new.md ranks exact matches first" \
    '[Ee]xact' "$TDA_FULL"
assert_match "S18 append-vs-new.md ranks by extra tokens, line count and path" \
    'fewer|superset|line|path' "$TDA_FULL"

# ── S19 no union of `# Tests:` sets, and the header is never rewritten ────
case_ran S19
assert_match "S19 append-vs-new.md limits the target to the subset rule" \
    'S ⊆ T|subset' "$TDA_FULL"
assert_match "S19 append-vs-new.md forbids rewriting the # Tests: line" \
    '(not|never|do not).*rewrite|rewrite.*(not|never)' "$TDA_FULL"
assert_match "S19 the dispatch schema repeats the never-rewrite rule to the subagent" \
    'never rewrite|do not rewrite' "$WT7_BLOCK"

# ── S20 RNT-3 Tier 2 keeps working off the same frontmatter (MUST class) ──
# The `# Tests:` axis is shared with run-tests' selection stage; this issue
# changes neither the header nor the parser, so Tier 2 must still key off both
# headers and must still match on ANY token, not the first one.
case_ran S20
RNT_SKILL="$AGENTS_ROOT/skills/run-tests/SKILL.md"
RNT_TEXT="$(cat "$RNT_SKILL" 2>/dev/null)"
RNT3_BLOCK="$(label_block "$RNT_SKILL" '^RNT-3\.' '^RNT-[0-9]')"
assert_match "S20 RNT-3 still reads the # Tests: header" '# Tests:' "$RNT3_BLOCK"
assert_match "S20 RNT-3 still reads the # Tags: header" '# Tags:' "$RNT3_BLOCK"
assert_match "S20 RNT-3 still selects on overlap, not on set equality" \
    'overlap' "$RNT3_BLOCK"
S20_LIB="$AGENTS_ROOT/bin/lib/test-frontmatter-fix.sh"
if [[ -f "$S20_LIB" ]]; then
    S20REPO="$(make_repo)"
    add_test_file "$S20REPO" "bin/multi.sh" "src/a.js,src/b.js,src/c.js" "scope:common" 20
    (
        # shellcheck source=../../bin/lib/test-frontmatter-fix.sh
        . "$S20_LIB"
        tfm_parse_tests_line "$S20REPO/tests/bin/multi.sh"
        printf '%s\n' "${#TFM_TOKENS[@]}"
        printf '%s\n' "${TFM_TOKENS[2]-}"
    ) > "$TMPDIR_BASE/s20.out" 2>/dev/null
    assert_eq "S20 the shared tokenizer exposes all three tokens" "3" \
        "$(sed -n 1p "$TMPDIR_BASE/s20.out")"
    assert_eq "S20 a NON-first source token is still reachable for Tier 2 overlap" \
        "src/c.js" "$(sed -n 2p "$TMPDIR_BASE/s20.out")"
else
    fail "S20 bin/lib/test-frontmatter-fix.sh is missing — the Tier 2 token axis cannot be checked"
fi

grp_done "skill-static-cases.sh"

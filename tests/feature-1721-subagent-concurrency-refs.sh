#!/usr/bin/env bash
# tests/feature-1721-subagent-concurrency-refs.sh
# Tests: skills/_shared/subagent-concurrency.md, skills/workflow-init/SKILL.md, skills/review-code-security/SKILL.md, skills/worktree-end/SKILL.md, skills/issue-close-finalize/SKILL.md, skills/_shared/codex-review-loop.md, skills/write-tests/SKILL.md, skills/review-tests/SKILL.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, skills/clarify-intent/SKILL.md
# Tags: subagent-concurrency, skill-orchestration, static, regression, TL1, scope:issue-specific
#
# Issue #1721 — subagent dispatch concurrency policy is stated once in
# skills/_shared/subagent-concurrency.md (SC-P parallel / SC-S serial /
# SC-W wait) and referenced from each dispatch site instead of being
# re-explained inline.
#
# The regression that matters is the SYMMETRIC PAIR: worktree-end WE-9 and
# issue-close-finalize's initial delegation pass are the same shape of
# serial-by-dependency dispatch. Annotating one and forgetting the other is
# exactly the #1721 defect, so either span failing fails the whole run.
# A second axis is SYNTAX DRIFT: the annotation must be the exact literal
# `Serial by dependency (SC-S):` — a variant like `(SC-S, path)` must FAIL.
#
# TL1 (static): the subject is prompt text, read directly off disk. No live
# LLM call, no runtime behavior.
#
# TL3 gap (what this test does NOT catch):
# - An orchestrator that reads the SC-P/SC-S annotations yet still dispatches
#   independent subagents sequentially across turns at runtime.
# Closest-to-action mitigation: manual review during /review-code of every new or
# edited SKILL.md dispatch block against the SC-P rule in
# skills/_shared/subagent-concurrency.md.
#
# Expected to FAIL until the #1721 write-code step creates
# skills/_shared/subagent-concurrency.md and lands the references.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_REL="skills/_shared/subagent-concurrency.md"
SHARED_MD="$AGENTS_DIR/$SHARED_REL"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sc-refs-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# The serial annotation literal, matched through the trailing colon.
SC_S_LITERAL='Serial by dependency (SC-S):'
SC_S_LOOSE='Serial by dependency (SC-S'

has_prefix_line() {
    awk -v p="$2" 'substr($0, 1, length(p)) == p { found = 1; exit } END { exit !found }' "$1"
}

# Block = [start-prefix, end-prefix). Anchors are literal line prefixes, not
# regexes, so `.` / `+` in step labels cannot be reinterpreted. A never-matching
# end anchor would swallow the rest of the file and turn a scoped grep into a
# false green, so every caller asserts the end anchor exists independently.
extract_block() {
    awk -v s="$2" -v e="$3" '
        function pre(line, p) { return substr(line, 1, length(p)) == p }
        !inb && pre($0, s) { inb = 1 }
        inb && seen && pre($0, e) { exit }
        inb { seen = 1; print }
    ' "$1"
}

# Extracts the block into a temp file and sets the BLOCK_FILE global to its path.
# Returns non-zero (having already reported the failure) when the block cannot be
# scoped. BLOCK_FILE is used instead of stdout so that this helper's own fail()
# output is never captured into the caller's variable and swallowed.
# $1=label $2=abs-path $3=start $4=end $5=max-lines
BLOCK_FILE=""
block_to_file() {
    local label="$1" path="$2" start="$3" end="$4" maxl="$5" out lines
    BLOCK_FILE=""
    if [ ! -f "$path" ]; then
        fail "$label: file missing: ${path#$AGENTS_DIR/}"
        return 1
    fi
    if ! has_prefix_line "$path" "$end"; then
        fail "$label: end anchor '$end' not found in ${path#$AGENTS_DIR/} (block scoping unreliable)"
        return 1
    fi
    out="$TMPD/block-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').md"
    extract_block "$path" "$start" "$end" > "$out"
    lines=$(wc -l < "$out" | tr -d '[:space:]')
    [ -n "$lines" ] || lines=0
    if [ "$lines" -eq 0 ]; then
        fail "$label: start anchor '$start' not found in ${path#$AGENTS_DIR/}"
        return 1
    fi
    if [ "$lines" -gt "$maxl" ]; then
        fail "$label: extracted block is $lines lines (max $maxl) — scoping looks broken"
        return 1
    fi
    BLOCK_FILE="$out"
    return 0
}

# ===========================================================================
# Group A — the shared doc exists and states the three axes
# ===========================================================================
group_shared_doc() {
    if [ ! -f "$SHARED_MD" ]; then
        fail "A1: $SHARED_REL missing"
        fail "A2: $SHARED_REL missing (headings unverifiable)"
        fail "A3: $SHARED_REL missing (SC-S literal unverifiable)"
        fail "A4: $SHARED_REL missing (line count unverifiable)"
        fail "A5: $SHARED_REL missing (inline-procedure check unverifiable)"
        return
    fi
    pass "A1: $SHARED_REL exists"

    local missing="" h
    for h in '## SC-P' '## SC-S' '## SC-W'; do
        has_prefix_line "$SHARED_MD" "$h" || missing="$missing $h"
    done
    if [ -z "$missing" ]; then
        pass "A2: $SHARED_REL declares all three axis headings (## SC-P / ## SC-S / ## SC-W)"
    else
        fail "A2: axis heading(s) missing:$missing"
    fi

    if grep -qF "$SC_S_LITERAL" "$SHARED_MD"; then
        pass "A3: $SHARED_REL defines the annotation literal '$SC_S_LITERAL'"
    else
        fail "A3: annotation literal '$SC_S_LITERAL' absent from $SHARED_REL"
    fi

    local lines
    lines=$(wc -l < "$SHARED_MD" | tr -d '[:space:]')
    [ -n "$lines" ] || lines=0
    if [ "$lines" -lt 100 ]; then
        pass "A4: $SHARED_REL is $lines lines (< 100, Pattern B WARN threshold)"
    else
        fail "A4: $SHARED_REL is $lines lines — exceeds the 100-line prompt-file WARN threshold"
    fi

    # check-inline-procedures anti-pattern: 3+ consecutive column-0 `N. ` lines.
    local runmax
    runmax=$(awk '
        /^[0-9]+\. / { run++; if (run > max) max = run; next }
        { run = 0 }
        END { print max + 0 }
    ' "$SHARED_MD")
    if [ "${runmax:-0}" -lt 3 ]; then
        pass "A5: $SHARED_REL has no 3+ consecutive column-0 numbered lines (max run ${runmax:-0})"
    else
        fail "A5: $SHARED_REL contains an inline numbered procedure (run of ${runmax} column-0 'N. ' lines)"
    fi
}

# ===========================================================================
# Group A2 — SC-P independence rule completeness (C1 regression guard)
# ===========================================================================
# A read-after-write-only definition of independence is the regression: the rule
# must ALSO cover two subagents writing the same target.
group_sc_p_independence() {
    local bf
    block_to_file "A2x-SCP" "$SHARED_MD" '## SC-P' '## SC-S' 60 || return
    bf="$BLOCK_FILE"
    local has_same has_raw
    has_same=0; has_raw=0
    grep -qF 'write the same' "$bf" && has_same=1
    grep -qF 'read/write' "$bf" && has_raw=1
    if [ "$has_same" -eq 1 ] && [ "$has_raw" -eq 1 ]; then
        pass "A6: SC-P defines independence over BOTH write-the-same-target and read-after-write"
    else
        fail "A6: SC-P independence rule incomplete" "write-the-same=$has_same read/write=$has_raw"
    fi

    # C1 substance guard: a heading + keywords do not mandate anything. The SC-P
    # section must state the actionable rule — independent dispatches go out
    # together in one assistant message.
    if grep -qF 'single assistant message' "$bf"; then
        pass "A7: SC-P mandates issuing independent dispatches in a 'single assistant message'"
    else
        fail "A7: SC-P section never says 'single assistant message' — rule is not actionable" \
            "block=$(tr '\n' '/' < "$bf")"
    fi
}

# ===========================================================================
# Group B — parallel dispatch sites reference the shared doc
# ===========================================================================
# rel | label | start-prefix | end-prefix | max-lines
PARALLEL_TABLE="skills/workflow-init/SKILL.md|B1-WI-10|### Step WI-10|### Step WI-11|30
skills/review-code-security/SKILL.md|B2-RCS-1/2|RCS-1.|## Patterns by Axis|40"

# Extracts the reference line to $SHARED_REL plus the two lines after it — the
# same 1-2 line window convention as sc_s_context/substr_context. A block can
# reference the shared doc via an unrelated SC-S or SC-W mention elsewhere and
# still pass a whole-block grep, so the SC-P specificity check below is scoped
# to this window, not the whole span.
shared_ref_context() {
    awk -v p="$SHARED_REL" 'index($0, p) { n = 3 } n > 0 { print; n-- }' "$1"
}

group_parallel_refs() {
    local rel label start end maxl path bf ctx
    while IFS='|' read -r rel label start end maxl; do
        [ -z "${rel// /}" ] && continue
        path="$AGENTS_DIR/$rel"
        block_to_file "$label" "$path" "$start" "$end" "$maxl" || continue
        bf="$BLOCK_FILE"
        if grep -qF "$SHARED_REL" "$bf"; then
            pass "$label: $rel dispatch span references $SHARED_REL"

            # C1: the reference must point at the SC-P (parallel dispatch) section
            # specifically — pointing at $SHARED_REL alone does not rule out an
            # unrelated SC-S/SC-W mention satisfying this check for free.
            ctx="$TMPD/b-ctx-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').md"
            shared_ref_context "$bf" > "$ctx"
            if grep -qF 'SC-P' "$ctx"; then
                pass "$label-scp: $rel reference names SC-P specifically"
            else
                fail "$label-scp: $rel references $SHARED_REL but never names SC-P specifically" \
                    "context=$(tr '\n' '/' < "$ctx")"
            fi
        else
            fail "$label: $rel dispatch span does not reference $SHARED_REL" "block=$(tr '\n' '/' < "$bf")"
        fi
    done <<TABLE
$PARALLEL_TABLE
TABLE
}

# Mutation probe: prove shared_ref_context + the SC-P check reject a reference
# to $SHARED_REL that names an unrelated axis instead of SC-P. Sibling to the
# C4 strict-matcher probe and C5 drift-filter probe below.
group_b_scp_ref_probe() {
    local good="$TMPD/probe-b-good.md" bad="$TMPD/probe-b-bad.md" ctx a=0 b=0
    {
        printf '%s\n' "Dispatch independent subagents together."
        printf '%s\n' "See $SHARED_REL SC-P for the parallel dispatch rule."
        printf '%s\n' "after1"
        printf '%s\n' "after2"
    } > "$good"
    {
        printf '%s\n' "Dispatch independent subagents together."
        printf '%s\n' "See $SHARED_REL SC-S for the serial dispatch rule."
        printf '%s\n' "after1"
        printf '%s\n' "after2"
    } > "$bad"
    ctx="$TMPD/probe-b-good-ctx.md"
    shared_ref_context "$good" > "$ctx"
    grep -qF 'SC-P' "$ctx" && a=1
    ctx="$TMPD/probe-b-bad-ctx.md"
    shared_ref_context "$bad" > "$ctx"
    grep -qF 'SC-P' "$ctx" || b=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then
        pass "C1: shared-doc reference check accepts an SC-P-specific reference and rejects removing the SC-P token (mutation probe)"
    else
        fail "C1: shared-doc reference SC-P check misbehaves" "accepts-good=$a rejects-bad=$b"
    fi
}

# ===========================================================================
# Group C — SC-S annotation on the symmetric pair, strict syntax
# ===========================================================================
# Minimum characters of real content required after `...(SC-S):` — enough to
# name a concrete shared-state dependency, not just restate the token.
SC_S_MIN_DETAIL=20

# Prints the remainder of the first line starting with the SC-S literal, with
# surrounding whitespace squeezed away. Empty output = bare annotation.
sc_s_detail() {
    awk -v p="$SC_S_LITERAL" '
        substr($0, 1, length(p)) == p {
            rest = substr($0, length(p) + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
            print rest
            exit
        }
    ' "$1"
}

# Prints the SC-S annotation line plus the two lines after it. Scoping the phase
# check to this window (not the whole span) keeps the span's own heading — which
# already contains the word "initial" — from satisfying the assertion for free.
sc_s_context() {
    awk -v p="$SC_S_LITERAL" '
        substr($0, 1, length(p)) == p { n = 3 }
        n > 0 { print; n-- }
    ' "$1"
}

# Same 1-2 line window, anchored on a substring instead of a line prefix. Used
# for the SC-W sites, whose token sits mid-line as `(SC-W — <ref>)`.
substr_context() {
    awk -v p="$2" 'index($0, p) { n = 3 } n > 0 { print; n-- }' "$1"
}

# rel | label | start-prefix | end-prefix | max-lines | phase-coverage (yes|-)
SERIAL_TABLE="skills/worktree-end/SKILL.md|C1-WE-9|### Step WE-9|### Step WE-10|30|-
skills/issue-close-finalize/SKILL.md|C2-ICF-initial|## Delegation — initial pass|## ICF-D..ICF-G loop|40|yes"

# The three issue-close-finalize-worker pass types. A serial annotation that
# names only one of them does not describe the real dependency chain.
ICF_PHASES="initial loop_step finalize_terminal"

group_serial_annotation() {
    local rel label start end maxl phases path bf detail dlen ph missing ctx
    while IFS='|' read -r rel label start end maxl phases; do
        [ -z "${rel// /}" ] && continue
        path="$AGENTS_DIR/$rel"
        block_to_file "$label" "$path" "$start" "$end" "$maxl" || continue
        bf="$BLOCK_FILE"
        # Strict: a LINE must START with the literal including the trailing colon.
        if ! has_prefix_line "$bf" "$SC_S_LITERAL"; then
            fail "$label: $rel span lacks a line starting with '$SC_S_LITERAL'" "block=$(tr '\n' '/' < "$bf")"
            continue
        fi
        pass "$label: $rel span carries a line starting with '$SC_S_LITERAL'"

        # The annotation must point back at the canonical doc. Without this, a
        # site can carry the token plus plausible prose and still leave the
        # reader with no route to the SSOT — the exact duplication #1721 removes.
        # Scoped to the annotation line + the 2 lines after it, the same window
        # the phase-coverage check uses.
        ctx="$TMPD/scs-ctx-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').md"
        sc_s_context "$bf" > "$ctx"
        if grep -qF "$SHARED_REL" "$ctx"; then
            pass "$label-ref: SC-S annotation points back to $SHARED_REL"
        else
            fail "$label-ref: SC-S annotation never references $SHARED_REL" \
                "context=$(tr '\n' '/' < "$ctx")"
        fi

        # C2(a): the annotation must actually say what the dependency is.
        detail="$(sc_s_detail "$bf")"
        dlen=${#detail}
        if [ "$dlen" -ge "$SC_S_MIN_DETAIL" ]; then
            pass "$label-detail: SC-S annotation names a dependency ($dlen chars after the colon)"
        else
            fail "$label-detail: SC-S annotation is bare or near-empty ($dlen chars after the colon, need >= $SC_S_MIN_DETAIL)" \
                "after-colon='$detail'"
        fi

        # C2(b): issue-close-finalize's chain spans all three worker pass types;
        # a partial annotation naming one phase must fail.
        if [ "$phases" = "yes" ]; then
            missing=""
            for ph in $ICF_PHASES; do
                grep -qF "$ph" "$ctx" || missing="$missing $ph"
            done
            if [ -z "$missing" ]; then
                pass "$label-phases: SC-S annotation context covers all three worker phases ($ICF_PHASES)"
            else
                fail "$label-phases: SC-S annotation context omits worker phase(s):$missing" \
                    "context=$(tr '\n' '/' < "$ctx")"
            fi
        fi
    done <<TABLE
$SERIAL_TABLE
TABLE
}

# Line-scoped filter over `grep -rnF` output ("path:lineno:content").
# Deliberately NOT a by-path exclusion for subagent-concurrency.md: that file
# explains the annotation syntax, but its explanatory lines quote the VALID
# colon-terminated literal, so stripping that literal SUBSTRING per line (not
# excluding the whole line) is enough. A deviant form anywhere in that same
# file — an accidental typo elsewhere in its prose, a counter-example written
# without a fenced marker, or even a deviant form on the SAME physical line as
# a valid quote — is still reported: the valid-literal substring is stripped
# from the line first, and only if nothing loose-form-shaped survives that
# strip is the line treated as clean. Only this test file is excluded
# wholesale: it must contain deviant fixtures by construction (the mutation
# probes below).
drift_filter() {
    local drift_line drift_stripped
    grep -vF 'feature-1721-subagent-concurrency-refs.sh' | while IFS= read -r drift_line; do
        drift_stripped="${drift_line//$SC_S_LITERAL/}"
        case "$drift_stripped" in
            *"$SC_S_LOOSE"*) printf '%s\n' "$drift_line" ;;
        esac
    done
}

# Repo-wide syntax-drift detection: no line may carry the loose form without the
# exact colon-terminated literal.
group_serial_syntax_drift() {
    local hits raw rc
    # The scan is run on its own so its exit status is observable. Piping it
    # straight into the filters would mask a scan failure (bad path, permission
    # error, timeout) as "no hits" and report a silent PASS.
    raw="$TMPD/drift-raw.txt"
    run_with_timeout 60 grep -rnF "$SC_S_LOOSE" "$AGENTS_DIR" \
        --include='*.md' --include='*.sh' --include='*.js' \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=_archive \
        > "$raw" 2>"$TMPD/drift-err.txt"
    rc=$?
    # grep: 0 = matched, 1 = no match (both fine). >= 2 = the scan itself broke.
    if [ "$rc" -ge 2 ]; then
        fail "C3: SC-S drift scan FAILED to run (exit $rc) — result is not a PASS" \
            "stderr=$(tr '\n' '/' < "$TMPD/drift-err.txt")"
        return
    fi
    hits=$(drift_filter < "$raw")
    if [ -z "$hits" ]; then
        pass "C3: no SC-S annotation syntax drift repo-wide (every '$SC_S_LOOSE' occurrence is the exact colon form)"
    else
        fail "C3: SC-S annotation syntax drift" "$(printf '%s' "$hits" | tr '\n' '/')"
    fi
}

# Mutation probe: prove the strict matcher rejects the deviant syntax that a
# loose prefix match would let through.
group_strict_matcher_probe() {
    local good="$TMPD/probe-good.md" bad="$TMPD/probe-bad.md" a=0 b=0
    printf '%s\n' "$SC_S_LITERAL each pass writes the same state file." > "$good"
    printf '%s\n' "Serial by dependency (SC-S, path): deviant syntax." > "$bad"
    has_prefix_line "$good" "$SC_S_LITERAL" && a=1
    has_prefix_line "$bad" "$SC_S_LITERAL" || b=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then
        pass "C4: strict matcher accepts the exact literal and rejects '(SC-S, path)' (mutation probe)"
    else
        fail "C4: strict matcher misbehaves" "accepts-good=$a rejects-bad=$b"
    fi
}

# Mutation probe for the drift filter's narrowing: the shared doc's own valid
# explanatory lines are skipped (no false positive), a deviant line in that
# SAME file is still caught, and — C4 — a line carrying BOTH the valid literal
# AND a deviant form (the substring-strip narrowing must not wholesale-exclude
# a mixed line) is caught too.
group_drift_filter_probe() {
    local raw="$TMPD/probe-drift-raw.txt" got
    local ok_valid=0 ok_deviant=0 ok_other=0 ok_mixed=0
    {
        printf '%s\n' "$SHARED_REL:12:  \`$SC_S_LITERAL <shared state, and which pass owns it first>.\`"
        printf '%s\n' "$SHARED_REL:24:- The literal prefix \`$SC_S_LITERAL\` is fixed."
        printf '%s\n' "$SHARED_REL:31:- Never write Serial by dependency (SC-S, path): typo in our own prose."
        printf '%s\n' "skills/worktree-end/SKILL.md:99:Serial by dependency (SC-S, x): drift elsewhere."
        printf '%s\n' "$SHARED_REL:40:$SC_S_LITERAL example, but also see the deviant Serial by dependency (SC-S, other): form."
    } > "$raw"
    got="$(drift_filter < "$raw")"
    printf '%s' "$got" | grep -qF "$SHARED_REL:12:" || ok_valid=1
    printf '%s' "$got" | grep -qF "$SHARED_REL:24:" || ok_valid=$((ok_valid + 1))
    printf '%s' "$got" | grep -qF "$SHARED_REL:31:" && ok_deviant=1
    printf '%s' "$got" | grep -qF 'skills/worktree-end/SKILL.md:99:' && ok_other=1
    printf '%s' "$got" | grep -qF "$SHARED_REL:40:" && ok_mixed=1
    if [ "$ok_valid" -eq 2 ] && [ "$ok_deviant" -eq 1 ] && [ "$ok_other" -eq 1 ] && [ "$ok_mixed" -eq 1 ]; then
        pass "C5/C4: drift filter skips only pure valid-literal lines, still catches a deviant line in $SHARED_REL, and catches a line mixing the valid literal with a deviant form on it (mutation probe)"
    else
        fail "C5/C4: drift filter narrowing misbehaves" \
            "valid-skipped=$ok_valid/2 deviant-caught=$ok_deviant other-caught=$ok_other mixed-caught=$ok_mixed survivors=$(printf '%s' "$got" | tr '\n' '/')"
    fi
}

# ===========================================================================
# Group D — symmetric negatives
# ===========================================================================
group_wi10_no_inline_text() {
    local bf
    block_to_file "D1-WI-10" "$AGENTS_DIR/skills/workflow-init/SKILL.md" \
        '### Step WI-10' '### Step WI-11' 30 || return
    bf="$BLOCK_FILE"
    if grep -qF 'single assistant message' "$bf"; then
        fail "D1: WI-10 still explains dispatch inline ('single assistant message') — reference-only reduction incomplete"
    else
        pass "D1: WI-10 no longer restates 'single assistant message' inline"
    fi
}

# NA-judged skills must not acquire an SC-P annotation (scope-creep guard).
NA_SKILLS="write-tests review-tests make-outline-plan make-detail-plan clarify-intent"

group_na_skills_no_scp() {
    local s path hits missing
    hits=""; missing=""
    for s in $NA_SKILLS; do
        path="$AGENTS_DIR/skills/$s/SKILL.md"
        if [ ! -f "$path" ]; then
            missing="$missing $s"
            continue
        fi
        grep -qF 'SC-P' "$path" && hits="$hits $s"
    done
    if [ -n "$missing" ]; then
        fail "D2: NA-judged SKILL.md missing:$missing"
        return
    fi
    if [ -z "$hits" ]; then
        pass "D2: no NA-judged skill (write-tests, review-tests, make-outline-plan, make-detail-plan, clarify-intent) mentions SC-P"
    else
        fail "D2: SC-P scope creep into NA-judged skill(s):$hits"
    fi
}

# ===========================================================================
# Group E — SC-W appears exactly once at each wait site
# ===========================================================================
# rel | label | start-prefix | end-prefix | max-lines   ("-" span = whole file)
WAIT_TABLE="skills/_shared/codex-review-loop.md|E1-codex-loop|-|-|0
skills/write-tests/SKILL.md|E2-WT-6|WT-6.|WT-7.|30"

# Alphanumeric characters required on the SC-W line besides the token itself.
SC_W_MIN_DETAIL=20

group_wait_annotation() {
    local rel label start end maxl path target count other wctx
    while IFS='|' read -r rel label start end maxl; do
        [ -z "${rel// /}" ] && continue
        path="$AGENTS_DIR/$rel"
        if [ "$start" = "-" ]; then
            if [ ! -f "$path" ]; then
                fail "$label: file missing: $rel"
                continue
            fi
            target="$path"
        else
            block_to_file "$label" "$path" "$start" "$end" "$maxl" || continue
            target="$BLOCK_FILE"
        fi
        count=$(grep -oF 'SC-W' "$target" | wc -l | tr -d '[:space:]')
        [ -n "$count" ] || count=0
        if [ "$count" -eq 1 ]; then
            pass "$label: $rel carries the SC-W literal exactly once"
        else
            fail "$label: $rel has $count SC-W occurrence(s), expected exactly 1"
        fi

        # A bare `SC-W` token is not wait guidance. The line carrying it must
        # also carry a sentence's worth of surrounding instruction.
        other=$(grep -F 'SC-W' "$target" | head -1 | sed 's/SC-W//g' \
            | tr -cd 'A-Za-z0-9' | wc -c | tr -d '[:space:]')
        [ -n "$other" ] || other=0
        if [ "$other" -ge "$SC_W_MIN_DETAIL" ]; then
            pass "$label-detail: SC-W sits inside actionable wait guidance ($other chars alongside the token)"
        else
            fail "$label-detail: SC-W is a bare token ($other chars alongside it, need >= $SC_W_MIN_DETAIL)" \
                "line=$(grep -F 'SC-W' "$target" | head -1)"
        fi

        # Same pointer-back requirement as the SC-S sites (symmetry: both axes
        # are annotations whose definition lives in the shared doc).
        wctx="$TMPD/scw-ctx-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').md"
        substr_context "$target" 'SC-W' > "$wctx"
        if grep -qF "$SHARED_REL" "$wctx"; then
            pass "$label-ref: SC-W annotation points back to $SHARED_REL"
        else
            fail "$label-ref: SC-W annotation never references $SHARED_REL" \
                "context=$(tr '\n' '/' < "$wctx")"
        fi
    done <<TABLE
$WAIT_TABLE
TABLE
}

group_shared_doc
group_sc_p_independence
group_parallel_refs
group_b_scp_ref_probe
group_serial_annotation
group_serial_syntax_drift
group_strict_matcher_probe
group_drift_filter_probe
group_wi10_no_inline_text
group_na_skills_no_scp
group_wait_annotation

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))

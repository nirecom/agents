# shellcheck shell=bash
# tests/skills/feature-1721-subagent-concurrency-refs/negatives-and-wait.sh — Groups D/E: symmetric negatives (no inline WI-10 text, no SC-P in NA skills) and SC-W once per wait site (site paths: the entrypoint's # Tests: header). Sourced by tests/skills/feature-1721-subagent-concurrency-refs.sh; not standalone.
# Tests: skills/_shared/subagent-concurrency.md
# Tags: subagent-concurrency, skill-orchestration, static, regression, negative, TL1, scope:issue-specific

if ! declare -F block_to_file >/dev/null 2>&1; then
    echo "negatives-and-wait.sh: sourced fragment — run tests/skills/feature-1721-subagent-concurrency-refs.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

# ===========================================================================
# Group D — symmetric negatives
# ===========================================================================
group_wi10_no_inline_text() {
    local bf
    block_to_file "D1-WI-10" "$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md" \
        '### WI-10' '### WI-11' 30 || return
    bf="$BLOCK_FILE"
    if grep -qF 'single assistant message' "$bf"; then
        fail "D1: WI-10 still explains dispatch inline ('single assistant message') — reference-only reduction incomplete"
    else
        pass "D1: WI-10 no longer restates 'single assistant message' inline"
    fi
}

# NA-judged skills must not acquire an SC-P annotation (scope-creep guard).
NA_SKILLS="write-tests review-tests make-outline-plan make-detail-plan clarify-intent"

# D2 is split into scan (per skill, accumulating) + report so each skill can sit
# in its own case span; `:=` keeps the accumulators across a re-source.
: "${NA_SCP_HITS:=}"
: "${NA_SCP_MISSING:=}"

# $@ (optional) = skills to scan; all NA_SKILLS when omitted.
group_na_skills_scan() {
    local s path list="${*:-$NA_SKILLS}"
    for s in $list; do
        path="$SCRIPT_CHECKOUT_ROOT/skills/$s/SKILL.md"
        if [ ! -f "$path" ]; then
            NA_SCP_MISSING="$NA_SCP_MISSING $s"
            continue
        fi
        grep -qF 'SC-P' "$path" && NA_SCP_HITS="$NA_SCP_HITS $s"
    done
}

group_na_skills_report() {
    local hits="$NA_SCP_HITS" missing="$NA_SCP_MISSING"
    NA_SCP_HITS=""; NA_SCP_MISSING=""
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

group_na_skills_no_scp() {
    group_na_skills_scan
    group_na_skills_report
}

# ===========================================================================
# Group E — SC-W appears exactly once at each wait site
# ===========================================================================
# Same 1-2 line window as sc_s_context (serial-annotation.sh), anchored on a
# substring instead of a line prefix. Used for the SC-W sites, whose token sits
# mid-line as `(SC-W — <ref>)`.
substr_context() {
    awk -v p="$2" 'index($0, p) { n = 3 } n > 0 { print; n-- }' "$1"
}

# rel | label | start-prefix | end-prefix | max-lines   ("-" span = whole file)
WAIT_TABLE="skills/_shared/codex-review-loop.md|E1-codex-loop|-|-|0
skills/write-tests/SKILL.md|E2-WT-7|WT-7.|WT-8.|30"

# Alphanumeric characters required on the SC-W line besides the token itself.
SC_W_MIN_DETAIL=20

# $1 (optional) = only the WAIT_TABLE row whose rel equals it; all rows when omitted.
group_wait_annotation() {
    local only="${1:-}" rel label start end maxl path target count other wctx
    while IFS='|' read -r rel label start end maxl; do
        [ -z "${rel// /}" ] && continue
        [ -n "$only" ] && [ "$rel" != "$only" ] && continue
        path="$SCRIPT_CHECKOUT_ROOT/$rel"
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

# shellcheck shell=bash
# tests/skills/feature-1721-subagent-concurrency-refs/parallel-refs.sh — Group B: parallel dispatch sites reference SC-P in the shared doc (dispatch-site paths: the entrypoint's # Tests: header). Sourced by tests/skills/feature-1721-subagent-concurrency-refs.sh; not standalone.
# Tests: skills/_shared/subagent-concurrency.md
# Tags: subagent-concurrency, skill-orchestration, static, regression, mutation-probe, TL1, scope:issue-specific

if ! declare -F block_to_file >/dev/null 2>&1; then
    echo "parallel-refs.sh: sourced fragment — run tests/skills/feature-1721-subagent-concurrency-refs.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

# ===========================================================================
# Group B — parallel dispatch sites reference the shared doc
# ===========================================================================
# rel | label | start-prefix | end-prefix | max-lines
PARALLEL_TABLE="skills/workflow-init/SKILL.md|B1-WI-10|### WI-10|### WI-11|30
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

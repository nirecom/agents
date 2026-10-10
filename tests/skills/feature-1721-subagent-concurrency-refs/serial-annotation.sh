# shellcheck shell=bash
# tests/skills/feature-1721-subagent-concurrency-refs/serial-annotation.sh — Group C: SC-S annotation on the symmetric pair (dispatch-site paths: the entrypoint's # Tests: header). Sourced by tests/skills/feature-1721-subagent-concurrency-refs.sh; not standalone.
# Tests: skills/_shared/subagent-concurrency.md
# Tags: subagent-concurrency, skill-orchestration, static, regression, symmetric-pair, TL1, scope:issue-specific

if ! declare -F block_to_file >/dev/null 2>&1; then
    echo "serial-annotation.sh: sourced fragment — run tests/skills/feature-1721-subagent-concurrency-refs.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

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

# rel | label | start-prefix | end-prefix | max-lines | phase-coverage (yes|-)
SERIAL_TABLE="skills/worktree-end/SKILL.md|C1-WE-9|### WE-9|### WE-10|30|-
skills/issue-close-finalize/SKILL.md|C2-ICF-initial|## Delegation — initial pass|## ICF-D..ICF-G loop|40|yes"

# The three issue-close-finalize-worker pass types. A serial annotation that
# names only one of them does not describe the real dependency chain.
ICF_PHASES="initial loop_step finalize_terminal"

# $1 (optional) = only the SERIAL_TABLE row whose rel equals it; all rows when omitted.
group_serial_annotation() {
    local only="${1:-}" rel label start end maxl phases path bf detail dlen ph missing ctx
    while IFS='|' read -r rel label start end maxl phases; do
        [ -z "${rel// /}" ] && continue
        [ -n "$only" ] && [ "$rel" != "$only" ] && continue
        path="$SCRIPT_CHECKOUT_ROOT/$rel"
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

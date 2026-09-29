# shellcheck shell=bash
# tests/skills/feature-1721-subagent-concurrency-refs/shared-doc.sh — Groups A/A2: the shared doc states the three axes and a complete SC-P rule. Sourced by tests/skills/feature-1721-subagent-concurrency-refs.sh; not standalone.
# Tests: skills/_shared/subagent-concurrency.md
# Tags: subagent-concurrency, skill-orchestration, static, regression, TL1, scope:issue-specific

if ! declare -F block_to_file >/dev/null 2>&1; then
    echo "shared-doc.sh: sourced fragment — run tests/skills/feature-1721-subagent-concurrency-refs.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

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

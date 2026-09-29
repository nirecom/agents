# shellcheck shell=bash
# tests/skills/feature-1721-subagent-concurrency-refs/serial-syntax.sh — Groups C3-C5: repo-wide SC-S syntax drift scan plus its strict-matcher and drift-filter mutation probes. Sourced by tests/skills/feature-1721-subagent-concurrency-refs.sh; not standalone.
# Tests: skills/_shared/subagent-concurrency.md
# Tags: subagent-concurrency, skill-orchestration, static, regression, syntax-drift, mutation-probe, TL1, scope:issue-specific

if ! declare -F block_to_file >/dev/null 2>&1; then
    echo "serial-syntax.sh: sourced fragment — run tests/skills/feature-1721-subagent-concurrency-refs.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

# Line-scoped filter over `grep -rnF` output ("path:lineno:content").
# Deliberately NOT a by-path exclusion for subagent-concurrency.md: its explanatory lines quote the VALID colon-terminated literal, so stripping that literal SUBSTRING per line (rather than excluding the whole line) is enough, and a deviant form anywhere in that same file — a typo elsewhere in its prose, an unfenced counter-example, even a deviant form on the SAME physical line as a valid quote — is still reported: the valid literal is stripped first, and the line counts as clean only when nothing loose-form-shaped survives that strip.
# Only this test's own files (the entrypoint and its sibling fragment folder) are excluded wholesale: they must contain deviant fixtures by construction (the mutation probes below).
drift_filter() {
    local drift_line drift_stripped
    grep -vF 'feature-1721-subagent-concurrency-refs' | while IFS= read -r drift_line; do
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

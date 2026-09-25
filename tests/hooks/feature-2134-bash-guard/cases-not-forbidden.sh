# tests/feature-2134-bash-guard/cases-not-forbidden.sh
# Tests: hooks/bash-guard/forbidden-literals.js, hooks/bash-guard/judge.js, bin/print-forbidden-literals, rules/shell-commands.md
# Tags: hook, bash-guard, forbidden-literals, ssot, scope:issue-specific, pwsh-not-required, TL2
# F1-F5: the boundary of the approved forbidden set. Sourced by the dispatcher.

# WHY `||` AND `&` ARE ABSENT (codex round 1, C7). The approved set is the table in
# rules/shell-commands.md, and that table lists `&&` alone. Enforcing `||` or background `&`
# would make the code enforce a rule the discipline document does not state -- the exact
# inversion of CPR-SSOT this feature exists to fix. The asymmetry with `&&` is real and is
# recorded as a follow-up issue for the document's owner, not silently closed in code.

f1_not_forbidden() {
    local name cmd got
    while IFS='~' read -r name cmd; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_of "$cmd")"
        assert_eq "F1/$name: outside the approved set, so not denied" "allow" "$got"

        got="$(probe hit-ids "$cmd")"
        assert_eq "F1/$name: produces no hit at all" "" "$got"
    done <<'TABLE'
or-list    ~ npm test || true
background ~ node server.js &
newline    ~ git status\nls
TABLE
    # `newline` row above: verified real-bash separator (bash -c $'true\necho x' runs both
    # lines), but hooks/lib/command-ir/ does not record it -- tracked, deferred gap #1253
    # (docs/architecture/claude-code/shell-command-parsing.md "Known gap"), not this PR's scope.
}

f1_not_forbidden

# F2: the id set is exactly ten, in the order of the rules/shell-commands.md table. A
# substring match such as includes("|") would drag `||` back in through the side door.
F2_WANT="chain-and,chain-semicolon,pipe,backtick,cmd-subst,brace-group,heredoc,redirect-out,redirect-append,env-prefix"
assert_eq "F2: forbidden-literals.js holds exactly the ten approved ids in table order" \
    "$F2_WANT" "$(probe ids '')"

# F3: ten ids fold onto seven document rows (`&&`/`;` share one, the two substitution forms
# share one, the two redirect forms share one).
assert_eq "F3: the ten ids fold onto seven rules/shell-commands.md rows" "7" "$(probe row-count '')"

# F4: the set is frozen -- a consumer must not be able to push an eleventh literal at runtime.
assert_eq "F4: the forbidden-literal table is frozen" "true" "$(probe literals-frozen '')"

# F5: the generator that stamps the document reads the same SSOT. If the ids drift apart, the
# guard denies something the discipline document never told the model about.
PFL="$AGENTS_DIR/bin/print-forbidden-literals"
if [ -x "$PFL" ] || [ -f "$PFL" ]; then
    f5_got="$(run_with_timeout 30 node "$(node_path "$PFL")" --ids 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
else
    f5_got="<MISSING:bin/print-forbidden-literals>"
fi
assert_eq "F5: bin/print-forbidden-literals --ids agrees with the module SSOT" "$F2_WANT" "$f5_got"

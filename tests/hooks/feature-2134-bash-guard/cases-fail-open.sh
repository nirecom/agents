# tests/feature-2134-bash-guard/cases-fail-open.sh
# Tests: hooks/bash-guard/judge.js, hooks/bash-guard.js, hooks/lib/command-ir.js
# Tags: hook, bash-guard, fail-open, error-handling, scope:issue-specific, pwsh-not-required, TL2
# O1-O4: the named exception to deny-on-doubt. Sourced by the dispatcher.

# WHY FAIL-OPEN HERE, AND ONLY HERE (CPR-UNV: an exception gets a name and a boundary).
# Other hooks/ guards protect security boundaries, so an unreadable command must read as
# dangerous. bash-guard protects PRESENTATION: passing a compound command costs tidiness,
# while denying one the parser merely failed to read stops the session. So parseFailure
# allows, and a throw inside judge() allows. If a later change flips this to fail-closed,
# these rows are what it has to delete -- and that deletion shows up in review.

o1_parse_failure() {
    local name cmd got
    while IFS='~' read -r name cmd; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_of "$cmd")"
        assert_eq "O1/$name: an unparseable command is allowed, never denied" "allow" "$got"
    done <<'TABLE'
unclosed-double ~ echo "unterminated && ls
unclosed-single ~ echo 'oops; rm -rf /tmp/x
unclosed-ansic  ~ echo $'oops && ls
TABLE
}

o1_parse_failure

# O2: a null command reaches judge() without a deny. The Bash tool always supplies one, so
# this is the shape a malformed or future payload takes.
assert_eq "O2: a null tool_input.command does not deny" "allow" "$(probe judge-null-command '')"

# O3: an input whose `command` getter throws does not deny either. Pattern 1 (negative
# assertion): the claim is that nothing was blocked, not that no stack trace printed.
assert_eq "O3: a throwing tool_input does not deny" "allow" "$(probe judge-throwing-input '')"

# O4: fail-open is a FALLBACK, not the resting state -- a well-formed compound command on the
# same path still denies. Without this row O1-O3 would pass against a guard that allows all.
assert_eq "O4: a parseable compound command still denies (fail-open is not blanket allow)" \
    "deny" "$(verdict_of 'echo one; echo two')"

# SKIPPED: forcing parse() itself to throw from inside judge() to exercise the outer catch.
# Because: parse() is required directly, so there is no seam to inject a fault through at
#          this layer without editing the module under test.
# L3 gap: a real crash inside the hook process -- covered indirectly by
#          cases-runtime-pretooluse.sh, which asserts the hook exits 0 and emits no block.

# tests/feature-2134-bash-guard/cases-fail-open.sh
# Tests: hooks/bash-guard/judge.js, hooks/bash-guard.js, hooks/lib/command-ir.js
# Tags: hook, bash-guard, fail-open, error-handling, scope:issue-specific, pwsh-not-required, TL2
# O1-O5: the named exception to deny-on-doubt. Sourced by the dispatcher.

# WHY FAIL-OPEN HERE, AND ONLY HERE (CPR-UNV: an exception gets a name and a boundary).
# Other hooks/ guards protect security boundaries, so an unreadable command must read as
# dangerous. bash-guard protects PRESENTATION: passing a compound command costs tidiness,
# # while denying one the parser merely failed to read stops the session. So parseFailure and
# a throw inside judge() pass through (no output, the host's own prompt decides) -- never
# allow, which would bypass that prompt. A flip to fail-closed must delete these rows.

o1_parse_failure() {
    local name cmd got
    while IFS='~' read -r name cmd; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(probe judge "$cmd")"
        assert_eq "O1/$name: an unparseable command passes through, never denied nor allowed" \
            "passThrough	BG-PARSE-FAILURE	-" "$got"
    done <<'TABLE'
unclosed-double ~ echo "unterminated && ls
unclosed-single ~ echo 'oops; rm -rf /tmp/x
unclosed-ansic  ~ echo $'oops && ls
TABLE
}

o1_parse_failure

# O2: a null command reaches judge() without a deny. The Bash tool always supplies one, so
# this is the shape a malformed or future payload takes.
assert_eq "O2: a null tool_input.command does not deny" "passThrough" "$(probe judge-null-command '')"

# O3: an input whose `command` getter throws does not deny either. Pattern 1 (negative
# assertion): the claim is that nothing was blocked, not that no stack trace printed.
assert_eq "O3: a throwing tool_input does not deny" "passThrough" "$(probe judge-throwing-input '')"

# O5: fail-open lands on passThrough and NEVER on allow (#2264). allow now skips the
# permission prompt, so an exception that allowed would silently remove the safety net.
# The throwing cwd getter is read after parse succeeds, i.e. inside the catch's reach on a
# command that would otherwise be a self-script allow candidate.
for o5_mode in judge-null-command judge-throwing-input; do
    assert_not_contains "O5/$o5_mode: a fail-open verdict is never allow" "allow" "$(probe "$o5_mode" '')"
done
o5_cwd="$(probe judge-throwing-cwd 'node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list')"
assert_eq "O5/throwing-cwd: an exception reading cwd falls to passThrough, not allow" \
    "passThrough" "$o5_cwd"

# O4: fail-open is a FALLBACK, not the resting state -- a well-formed compound command on the
# same path still denies. Without this row O1-O3 would pass against a guard that allows all.
assert_eq "O4: a parseable compound command still denies (fail-open is not blanket allow)" \
    "deny" "$(verdict_of 'echo one; echo two')"

# SKIPPED: forcing parse() itself to throw from inside judge() to exercise the outer catch.
# Because: parse() is required directly, so there is no seam to inject a fault through at
#          this layer without editing the module under test.
# L3 gap: a real crash inside the hook process -- covered indirectly by
#          cases-runtime-pretooluse.sh, which asserts the hook exits 0 and emits no block.

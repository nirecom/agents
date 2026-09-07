# tests/feature-2134-bash-guard/cases-hit-scope.sh
# Tests: hooks/bash-guard/detect.js, hooks/bash-guard/exemptions.js, hooks/bash-guard/judge.js
# Tags: hook, bash-guard, exemptions, hit-scope, classifier, scope:issue-specific, pwsh-not-required, TL2
# H1-H4: hits are per-occurrence, never a blanket boolean. Sourced by the dispatcher.

# THE DEFECT THIS PINS (codex round 1, C1). An earlier shape asked "is this a single
# command?" and, when the answer was yes, dropped every hit. `echo $(date)`, a backtick
# capture and `A=1 cmd` are all single commands, so all three walked straight through the
# guard. The cure is structural: detect() returns an ARRAY OF HITS with positions, and an
# exemption may remove only the hits it names. There is no single-command predicate to
# regress to -- H3 asserts none was reintroduced.

h1_hit_scope() {
    local name cmd want_verdict want_ids got
    while IFS='~' read -r name cmd want_verdict want_ids; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want_verdict="${want_verdict//[[:space:]]/}"
        want_ids="${want_ids//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_of "$cmd")"
        assert_eq "H1/$name: verdict" "$want_verdict" "$got"

        got="$(probe hit-ids "$cmd")"
        assert_eq "H1/$name: exact surviving hit-id set (sorted)" "$want_ids" "$got"
    done <<'TABLE'
subst-only     ~ echo $(date)          ~ deny  ~ cmd-subst
backtick-only  ~ echo `date`           ~ deny  ~ backtick
env-only       ~ A=1 cmd               ~ deny  ~ env-prefix
two-hits       ~ echo $(date) > out    ~ deny  ~ cmd-subst,redirect-out
no-hits        ~ ls -la                ~ allow ~
TABLE
}

h1_hit_scope

# H2: a hit-scoped exemption removes ONLY the literal ids it excuses. The injected dummy
# excuses `pipe` and nothing else, so the redirect beside it must survive untouched.
h2_ids="$(probe dummy-exemption 'echo a | tee x > out.log')"
assert_eq "H2: a hit-scoped exemption excusing only 'pipe' leaves the redirect hit standing" \
    "redirect-out" "$h2_ids"

# H3: no blanket single-command predicate anywhere under hooks/bash-guard/.
BG_DIR="$AGENTS_DIR/hooks/bash-guard"
if [ -d "$BG_DIR" ]; then
    h3_got="$(grep -rl "isSingleCommand" "$BG_DIR" 2>/dev/null | wc -l | tr -d ' ')"
else
    h3_got="<MISSING:hooks/bash-guard/>"
fi
assert_eq "H3: no isSingleCommand predicate exists (it re-creates the round-1 all-clear defect)" \
    "0" "$h3_got"

# H4: exactly two exemptions exist, with their scopes -- an unnamed or unscoped third
# exemption is how a guard quietly stops guarding.
assert_eq "H4: the exemption registry holds exactly the two approved members with their scopes" \
    "allow-rule-match:command,xargs-pipe:hit" "$(probe exemption-ids '')"

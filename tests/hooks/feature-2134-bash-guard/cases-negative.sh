# tests/feature-2134-bash-guard/cases-negative.sh
# Tests: hooks/bash-guard/detect.js, hooks/bash-guard/judge.js, hooks/lib/command-ir.js
# Tags: hook, bash-guard, false-positive, quoting, escaping, scope:issue-specific, pwsh-not-required, TL2
# N1-N3: characters that LOOK forbidden but are not operators. Sourced by the dispatcher.

# WHY THESE ARE NON-HITS, NOT EXEMPTIONS. detect() reads the IR, so a quoted or escaped
# metacharacter never becomes a separator in the first place and no hit is ever created.
# Writing them as exemptions instead would put a carve-out where the parser already gives the
# right answer -- and would hide a real regression the day the parser stops quoting properly.
# `\;` and `{}` in the find row are the exact shapes round 1 wanted to special-case.

n1_non_hits() {
    local name cmd got
    while IFS='~' read -r name cmd; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_of "$cmd")"
        assert_eq "N1/$name: not denied" "allow" "$got"

        got="$(probe hit-ids "$cmd")"
        assert_eq "N1/$name: no hit was ever created (non-hit, not an exemption)" "" "$got"
    done <<'TABLE'
plain-single    ~ git log --oneline -5
find-exec       ~ find . -name '*.tmp' -exec rm {} \;
quoted-semi     ~ grep 'a;b' file.txt
quoted-pipe     ~ cat "my|file.txt"
semi-in-path    ~ cat '/tmp/weird;dir/file.txt'
quoted-sentinel ~ echo "<<WORKFLOW_RESET_FROM_detail: reason>>"
arith-expansion ~ echo $((1+2))
fd-dup          ~ ls 2>&1
fd-close        ~ ls 2>&-
bare-assignment ~ A=1
TABLE
}

# The last four rows are near-misses on the SHAPE of a literal: `$((` is arithmetic, `2>&1`
# and `2>&-` move a descriptor instead of writing a file, and a bare `A=1` prefixes nothing.
n1_non_hits

# N2: the sanctioned `bash -c '... && ...'` form used across skills/_shared. The `&&` sits
# inside single quotes, so it is not a separator -- if this ever denies, roughly eight prompt
# assets stop working and the workflow blocks itself the way #2120 did.
assert_eq "N2: an && inside single quotes is not a separator" \
    "allow" "$(verdict_of "bash -c 'cd \"\$AGENTS_CONFIG_DIR\" && bash \"\$AGENTS_CONFIG_DIR/bin/confirm-off\" RUN_TL4 on'")"

# N3: an escaped separator in unquoted context. The pre-#2121 lexer mis-split this, which is
# why the new parser is a prerequisite for the guard rather than an independent change.
assert_eq "N3: an escaped && is not a separator" "allow" "$(verdict_of 'echo a \&\& b')"

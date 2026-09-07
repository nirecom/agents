# tests/feature-2134-bash-guard/cases-xargs-pipe.sh
# Tests: hooks/bash-guard/exemptions.js, hooks/bash-guard/detect.js, hooks/lib/command-ir.js
# Tags: hook, bash-guard, exemptions, xargs, separator-links, scope:issue-specific, pwsh-not-required, TL2
# X1-X7: the one hit-scoped exemption. Sourced by tests/feature-2134-bash-guard.sh.

# WHY THIS EXEMPTION EXISTS. intent.md's approved Scope excludes "via xargs", so
# `find . -name '*.tmp' | xargs rm` must not be denied. Round 1 implemented that as a
# whole-command all-clear, which also forgave every other literal on the line; the correction
# is a HIT-scoped exemption that removes exactly the `|` immediately left of xargs. Rows b-d
# are the proof that the narrowing holds: a redirect, a non-xargs pipe and a chain survive.

x1_xargs_pipe() {
    local name cmd want_verdict want_ids got
    while IFS='~' read -r name cmd want_verdict want_ids; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want_verdict="${want_verdict//[[:space:]]/}"
        want_ids="${want_ids//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_of "$cmd")"
        assert_eq "X1/$name: verdict" "$want_verdict" "$got"

        got="$(probe hit-ids "$cmd")"
        assert_eq "X1/$name: exact surviving hit-id set (sorted)" "$want_ids" "$got"
    done <<'TABLE'
a-plain-xargs   ~ find . -name '*.tmp' | xargs rm           ~ allow ~
b-with-redirect ~ find . -name '*.tmp' | xargs rm > out.log ~ deny  ~ redirect-out
c-second-pipe   ~ ls | grep x | xargs rm                    ~ deny  ~ pipe
d-with-chain    ~ echo a | xargs -0 rm && ls                ~ deny  ~ chain-and
e-abs-path      ~ find . -type f | /usr/bin/xargs rm        ~ allow ~
TABLE
}

x1_xargs_pipe

# X6: in `ls | grep x | xargs rm` the SURVIVING hit is the FIRST pipe (right side `grep`),
# not merely "some pipe". The expected index is read from separatorLinks, so the assertion
# stays true whatever numbering the IR uses -- what it pins is WHICH pipe survived.
x6_cmd='ls | grep x | xargs rm'
x6_links="$(probe links "$x6_cmd")"
x6_first="$(printf '%s' "$x6_links" | tr ',' '\n' | awk -F: '$2=="|"{print $1; exit}')"
assert_eq "X6: the pipe left of a non-xargs command is the hit that survives" \
    "pipe@separator:${x6_first}" "$(probe hits "$x6_cmd")"

# X7: position linkage, not index arithmetic. `& git.exe status` and `git pull &` each yield
# one segment and one separator, so `segments[i+1]` cannot tell them apart; only
# separatorLinks knows which side is empty. A regression to index arithmetic fails here, and
# the xargs exemption silently forgives the wrong pipe.
assert_eq "X7a: a LEADING separator links to a right segment and a null left segment" \
    "0:&:-:0" "$(probe links '& git.exe status')"
assert_eq "X7b: a TRAILING separator links to a left segment and a null right segment" \
    "0:&:0:-" "$(probe links 'git pull &')"

# SKIPPED: proving that `... | xargs -I{} sh -c '...'` cannot be used to smuggle a compound
#          command past the guard.
# Because: the escape is inherent to the approved "via xargs" carve-out -- xargs may run any
#          command, so no assertion at this layer can close it without revoking the carve-out.
# L3 gap: only a live session would show how often the shape is actually issued; detail.md
#          records it as an accepted residual risk under "xargs-pipe escape route".

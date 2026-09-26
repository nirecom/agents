# tests/feature-2134-bash-guard/cases-allow-direction.sh
# Tests: hooks/bash-guard/detect.js, hooks/bash-guard/judge.js, hooks/bash-guard/forbidden-literals.js
# Tags: hook, bash-guard, classifier, false-positive, scope:issue-specific, pwsh-not-required, TL2
# A1: the sanctioned-input half of the classifier. Sourced by tests/feature-2134-bash-guard.sh.

# CPR-ORTH counterpart of cases-detect.sh (protection-fix-tests.md Pattern 4, origin #1425):
# a guard that only ever proves it BLOCKS ships over-blocking. Every literal id gets a
# sanctioned form here -- the plain command, or the same characters neutralised by single
# quotes. Since #2264 an unremarkable command is passThrough (no output, the host decides),
# not allow: allow is reserved for this repo's own scripts (cases-allow-self-script.sh).

a1_sanctioned_forms() {
    local name cmd want got
    while IFS='~' read -r name cmd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_of "$cmd")"
        assert_eq "A1/$name: sanctioned form is NOT blocked" "$want" "$got"

        got="$(probe hit-ids "$cmd")"
        assert_eq "A1/$name: sanctioned form leaves no surviving hit" "" "$got"
    done <<'TABLE'
chain-and-pair       ~ git status                                   ~ passThrough
chain-semicolon-pair ~ ls -la                                       ~ passThrough
pipe-pair            ~ grep -n foo file.txt                         ~ passThrough
backtick-pair        ~ echo '`date`'                                ~ passThrough
cmd-subst-pair       ~ echo '$(date)'                               ~ passThrough
brace-group-pair     ~ echo '{ ls; }'                               ~ passThrough
heredoc-pair         ~ echo "<<WORKFLOW_MARK_STEP_x_complete>>"     ~ passThrough
heredoc-quoted-pair  ~ echo '<<EOF'                                 ~ passThrough
redirect-out-pair    ~ echo hi                                      ~ passThrough
redirect-append-pair ~ echo 'hi >> out.txt'                         ~ passThrough
env-prefix-pair      ~ bash /tmp/scratch/probe.sh                   ~ passThrough
workflow-tool        ~ node bin/workflow/next-step --list           ~ passThrough
git-c-form           ~ git -C /tmp/x status                         ~ passThrough
TABLE
}

# heredoc-pair uses a STRICT sentinel: a malformed one (`_x` with no status) would now be a
# notify (cases-notify-sentinel.sh). workflow-tool is a relative self-script with no cwd in
# the payload, which bash-guard must not resolve against process.cwd() -- so no allow.

a1_sanctioned_forms

# A2: a passed-through command carries no literal id -- nothing was detected and then forgiven.
a2_line="$(probe judge "ls -la")"
assert_eq "A2: a no-hit command reports passThrough with the NO_HIT code and no literal" \
    "passThrough	BG-NO-HIT	-" "$a2_line"
assert_not_contains "A2: a no-hit verdict does not name a forbidden literal" "redirect" "$a2_line"

# A3: argument count is not the axis -- rules/shell-commands.md exempts "one standalone
# command with its own flags and arguments", however many of them there are.
assert_eq "A3: a long single command with many flags is not blocked" \
    "passThrough" "$(verdict_of 'grep -rn --include=*.js --color=never needle /tmp/haystack')"

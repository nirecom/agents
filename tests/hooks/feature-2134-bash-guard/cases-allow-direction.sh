# tests/feature-2134-bash-guard/cases-allow-direction.sh
# Tests: hooks/bash-guard/detect.js, hooks/bash-guard/judge.js, hooks/bash-guard/forbidden-literals.js
# Tags: hook, bash-guard, classifier, false-positive, scope:issue-specific, pwsh-not-required, TL2
# A1: the sanctioned-input half of the classifier. Sourced by tests/feature-2134-bash-guard.sh.

# CPR-ORTH counterpart of cases-detect.sh (protection-fix-tests.md Pattern 4, origin #1425):
# a guard that only ever proves it BLOCKS ships over-blocking. Every literal id gets a
# sanctioned form here -- the plain command, or the same characters neutralised by single
# quotes. The fixture home's permissions.allow is EMPTY, so an allow here can only come from
# detect() finding zero hits, never from the allow-rule exemption doing the work.

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
chain-and-pair       ~ git status                          ~ allow
chain-semicolon-pair ~ ls -la                              ~ allow
pipe-pair            ~ grep -n foo file.txt                ~ allow
backtick-pair        ~ echo '`date`'                       ~ allow
cmd-subst-pair       ~ echo '$(date)'                      ~ allow
brace-group-pair     ~ echo '{ ls; }'                      ~ allow
heredoc-pair         ~ echo "<<WORKFLOW_MARK_STEP_x>>"     ~ allow
heredoc-quoted-pair  ~ echo '<<EOF'                         ~ allow
redirect-out-pair    ~ echo hi                             ~ allow
redirect-append-pair ~ echo 'hi >> out.txt'                ~ allow
env-prefix-pair      ~ bash /tmp/scratch/probe.sh          ~ allow
workflow-tool        ~ node bin/workflow/next-step --list  ~ allow
git-c-form           ~ git -C /tmp/x status                ~ allow
TABLE
}

a1_sanctioned_forms

# A2: an allowed command carries no literal id -- nothing was detected and then forgiven.
a2_line="$(probe judge "ls -la")"
assert_contains "A2: an allow verdict reports no offending literal" "allow" "$a2_line"
assert_not_contains "A2: an allow verdict does not name a forbidden literal" "redirect" "$a2_line"

# A3: argument count is not the axis -- rules/shell-commands.md exempts "one standalone
# command with its own flags and arguments", however many of them there are.
assert_eq "A3: a long single command with many flags stays allowed" \
    "allow" "$(verdict_of 'grep -rn --include=*.js --color=never needle /tmp/haystack')"

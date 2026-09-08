# tests/prompt-bash-node-calling-convention/legacy-p2p3-coverage.sh
# Tests: hooks/bash-guard/judge.js, skills, skills/_shared
# Tags: prompt, permissions, calling-convention, ssot, scope:common, pwsh-not-required, TL2
# T58-T59: the two risk classes tests/feature-2132-prompt-issuance.sh covered and #2262 deleted
# along with it. T58 is its P2 -- the REAL permission judge rather than the heuristic sweep next
# door. T59 is its P3 -- the ask-inducing command FORMS anywhere under skills/, which a
# per-SSOT-entry sweep cannot see because they name no SSOT entry at all. Sourced by the
# dispatcher, which owns PASS/FAIL/ROWS and assert_eq.

JP_PROBE_REL="tests/prompt-bash-node-calling-convention/judge-verdict-probe.js"
JP_PROBE="$AGENTS_DIR/$JP_PROBE_REL"

# T58 -- WHAT THE SWEEP CANNOT ANSWER. The sweep reads prompt text and judges the token in
# execution position; it never asks whether the WHOLE command line a fixed site now instructs
# survives hooks/bash-guard/judge.js. These are the real literals from #2262's fixed sites, one
# per distinct SSOT entry the issue touched, with `<PLACEHOLDER>` operands resolved the way the
# model resolves them (an angle-bracket placeholder is not text anyone ever issues, and `>`
# would be judged as a redirect).
jp_command() { # <key> -> the command literal
    case "$1" in
        detect-non-github-stage)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/bin/detect-non-github.sh" "issue-close-stage" || exit 0' ;;
        detect-non-github-commit)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/bin/detect-non-github.sh" "Phase 1 pre-flight" || NON_GITHUB=1' ;;
        concern-ledger)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/bin/concern-ledger" check-finalized --plans-dir /tmp/plans --session-id s-1 --format detail-plan' ;;
        assemble-mandatory)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind outline "$PLANS_DIR/$SESSION_ID-outline.md" "$PLANS_DIR/$SESSION_ID-detail.md" "$PLANS_DIR/$SESSION_ID-detail.md"' ;;
        check-issues-class-coverage)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/bin/check-issues-class-coverage" --mode detail "$PLANS_DIR/$SESSION_ID-detail.md"' ;;
        detect-scope-change)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/skills/make-detail-plan/scripts/detect-scope-change.sh" "$PLANS_DIR/$SESSION_ID-outline.md" "$PLANS_DIR/$SESSION_ID-detail.md"' ;;
        resolve-worktree-path)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/bin/resolve-worktree-path"' ;;
        select-staged-files)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/skills/review-tests/scripts/select-staged-files.sh"' ;;
        control-chain)
            printf '%s' 'bash "$AGENTS_CONFIG_DIR/bin/resolve-worktree-path" && echo done' ;;
        *)  printf 'UNKNOWN-COMMAND-KEY' ;;
    esac
}

jp_verdict() { # <command> -> allow | deny | <sentinel>
    [ -f "$JP_PROBE" ] || { printf '<MISSING:%s>' "$JP_PROBE_REL"; return; }
    run_with_timeout 30 node "$JP_PROBE" "$(node_path "$AGENTS_DIR")" "$1" 2>&1
}

t58_judge_table() {
    local key id want label
    while IFS='|' read -r key id want label; do
        [ -n "$key" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "$id: $label" "$want" "$(jp_verdict "$(jp_command "$key")")"
    done <<'T58_CASES'
detect-non-github-stage|T58[allow:detect-non-github.sh/stage]|allow|the converted issue-close-stage call is judged allow by the real guard, its trailing OR-recovery clause included -- the discipline document lists the AND chain and not the OR one, so the clause the prompt actually carries is not what makes a site ask
detect-non-github-commit|T58[allow:detect-non-github.sh/commit-push]|allow|CPR-ORTH: the sibling call in commit-push, whose recovery clause assigns instead of exiting, is judged allow too
concern-ledger|T58[allow:concern-ledger]|allow|the check-finalized call three skills share is judged allow with its four flag operands
assemble-mandatory|T58[allow:assemble-mandatory.sh]|allow|and so is the assembly call, whose three operands are unexpanded $PLANS_DIR/$SESSION_ID variables rather than literal paths
check-issues-class-coverage|T58[allow:check-issues-class-coverage]|allow|the class-coverage gate is judged allow
detect-scope-change|T58[allow:detect-scope-change.sh]|allow|the scope-change gate is judged allow
resolve-worktree-path|T58[allow:resolve-worktree-path]|allow|the argument-less RT-0 call, the shortest converted form there is, is judged allow
select-staged-files|T58[allow:select-staged-files.sh]|allow|as is the other argument-less one, so the verdict is not a property of one lucky command
control-chain|T58[control-deny]|deny|ATTRIBUTABILITY CONTROL: the SAME converted call with && echo done appended comes back deny through the same probe -- without this row a judge reached through a wrong envelope, or a settings file granting everything, would score all eight rows above allow for the wrong reason
T58_CASES
}

# T59 -- THE RESIDUAL FORMS. Independent of the launcher sweep by construction: these shapes
# induce a permission ask because of WHAT they are (a capture, a pipe, a substitution, an eval),
# no matter which path they name, so no per-entry scan can reach them. Recovered from #2132's P3
# together with its positive-control design -- a regex that typo'd dead, or a skills/ tree that
# stopped existing, would otherwise satisfy every zero-hit row below.
P3_CONTROL=""

p3_setup() {
    P3_CONTROL="$TMPROOT/p3-control"
    mkdir -p "$P3_CONTROL"
    printf '%s\n' '# fx positive control: one line per swept form' '' \
        'Capture: `WORKTREE=$(bin/resolve-worktree-path)`' \
        'Pipe: `git log --oneline | tail -5`' \
        'Substitution: `git -C $(pwd) status`' \
        'Eval: eval "$(setup-env)"' \
        > "$P3_CONTROL/p3-positive-control.md"
}

p3_pattern_scan() { # <key> <dir> -> hit count
    case "$1" in
        capture)  grep -rnE '`[A-Z_]+=\$\(' "$2" --include='*.md' | wc -l | tr -d ' ' ;;
        pipe)     grep -rnE '`[^`]*\| *(tail|cut|tr|head) ' "$2" --include='*.md' | wc -l | tr -d ' ' ;;
        argsubst) grep -rnE '`[^`]*\$\((pwd|git rev-parse)' "$2" --include='*.md' | wc -l | tr -d ' ' ;;
        evalboot) grep -rnF 'eval "$(' "$2" --include='*.md' | wc -l | tr -d ' ' ;;
        *)        printf 'UNKNOWN-PATTERN' ;;
    esac
}

p3_live() { # <count> -> live | DEAD:<count> | NOT-A-NUMBER:<value>
    case "$1" in ''|*[!0-9]*) printf 'NOT-A-NUMBER:%s' "$1"; return ;; esac
    [ "$1" -ge 1 ] && { printf 'live'; return; }
    printf 'DEAD:%s' "$1"
}

p3_probe() { # <key> <control|skills> -> live-verdict | hit count
    case "$2" in
        control) p3_live "$(p3_pattern_scan "$1" "$P3_CONTROL")" ;;
        skills)  p3_pattern_scan "$1" "$AGENTS_DIR/skills" ;;
        *)       printf 'UNKNOWN-TARGET' ;;
    esac
}

t59_residual_table() {
    local key target id want label
    while IFS='|' read -r key target id want label; do
        [ -n "$key" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "$id: $label" "$want" "$(p3_probe "$key" "$target")"
    done <<'T59_CASES'
capture|control|T59[control:capture]|live|POSITIVE CONTROL: the capture-into-variable pattern really matches a line built to carry it
capture|skills|T59[residual:capture]|0|and no VAR=$(...) capture remains in any code span under skills/ -- the form that makes the Bash tool ask no matter what it wraps
pipe|control|T59[control:pipe]|live|POSITIVE CONTROL: the pipe-extraction pattern is live
pipe|skills|T59[residual:pipe]|0|and no pipe-into-tail/cut/tr/head post-processing chain remains under skills/
argsubst|control|T59[control:argsubst]|live|POSITIVE CONTROL: the inline argument-substitution pattern is live
argsubst|skills|T59[residual:argsubst]|0|and no $(pwd) / $(git rev-parse ...) operand remains under skills/
evalboot|control|T59[control:evalboot]|live|POSITIVE CONTROL: the eval-bootstrap pattern is live
evalboot|skills|T59[residual:evalboot]|0|and no eval "$(...)" bootstrap remains under skills/ -- the extreme case, where the command line is not even readable before it runs
T59_CASES
}

p3_setup
t58_judge_table
t59_residual_table

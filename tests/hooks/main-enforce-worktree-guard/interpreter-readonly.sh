# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, shell, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-enforce-worktree-push-fix-interp.sh (all cases).
# Cases: the `Fix 2: …` allow/block family below.
# isReadOnlyInterpreterC(cmd): `bash -c` / `pwsh -Command` is allowed only when the
# outer command has no shell chaining AND every inner segment classifies read-only;
# anything unparseable fails closed. Repo resolution: orphan-cwd-fail-closed.sh.

# Args: expect(allow|block) fixture-name command pass-label fail-label. The labels
# are case identifiers, verbatim per origin; two block cases fail on current HEAD.
ir_run_case() {
    local expect="$1" name="$2" cmd="$3" pass_label="$4" fail_label="$5"
    local repo; repo="$(setup_main_checkout "$name")"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if [ "$expect" = "allow" ]; then
        if guard_decision "$out"; then pass "$pass_label"; else fail "$fail_label ($out)"; fi
    else
        if guard_decision "$out"; then fail "$fail_label ($out)"; else pass "$pass_label"; fi
    fi
}

echo "=== Fix 2: isReadOnlyInterpreterC ==="

# --- ALLOW: read-only inner body ---
# The `&&`/`||` here sit INSIDE single quotes, so stripQuotedArgs removes them
# and the outer-chaining check sees nothing; every inner segment is read-only.
ir_run_case allow "interp-cd-read" "bash -c 'cd \"/tmp\" && git status && echo OK || echo FAIL'" \
    "Fix 2: bash -c with read-only inner body (cd && git status && echo) allows" \
    "Fix 2: bash -c with read-only inner body should allow"
ir_run_case allow "interp-ls-pwd" "bash -c \"ls && pwd\"" \
    "Fix 2: bash -c \"ls && pwd\" allows" \
    "Fix 2: bash -c \"ls && pwd\" should allow"
ir_run_case allow "interp-pwsh-gci" "pwsh -Command 'Get-ChildItem'" \
    "Fix 2: pwsh -Command 'Get-ChildItem' allows" \
    "Fix 2: pwsh -Command 'Get-ChildItem' should allow"
ir_run_case allow "interp-ps-gc" "powershell -Command 'Get-Content x.txt'" \
    "Fix 2: powershell -Command 'Get-Content x.txt' allows" \
    "Fix 2: powershell -Command 'Get-Content x.txt' should allow"

# --- BLOCK: write body, outer chaining, or an unreadable body ---
ir_run_case block "interp-rm" "bash -c 'rm -rf /tmp/foo'" \
    "Fix 2: bash -c 'rm -rf ...' blocks" \
    "Fix 2: bash -c 'rm -rf ...' should block"
# The `&& rm` is outside the quotes, so hasShellChaining sees it.
ir_run_case block "interp-outer" "bash -c 'echo hi' && rm file" \
    "Fix 2: outer chaining (bash -c ... && rm) blocks" \
    "Fix 2: bash -c '...' && rm should block (outer chaining)"
ir_run_case block "interp-unquoted" "bash -c ls" \
    "Fix 2: bash -c ls (unquoted body) blocks (fail-closed)" \
    "Fix 2: bash -c <unquoted body> should fail-closed"
ir_run_case block "interp-unq-multi" "bash -c echo hello" \
    "Fix 2: bash -c echo hello blocks (fail-closed)" \
    "Fix 2: bash -c echo hello (unquoted multi-token) should block"
ir_run_case block "interp-ansic" "bash -c \$'echo hi'" \
    "Fix 2: bash -c \$'…' (ANSI-C) blocks (fail-closed)" \
    "Fix 2: bash -c \$'…' (ANSI-C) should block"
# A here-string is not a -c invocation at all; the here-string write pattern
# is what blocks it.
ir_run_case block "interp-herestr" "bash <<< 'echo hi'" \
    "Fix 2: bash <<< '...' blocks (here-string write pattern)" \
    "Fix 2: bash <<< '...' (here-string) should block"
ir_run_case block "interp-pwsh-rm" "pwsh -Command \"Remove-Item foo\"" \
    "Fix 2: pwsh -Command 'Remove-Item …' blocks" \
    "Fix 2: pwsh -Command 'Remove-Item …' should block"

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "interpreter-readonly.sh"

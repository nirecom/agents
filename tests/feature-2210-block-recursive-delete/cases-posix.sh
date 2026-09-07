# tests/feature-2210-block-recursive-delete/cases-posix.sh  (lang-check: ignore)
# Tests: hooks/block-recursive-delete.js, hooks/lib/bash-write-targets/rm.js
# Tags: scope:issue-specific, recursive-delete, hook, posix, rm, TL2, pwsh-not-required
#
# POSIX `rm` positives, including the forms the deleted settings.json deny globs
# covered — this hook is their only coverage. TL3 gap: text-only, no real shell.

run_posix_cases() {
    echo ""
    echo "=== POSIX rm — recursive forms must block ==="

    expect_block_cmd "rm -r dir (short form, no -f)" "rm -r dir"
    expect_block_cmd "rm -r -f dir (split flags)" "rm -r -f dir"
    expect_block_cmd "rm -Rf dir (uppercase R cluster)" "rm -Rf dir"
    expect_block_cmd "rm -fR dir (reversed cluster)" "rm -fR dir"
    expect_block_cmd "rm --recursive dir (long form)" "rm --recursive dir"
    expect_block_cmd "rm -rf/tmp/x (attached target, no space)" "rm -rf/tmp/x"
    expect_block_cmd "rm -rf dir (former deny glob)" "rm -rf dir"
    expect_block_cmd "rm -fr dir (former deny glob)" "rm -fr dir"
    expect_block_cmd "rm -rf ./build (relative target)" "rm -rf ./build"
    expect_block_cmd "/bin/rm -rf dir (absolute path to rm)" "/bin/rm -rf dir"
    expect_block_cmd "env rm -rf dir (env wrapper)" "env rm -rf dir"
    expect_block_cmd "rm -f -r dir (split flags, -f before -r)" "rm -f -r dir"

    echo ""
    echo "=== POSIX rm — concealed forms must block ==="

    expect_block_cmd "FLAGS=-rf; rm \$FLAGS x (env-prefix variable flag)" \
        'FLAGS=-rf; rm $FLAGS x'
    expect_block_cmd "bash -c 'rm -rf x' (interpreter wrapper)" \
        "bash -c 'rm -rf x'"
    expect_block_cmd "zsh -c 'rm -rf x' (interpreter wrapper, C7)" \
        "zsh -c 'rm -rf x'"
    expect_block_cmd "dash -c 'rm -r x' (interpreter wrapper, C7)" \
        "dash -c 'rm -r x'"
    expect_block_cmd "ksh -c 'rm -rf x' (interpreter wrapper, C7)" \
        "ksh -c 'rm -rf x'"
    expect_block_cmd "echo \"\$(rm -rf x)\" (quoted command substitution)" \
        'echo "$(rm -rf x)"'
    expect_block_cmd "echo done; rm -r dir (second statement)" \
        "echo done; rm -r dir"
    expect_block_cmd "true && rm -rf dir (conditional chain)" \
        "true && rm -rf dir"
    expect_block_cmd "heredoc terminator followed by a real rm -rf (C9)" \
        $'cat <<\'EOF\'\nrm -rf mentioned inside the body, ignored\nEOF\nrm -rf dir'

    echo ""
    echo "=== POSIX rm — unresolvable flag content folds to block (C2, hook-integration level) ==="

    # The classifier's null (unresolvable) verdict was proven only in its unit
    # test; these assert it folds to block through the whole hook pipeline.
    expect_block_cmd "rm -\$VAR dir (unresolvable -leading flag, null -> block, C2)" \
        'rm -$VAR dir'
    expect_block_cmd "rm -\$(echo r) dir (unresolvable command-substitution flag, null -> block, C2)" \
        'rm -$(echo r) dir'
    expect_block_cmd 'rm -`echo r` dir (unresolvable backtick-substitution flag, null -> block, C2)' \
        'rm -`echo r` dir'

    echo ""
    echo "=== POSIX rm — sudo, xargs, eval, timeout indirection all block (C1 fix, fail-closed contract) ==="

    # sudo, xargs and timeout are WRAPPER_SPECS entries that peel through to the
    # wrapped command; eval's argv is rejoined and rescanned as an extraScript.
    # All four were once documented as accepted gaps — they block now.
    expect_block_cmd "sudo rm -rf dir (sudo now peeled as a transparent wrapper, round-4)" \
        "sudo rm -rf dir"

    expect_block_cmd "printf 'dir\\n' | xargs rm -rf (xargs indirection now peeled, fail-closed, C1)" \
        'printf "dir\n" | xargs rm -rf'

    expect_block_cmd 'eval "rm -rf dir" (eval indirection now scanned as extraScript, fail-closed, C1)' \
        'eval "rm -rf dir"'

    expect_block_cmd "timeout 5 rm -rf dir (timeout indirection now peeled, fail-closed, C1)" \
        "timeout 5 rm -rf dir"

    echo ""
    echo "=== POSIX rm — symmetric negatives: same wrappers with a harmless payload approve (C1) ==="

    # CPR-ORTH: without a paired negative, each block above could be an over-block.
    expect_approve_cmd "printf 'dir\\n' | xargs echo (xargs indirection, harmless payload)" \
        'printf "dir\n" | xargs echo'
    expect_approve_cmd 'eval "echo hi" (eval indirection, harmless payload)' \
        'eval "echo hi"'
    expect_approve_cmd "timeout 5 echo hi (timeout indirection, harmless payload)" \
        "timeout 5 echo hi"

    echo ""
    echo "=== POSIX rm — recursive flag placed AFTER the target must still block (C4) ==="

    # Walking argv, not a fixed "verb flag target" shape, is the point.
    expect_block_cmd "rm dir -r (flag after target, C4)" "rm dir -r"
    expect_block_cmd "rm dir -rf (flag cluster after target, C4)" "rm dir -rf"

    echo ""
    echo "=== POSIX rm — blocked command's own text must not leak into hook output (C8) ==="

    # Bypasses run_hook, which discards stderr and would hide a leak via a stack
    # trace. The needle is a dummy key-shaped string, never a real credential.
    local secret_needle secret_cmd secret_combined
    secret_needle="sk-test-DUMMY1234567890ABCDEFGHIJ"
    secret_cmd="rm -rf /tmp/cache-${secret_needle}"
    secret_combined="$(printf '%s' "$(payload_cmd "$secret_cmd")" | run_with_timeout 60 node "$HOOK" 2>&1)"
    lacks "blocked command's secret-looking substring never appears in hook stdout+stderr (C8)" \
        "$secret_needle" "$secret_combined"

    echo ""
    echo "=== POSIX rm — block reason names the sanctioned route ==="

    # A blocked agent must be redirected, not left hunting for another spelling.
    local out reason
    out="$(run_hook "$(payload_cmd 'rm -rf dir')")"
    reason="$(reason_of "$out")"
    has "block reason names the sanctioned route (cleanup-orphan-dir.js)" \
        "cleanup-orphan-dir.js" "$reason"
    if [ -n "$reason" ] && [ "${#reason}" -ge 20 ]; then
        pass "block reason is a specific sentence (${#reason} chars), not a bare word"
    else
        fail "block reason is empty or suspiciously short (${#reason} chars): '$reason'"
    fi
    case "$reason" in
        *[Rr]ecursi*|*再帰*) pass "block reason explains WHY (mentions recursion), not just THAT it blocked" ;;
        *) fail "block reason never mentions recursion — reads as a generic denial: '$reason'" ;;
    esac
}

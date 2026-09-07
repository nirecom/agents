# tests/feature-2210-block-recursive-delete/cases-posix.sh  (lang-check: ignore)
# Tests: hooks/block-recursive-delete.js, hooks/lib/bash-write-targets/rm.js
# Tags: scope:issue-specific, recursive-delete, hook, posix, rm, TL2, pwsh-not-required
#
# POSIX `rm` positives: every spelling, ordering, long/short form and attached
# form of the recursive flag must block through the hook, plus the cross-segment
# env-prefix variable-flag form (round-2 C3). The forms the removed settings.json
# deny globs used to cover (`rm -rf `, `rm -fr `) are asserted here too — after
# stage 2 this hook is their ONLY remaining coverage.
# TL3 gap: text-only — no real bash/sh process runs these payloads (see dispatcher).

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

    # isRecursiveRmFlagToken(tok) returns null (fail-closed) for a `-`-leading
    # token whose content cannot be resolved statically (contains $/`/(). This
    # was only proven at the classifier unit-test level (test-recursive-delete-
    # flags.js); nothing exercised the FULL hook pipeline to confirm a null
    # per-token verdict actually folds into the hook's binary block decision.
    expect_block_cmd "rm -\$VAR dir (unresolvable -leading flag, null -> block, C2)" \
        'rm -$VAR dir'
    expect_block_cmd "rm -\$(echo r) dir (unresolvable command-substitution flag, null -> block, C2)" \
        'rm -$(echo r) dir'
    expect_block_cmd 'rm -`echo r` dir (unresolvable backtick-substitution flag, null -> block, C2)' \
        'rm -`echo r` dir'

    echo ""
    echo "=== POSIX rm — sudo, xargs, eval, timeout indirection all block (C1 fix, fail-closed contract) ==="

    # round-4: sudo was added to segment-utils.js's WRAPPER_SPECS and is
    # peeled transparently by resolveEffectiveCommand, so it now blocks.
    expect_block_cmd "sudo rm -rf dir (sudo now peeled as a transparent wrapper, round-4)" \
        "sudo rm -rf dir"

    # C1 fix: xargs is a WRAPPER_SPECS entry (segment-utils.js) that peels
    # through to the wrapped command, so its argv-embedded verb IS resolved as
    # the effective command — this is no longer an accepted gap. The stale
    # SKIPPED/Because comment that used to sit here (claiming xargs is never
    # peeled) contradicted the implementation; verified empirically that the
    # hook now returns {"decision":"block"} for this exact payload.
    expect_block_cmd "printf 'dir\\n' | xargs rm -rf (xargs indirection now peeled, fail-closed, C1)" \
        'printf "dir\n" | xargs rm -rf'

    # C1 fix: peelTransparentHeads (head-peeling.js) gives `eval` dedicated
    # handling — its argv is joined into one script and recursively scanned
    # as an extraScript, so the wrapped `rm -rf` is found. No longer an
    # accepted gap.
    expect_block_cmd 'eval "rm -rf dir" (eval indirection now scanned as extraScript, fail-closed, C1)' \
        'eval "rm -rf dir"'

    # C1 fix: timeout is a WRAPPER_SPECS entry with `positionalCount: 1` (its
    # DURATION argument), so the wrapped command after the duration IS peeled
    # and resolved as the effective command. No longer an accepted gap.
    expect_block_cmd "timeout 5 rm -rf dir (timeout indirection now peeled, fail-closed, C1)" \
        "timeout 5 rm -rf dir"

    echo ""
    echo "=== POSIX rm — symmetric negatives: same wrappers with a harmless payload approve (C1) ==="

    # CPR-ORTH: a block-side fix without a paired negative could be masking an
    # over-block regression — each wrapper above gets a harmless counterpart.
    expect_approve_cmd "printf 'dir\\n' | xargs echo (xargs indirection, harmless payload)" \
        'printf "dir\n" | xargs echo'
    expect_approve_cmd 'eval "echo hi" (eval indirection, harmless payload)' \
        'eval "echo hi"'
    expect_approve_cmd "timeout 5 echo hi (timeout indirection, harmless payload)" \
        "timeout 5 echo hi"

    echo ""
    echo "=== POSIX rm — recursive flag placed AFTER the target must still block (C4) ==="

    # Token-position-independent scanning is the whole point of walking argv
    # instead of matching a fixed "verb flag target" shape — nothing proved
    # that a flag trailing the target is still found.
    expect_block_cmd "rm dir -r (flag after target, C4)" "rm dir -r"
    expect_block_cmd "rm dir -rf (flag cluster after target, C4)" "rm dir -rf"

    echo ""
    echo "=== POSIX rm — blocked command's own text must not leak into hook output (C8) ==="

    # helpers.sh's run_hook discards stderr entirely, so a leak via a crash or
    # stack trace would be invisible there — this capture combines stdout+
    # stderr directly instead of going through run_hook, so a leak through
    # EITHER channel is caught. The needle is a dummy, non-functional
    # API-key-shaped string, never a real credential.
    local secret_needle secret_cmd secret_combined
    secret_needle="sk-test-DUMMY1234567890ABCDEFGHIJ"
    secret_cmd="rm -rf /tmp/cache-${secret_needle}"
    secret_combined="$(printf '%s' "$(payload_cmd "$secret_cmd")" | run_with_timeout 60 node "$HOOK" 2>&1)"
    lacks "blocked command's secret-looking substring never appears in hook stdout+stderr (C8)" \
        "$secret_needle" "$secret_combined"

    echo ""
    echo "=== POSIX rm — block reason names the sanctioned route ==="

    # detail.md Step 5.5: the reason must point at the one legitimate path, so a
    # blocked agent redirects instead of hunting for another spelling. Beyond
    # a bare substring match (MEDIUM): the reason must also be a real sentence
    # (not a bare word) and must explain WHY, not just THAT it blocked.
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

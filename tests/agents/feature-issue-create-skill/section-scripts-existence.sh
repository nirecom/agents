# IC-1467-1 through IC-1467-11: run-bulk-dispatch.sh and run-phase5-record.sh existence
# Static checks, one in-process case (run_case_sync) so output stays in definition order.

BULK_SCRIPT="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/run-bulk-dispatch.sh"
PHASE5_SCRIPT="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/run-phase5-record.sh"

case_ic_1467() {
    # IC-1467-1: skills/issue-create/scripts/run-bulk-dispatch.sh exists
    if [[ -f "$BULK_SCRIPT" ]]; then
        pass "IC-1467-1: run-bulk-dispatch.sh exists"
    else
        fail "IC-1467-1: run-bulk-dispatch.sh missing — RED until implementation"
    fi

    # IC-1467-2: skills/issue-create/scripts/run-bulk-dispatch.sh is executable
    if [[ -x "$BULK_SCRIPT" ]]; then
        pass "IC-1467-2: run-bulk-dispatch.sh is executable"
    else
        fail "IC-1467-2: run-bulk-dispatch.sh not executable — RED until implementation"
    fi

    # IC-1467-3: skills/issue-create/scripts/run-phase5-record.sh exists
    if [[ -f "$PHASE5_SCRIPT" ]]; then
        pass "IC-1467-3: run-phase5-record.sh exists"
    else
        fail "IC-1467-3: run-phase5-record.sh missing — RED until implementation"
    fi

    # IC-1467-4: skills/issue-create/scripts/run-phase5-record.sh is executable
    if [[ -x "$PHASE5_SCRIPT" ]]; then
        pass "IC-1467-4: run-phase5-record.sh is executable"
    else
        fail "IC-1467-4: run-phase5-record.sh not executable — RED until implementation"
    fi

    # IC-1467-5: SKILL.md delegates Phase 4 bulk-sub-of to run-bulk-dispatch.sh
    if [[ ! -f "$SKILL_MD" ]]; then
        fail "IC-1467-5: SKILL.md missing"
    elif grep -q "run-bulk-dispatch.sh" "$SKILL_MD"; then
        pass "IC-1467-5: SKILL.md delegates Phase 4 bulk-sub-of to run-bulk-dispatch.sh"
    else
        fail "IC-1467-5: SKILL.md does not reference run-bulk-dispatch.sh — RED until implementation"
    fi

    # IC-1467-6: SKILL.md delegates Phase 5 record loop to run-phase5-record.sh
    if [[ ! -f "$SKILL_MD" ]]; then
        fail "IC-1467-6: SKILL.md missing"
    elif grep -q "run-phase5-record.sh" "$SKILL_MD"; then
        pass "IC-1467-6: SKILL.md delegates Phase 5 record loop to run-phase5-record.sh"
    else
        fail "IC-1467-6: SKILL.md does not reference run-phase5-record.sh — RED until implementation"
    fi

    # IC-1467-7: run-phase5-record.sh contains worktree-notes-append.js reference
    if [[ ! -f "$PHASE5_SCRIPT" ]]; then
        fail "IC-1467-7: run-phase5-record.sh missing — RED until implementation"
    elif grep -q "worktree-notes-append.js" "$PHASE5_SCRIPT"; then
        pass "IC-1467-7: run-phase5-record.sh contains worktree-notes-append.js reference"
    else
        fail "IC-1467-7: run-phase5-record.sh does not reference worktree-notes-append.js"
    fi

    # IC-1467-8: run-phase5-record.sh contains non-fatal behavior marker
    if [[ ! -f "$PHASE5_SCRIPT" ]]; then
        fail "IC-1467-8: run-phase5-record.sh missing — RED until implementation"
    elif grep -qiE "non.fatal|non fatal|nonfatal" "$PHASE5_SCRIPT"; then
        pass "IC-1467-8: run-phase5-record.sh contains non-fatal behavior marker"
    else
        fail "IC-1467-8: run-phase5-record.sh does not contain non-fatal marker"
    fi

    # IC-1467-9: run-phase5-record.sh contains --skip-if-main flag
    if [[ ! -f "$PHASE5_SCRIPT" ]]; then
        fail "IC-1467-9: run-phase5-record.sh missing — RED until implementation"
    elif grep -q -- "--skip-if-main" "$PHASE5_SCRIPT"; then
        pass "IC-1467-9: run-phase5-record.sh contains --skip-if-main flag"
    else
        fail "IC-1467-9: run-phase5-record.sh does not contain --skip-if-main"
    fi

    # IC-1467-10: run-bulk-dispatch.sh has set -euo pipefail
    if [[ ! -f "$BULK_SCRIPT" ]]; then
        fail "IC-1467-10: run-bulk-dispatch.sh missing — RED until implementation"
    elif grep -q "set -euo pipefail" "$BULK_SCRIPT"; then
        pass "IC-1467-10: run-bulk-dispatch.sh has set -euo pipefail"
    else
        fail "IC-1467-10: run-bulk-dispatch.sh missing set -euo pipefail"
    fi

    # IC-1467-11: run-phase5-record.sh has set -euo pipefail
    if [[ ! -f "$PHASE5_SCRIPT" ]]; then
        fail "IC-1467-11: run-phase5-record.sh missing — RED until implementation"
    elif grep -q "set -euo pipefail" "$PHASE5_SCRIPT"; then
        pass "IC-1467-11: run-phase5-record.sh has set -euo pipefail"
    else
        fail "IC-1467-11: run-phase5-record.sh missing set -euo pipefail"
    fi
}
run_case_sync case_ic_1467

# IC-3013-1 through IC-3013-5 (#3013): the manifest path contract is stated in the script header and SKILL.md.
case_ic_3013() {
    local lines

    # IC-3013-1: run-bulk-dispatch.sh header Usage names manifest_path as arg 1
    if [[ -f "$BULK_SCRIPT" ]] && head -n 6 "$BULK_SCRIPT" | grep -q 'manifest_path'; then
        pass "IC-3013-1: run-bulk-dispatch.sh header Usage states manifest_path"
    else
        fail "IC-3013-1: run-bulk-dispatch.sh header Usage does not state manifest_path"
    fi

    # IC-3013-2: SKILL.md defines the -bulk-dispatch- manifest path
    if [[ -f "$SKILL_MD" ]] && grep -q -- '-bulk-dispatch-' "$SKILL_MD"; then
        pass "IC-3013-2: SKILL.md states the -bulk-dispatch- manifest path"
    else
        fail "IC-3013-2: SKILL.md does not state the -bulk-dispatch- manifest path"
    fi

    # IC-3013-3: SKILL.md passes --remove-manifest to Phase 5 and leaves no bare "<MANIFEST>"
    if [[ -f "$SKILL_MD" ]] && grep -q -- '--remove-manifest' "$SKILL_MD" && ! grep -qF '"<MANIFEST>"' "$SKILL_MD"; then
        pass "IC-3013-3: SKILL.md states --remove-manifest and no bare \"<MANIFEST>\" remains"
    else
        fail "IC-3013-3: SKILL.md lacks --remove-manifest or still carries a bare \"<MANIFEST>\""
    fi

    # IC-3013-6 (C1): the deletion policy lives on the procedure side: --remove-manifest is attached only when the
    # dispatch exits 0, and a non-zero exit / partial failure keeps the manifest for retry.
    local rm_ctx keep_line
    rm_ctx="$(grep -iE -B1 -A1 -- '--remove-manifest' "$SKILL_MD" 2>/dev/null)" || true
    keep_line="$(grep -iE 'manifest' "$SKILL_MD" 2>/dev/null | grep -iE 'non-zero|nonzero|partial|fail' | grep -iE 'retry|kept|keep|remain|not (delete|remove)|left')" || true
    if [[ -n "$rm_ctx" ]] && printf '%s\n' "$rm_ctx" | grep -qiE 'exits? (code )?0|exit (code )?0|zero exit|exited 0' \
       && [[ -n "$keep_line" ]]; then
        pass "IC-3013-6: SKILL.md attaches --remove-manifest only on exit 0 and keeps the manifest on non-zero/partial failure"
    else
        fail "IC-3013-6: SKILL.md does not tie --remove-manifest to exit 0 / does not keep the manifest on partial failure (ctx='${rm_ctx:-none}' keep='${keep_line:-none}')"
    fi

    # IC-3013-7 (C2): Phase 4 (arg 1 of run-bulk-dispatch.sh) and Phase 5 (arg 4 of run-phase5-record.sh) take the
    # identical manifest-path argument, otherwise Phase 5 reads a different file than Phase 4 wrote.
    local p4_line p5_line p4_arg="" p5_arg=""
    p4_line="$(grep -F 'run-bulk-dispatch.sh' "$SKILL_MD" 2>/dev/null | head -n 1)" || true
    p5_line="$(grep -F 'run-phase5-record.sh' "$SKILL_MD" 2>/dev/null | head -n 1)" || true
    if [[ "$p4_line" =~ run-bulk-dispatch\.sh\"[[:space:]]+(\"[^\"]*\"|[^[:space:]]+) ]]; then p4_arg="${BASH_REMATCH[1]}"; fi
    if [[ "$p5_line" =~ run-phase5-record\.sh\"[[:space:]]+(\"[^\"]*\"|[^[:space:]]+)[[:space:]]+(\"[^\"]*\"|[^[:space:]]+)[[:space:]]+(\"[^\"]*\"|[^[:space:]]+)[[:space:]]+(\"[^\"]*\"|[^[:space:]]+) ]]; then p5_arg="${BASH_REMATCH[4]}"; fi
    if [[ -n "$p4_arg" && "$p4_arg" != '""' && "$p4_arg" == "$p5_arg" && "$p4_arg" != *PLANS_DIR\" ]]; then
        pass "IC-3013-7: Phase 4 and Phase 5 calls pass the same manifest path argument ($p4_arg)"
    else
        fail "IC-3013-7: Phase 4 arg1='${p4_arg:-none}' differs from Phase 5 arg4='${p5_arg:-none}' (or is a bare plans dir)"
    fi

    # IC-3013-4: SKILL.md stays within the prompt HARD limit (200 lines)
    lines="$(wc -l <"$SKILL_MD" 2>/dev/null | tr -d ' ')" || true
    if [[ -n "$lines" ]] && [[ "$lines" -le 200 ]]; then
        pass "IC-3013-4: SKILL.md is $lines lines (<= 200)"
    else
        fail "IC-3013-4: SKILL.md is ${lines:-unknown} lines (> 200)"
    fi
}
run_case_sync case_ic_3013

# IC-3013-5: the manifest name rule is the same in both scripts. For each name, run-bulk-dispatch.sh
# accepting it (creates the manifest) must agree with run-phase5-record.sh --remove-manifest removing it.
# A conforming name must be accepted by both, so a pair of scripts that reject everything cannot pass.
case_ic_3013_symmetry() {
    local name bulk_ok bulk_rc p5_ok mismatch="" conforming_ok=0 rejected_ok=0 notes_dir M
    setup_mock
    notes_dir="$TMP/notes"; mkdir -p "$notes_dir"
    printf 'https://github.com/example/repo/issues/301\n' >"$TMP/urls"
    # Names are passed unprefixed, so the boundary name bulk-dispatch-5.tsv (no session-id part) is tested as itself.
    for name in sid-bulk-dispatch-5.tsv s1-bulk-dispatch-5.tsv s1-bulk-dispatch-5.txt manifest.tsv bulk-dispatch.tsv bulk-dispatch-5.tsv; do
        M="$TMP/$name"
        rm -f "$M"
        bulk_rc=0
        run_with_timeout 30 bash "$BULK_SCRIPT" "$M" 100 </dev/null >/dev/null 2>&1 || bulk_rc=$?
        bulk_ok=0; [[ -e "$M" ]] && bulk_ok=1
        rm -f "$M"
        printf 'Alpha\tBackground: a\\nChanges: a\n' >"$M"
        run_with_timeout 30 bash "$PHASE5_SCRIPT" bulk-sub-of "$(cygpath -m "$notes_dir" 2>/dev/null || echo "$notes_dir")/WORKTREE_NOTES.md" "Phase1 title" "$M" --input-file "$TMP/urls" --remove-manifest >/dev/null 2>&1 || true
        p5_ok=0; [[ -e "$M" ]] || p5_ok=1
        [[ "$bulk_ok" -eq "$p5_ok" ]] || mismatch="$mismatch $name(bulk=$bulk_ok,phase5=$p5_ok)"
        case "$name" in
            sid-bulk-dispatch-5.tsv|s1-bulk-dispatch-5.tsv)
                if [[ "$bulk_ok" -eq 1 && "$p5_ok" -eq 1 ]]; then conforming_ok=$((conforming_ok + 1)); fi ;;
            *)
                if [[ "$bulk_ok" -eq 0 && "$bulk_rc" -eq 2 && "$p5_ok" -eq 0 ]]; then rejected_ok=$((rejected_ok + 1)); fi ;;
        esac
    done
    if [[ -z "$mismatch" && "$conforming_ok" -eq 2 && "$rejected_ok" -eq 4 ]]; then
        pass "IC-3013-5: both scripts accept and reject the same manifest names"
    else
        fail "IC-3013-5: name rule differs or is not enforced: mismatch='$mismatch' conforming_ok=$conforming_ok rejected_ok=$rejected_ok"
    fi
    teardown_mock
}
run_case case_ic_3013_symmetry

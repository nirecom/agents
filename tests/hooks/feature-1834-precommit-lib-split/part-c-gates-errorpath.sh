# Part C (gates error-path) — the shared rc-handling template of the on-demand, session-id and
# migration gates (C1f-C1n). CPR-ORTH: all three gates share one fail-closed template (#2589) —
# rc 0 -> pass; rc 1|2 -> block; a missing/unrunnable checker or an unexpected rc -> block too
# (the bypass is `git commit --no-verify`). C1a/C1b already cover the rc=1 block; these add
# rc=2, absent and unexpected rc FOR EACH gate, via CONTROLLED checker shims.
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.

echo ""
echo "=== Part C: agents-repo gates error paths (controlled checker shims) ==="

# c1_rc2_blocks <id> <label> <block-msg> <si> <mb> [od] — rc 2 takes the 1|2 arm and blocks.
c1_rc2_blocks() {
    local id="$1" label="$2" msg="$3"
    R="$TMPBASE/$id"; mk_agents_fixture_rc "$R" "$4" "$5" "${6:-clean}"
    printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
    run_agents_gates "$R" "$R"
    if [ "$GRC" -ne 1 ]; then
        fail "$id: $label rc2" "want rc 1, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
    elif ! printf '%s' "$GOUT" | grep -qF "$msg"; then
        fail "$id: $label rc2" "output lacks the $label block message [$msg]"
    elif ! printf '%s' "$GOUT" | grep -qF 'checker rc=2'; then
        fail "$id: $label rc2" "output lacks the interpolated 'checker rc=2' string"
    else
        pass "$id: $label checker rc=2 blocks the commit (caller-contract-breach arm)"
    fi
}

# c1_failclosed <id> <label> <checker-basename> <skip-msg> <want-rc3:0|1> <si> <mb> [od] — an
# absent checker or an unexpected rc blocks: rc 1, the checker named, no fail-open skip line.
c1_failclosed() {
    local id="$1" label="$2" name="$3" skip="$4" want_rc3="$5" what
    what="$label $([ "$want_rc3" = 1 ] && echo 'rc3' || echo 'absent')"
    R="$TMPBASE/$id"; mk_agents_fixture_rc "$R" "$6" "$7" "${8:-clean}"
    printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
    run_agents_gates "$R" "$R"
    if [ "$GRC" -ne 1 ]; then
        fail "$id: $what" "want rc 1 (fail closed), got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
    elif ! printf '%s' "$GOUT" | grep -qF "$name"; then
        fail "$id: $what" "block output does not name the checker [$name]"
    elif [ "$want_rc3" = 1 ] && ! printf '%s' "$GOUT" | grep -qF 'rc=3'; then
        fail "$id: $what" "block output lacks the interpolated 'rc=3'"
    elif printf '%s' "$GOUT" | grep -qF "$skip"; then
        fail "$id: $what" "the fail-open diagnostic [$skip] still fires"
    else
        pass "$id: $what blocks the commit and names $name"
    fi
}

case_begin "C1f-session-id-rc2-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_rc2_blocks c1f session-id "$SID_MSG" rc2 clean
case_end

case_begin "C1g-session-id-absent-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_failclosed c1g session-id check-session-id-ssot "$SID_SKIP_MSG" 0 absent clean
case_end

case_begin "C1h-session-id-unexpected-rc-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_failclosed c1h session-id check-session-id-ssot "$SID_SKIP_MSG" 1 rc3 clean
case_end

case_begin "C1i-migration-rc2-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_rc2_blocks c1i migration "$MIG_MSG" clean rc2
case_end

case_begin "C1j-migration-absent-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_failclosed c1j migration check-migration-blocks "$MIG_SKIP_MSG" 0 clean absent
case_end

case_begin "C1k-migration-unexpected-rc-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_failclosed c1k migration check-migration-blocks "$MIG_SKIP_MSG" 1 clean rc3
case_end

case_begin "C1l-on-demand-rc2-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_rc2_blocks c1l on-demand "$OD_MSG" clean clean rc2
case_end

case_begin "C1m-on-demand-absent-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_failclosed c1m on-demand check-on-demand-rules "$OD_SKIP_MSG" 0 clean clean absent
case_end

case_begin "C1n-on-demand-unexpected-rc-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c1_failclosed c1n on-demand check-on-demand-rules "$OD_SKIP_MSG" 1 clean clean rc3
case_end

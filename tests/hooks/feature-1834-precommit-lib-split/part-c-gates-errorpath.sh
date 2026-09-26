# Part C (gates error-path) — the shared rc-handling template of the on-demand, session-id and
# migration gates (C1f-C1n). CPR-ORTH: all three gates share one template — [ ! -x ] -> skip
# fail-open; rc 0 -> pass; rc 1|2 -> block via exit 1; *) unexpected rc -> skip fail-open.
# C1a/C1b already cover the rc=1 block; these add rc=2 (block), non-exec/absent (fail-open)
# and unexpected rc (fail-open) FOR EACH gate, via CONTROLLED checker shims.
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.

echo ""
echo "=== Part C: agents-repo gates error paths (controlled checker shims) ==="

# C1f: session-id checker exits 2 -> the 1|2 arm BLOCKS (rc 2 is a caller-contract-breach,
# not a silent skip). Migration stays clean but is never reached (session-id exits first).
case_begin "C1f-session-id-rc2-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1f"; mk_agents_fixture_rc "$R" rc2 clean
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 1 ]; then
    fail "C1f: session-id rc2" "want rc 1, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif ! printf '%s' "$GOUT" | grep -qF "$SID_MSG"; then
    fail "C1f: session-id rc2" "output lacks the session-id block message [$SID_MSG]"
elif ! printf '%s' "$GOUT" | grep -qF 'checker rc=2'; then
    fail "C1f: session-id rc2" "output lacks the interpolated 'checker rc=2' string"
else
    pass "C1f: session-id checker rc=2 blocks the commit (caller-contract-breach arm)"
fi
case_end

# C1g: session-id checker present-but-not-executable (absent) -> FAIL OPEN. Commit left
# alone, no block message, the fail-open diagnostic names the checker + "skipped".
case_begin "C1g-session-id-nonexec-failopen" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1g"; mk_agents_fixture_rc "$R" absent clean
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1g: session-id nonexec" "want rc 0 (fail open), got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$SID_MSG"; then
    fail "C1g: session-id nonexec" "block message [$SID_MSG] fired though the checker could not run"
elif ! printf '%s' "$GOUT" | grep -qF "$SID_SKIP_MSG"; then
    fail "C1g: session-id nonexec" "output lacks the fail-open diagnostic [$SID_SKIP_MSG]"
else
    pass "C1g: an unrunnable session-id checker leaves the commit alone with a skipped diagnostic"
fi
case_end

# C1h: session-id checker exits an unexpected rc (3) -> FAIL OPEN via the *) arm. Commit
# left alone, no block message, the "rc=3 ... skipped" diagnostic present.
case_begin "C1h-session-id-unexpected-rc-failopen" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1h"; mk_agents_fixture_rc "$R" rc3 clean
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1h: session-id rc3" "want rc 0 (fail open), got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$SID_MSG"; then
    fail "C1h: session-id rc3" "block message [$SID_MSG] fired on an unexpected rc"
elif ! printf '%s' "$GOUT" | grep -qF 'rc=3'; then
    fail "C1h: session-id rc3" "output lacks the interpolated 'rc=3' diagnostic"
elif ! printf '%s' "$GOUT" | grep -qF "$SID_SKIP_MSG"; then
    fail "C1h: session-id rc3" "output lacks the fail-open diagnostic [$SID_SKIP_MSG]"
else
    pass "C1h: session-id checker unexpected rc=3 fails open with a skipped diagnostic"
fi
case_end

# C1i: migration checker exits 2 -> the 1|2 arm BLOCKS. Session-id clean so control
# REACHES the migration gate.
case_begin "C1i-migration-rc2-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1i"; mk_agents_fixture_rc "$R" clean rc2
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 1 ]; then
    fail "C1i: migration rc2" "want rc 1, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif ! printf '%s' "$GOUT" | grep -qF "$MIG_MSG"; then
    fail "C1i: migration rc2" "output lacks the migration block message [$MIG_MSG]"
elif ! printf '%s' "$GOUT" | grep -qF 'checker rc=2'; then
    fail "C1i: migration rc2" "output lacks the interpolated 'checker rc=2' string"
else
    pass "C1i: migration checker rc=2 blocks the commit (caller-contract-breach arm)"
fi
case_end

# C1j: migration checker present-but-not-executable (absent) -> FAIL OPEN. Session-id
# clean; commit left alone, no block message, the fail-open diagnostic present.
case_begin "C1j-migration-nonexec-failopen" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1j"; mk_agents_fixture_rc "$R" clean absent
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1j: migration nonexec" "want rc 0 (fail open), got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$MIG_MSG"; then
    fail "C1j: migration nonexec" "block message [$MIG_MSG] fired though the checker could not run"
elif ! printf '%s' "$GOUT" | grep -qF "$MIG_SKIP_MSG"; then
    fail "C1j: migration nonexec" "output lacks the fail-open diagnostic [$MIG_SKIP_MSG]"
else
    pass "C1j: an unrunnable migration checker leaves the commit alone with a skipped diagnostic"
fi
case_end

# C1k: migration checker exits an unexpected rc (3) -> FAIL OPEN via the *) arm.
case_begin "C1k-migration-unexpected-rc-failopen" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1k"; mk_agents_fixture_rc "$R" clean rc3
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1k: migration rc3" "want rc 0 (fail open), got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$MIG_MSG"; then
    fail "C1k: migration rc3" "block message [$MIG_MSG] fired on an unexpected rc"
elif ! printf '%s' "$GOUT" | grep -qF 'rc=3'; then
    fail "C1k: migration rc3" "output lacks the interpolated 'rc=3' diagnostic"
elif ! printf '%s' "$GOUT" | grep -qF "$MIG_SKIP_MSG"; then
    fail "C1k: migration rc3" "output lacks the fail-open diagnostic [$MIG_SKIP_MSG]"
else
    pass "C1k: migration checker unexpected rc=3 fails open with a skipped diagnostic"
fi
case_end

# C1l: on-demand checker exits 2 -> the 1|2 arm BLOCKS. on-demand runs first, so si/mb clean
# and control reaches it immediately (CPR-ORTH sibling of C1f/C1i).
case_begin "C1l-on-demand-rc2-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1l"; mk_agents_fixture_rc "$R" clean clean rc2
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 1 ]; then
    fail "C1l: on-demand rc2" "want rc 1, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif ! printf '%s' "$GOUT" | grep -qF "$OD_MSG"; then
    fail "C1l: on-demand rc2" "output lacks the on-demand block message [$OD_MSG]"
elif ! printf '%s' "$GOUT" | grep -qF 'checker rc=2'; then
    fail "C1l: on-demand rc2" "output lacks the interpolated 'checker rc=2' string"
else
    pass "C1l: on-demand checker rc=2 blocks the commit (caller-contract-breach arm)"
fi
case_end

# C1m: on-demand checker present-but-not-executable (absent) -> FAIL OPEN. Commit left alone,
# no block message, the fail-open diagnostic names the checker + skipped (CPR-ORTH sibling of C1g/C1j).
case_begin "C1m-on-demand-nonexec-failopen" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1m"; mk_agents_fixture_rc "$R" clean clean absent
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1m: on-demand nonexec" "want rc 0 (fail open), got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$OD_MSG"; then
    fail "C1m: on-demand nonexec" "block message [$OD_MSG] fired though the checker could not run"
elif ! printf '%s' "$GOUT" | grep -qF "$OD_SKIP_MSG"; then
    fail "C1m: on-demand nonexec" "output lacks the fail-open diagnostic [$OD_SKIP_MSG]"
else
    pass "C1m: an unrunnable on-demand checker leaves the commit alone with a skipped diagnostic"
fi
case_end

# C1n: on-demand checker exits an unexpected rc (3) -> FAIL OPEN via the *) arm (CPR-ORTH
# sibling of C1h/C1k — the gap Codex flagged). Commit left alone, "rc=3 ... skipped" present.
case_begin "C1n-on-demand-unexpected-rc-failopen" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1n"; mk_agents_fixture_rc "$R" clean clean rc3
printf 'x\n' > "$R/app.txt"; git -C "$R" add -- app.txt >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1n: on-demand rc3" "want rc 0 (fail open), got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$OD_MSG"; then
    fail "C1n: on-demand rc3" "block message [$OD_MSG] fired on an unexpected rc"
elif ! printf '%s' "$GOUT" | grep -qF 'rc=3'; then
    fail "C1n: on-demand rc3" "output lacks the interpolated 'rc=3' diagnostic"
elif ! printf '%s' "$GOUT" | grep -qF "$OD_SKIP_MSG"; then
    fail "C1n: on-demand rc3" "output lacks the fail-open diagnostic [$OD_SKIP_MSG]"
else
    pass "C1n: on-demand checker unexpected rc=3 fails open with a skipped diagnostic"
fi
case_end

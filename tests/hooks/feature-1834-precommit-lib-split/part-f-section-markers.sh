# Part F (#2762) — the pre-commit section marker contract, through a real `git commit`.
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh after Part E; reuses E_TEMPLATE,
# E_CHECKERS, e_stub, e_fixture and e_flat.
# hooks/pre-commit prints `pre-commit-section: <name>` on stderr at the start of each of its eleven
# sections (before the section's own guard); the agents-repo gate runner prints
# `pre-commit-section: agents-repo-gate-<checker without .sh>` before each checker. The commit-push
# worker reads only the LAST marker to say where a timed-out commit stopped, so the exact sequence
# and the stop point are the contract. The fixture is fixed, so the sequence is deterministic.

echo ""
echo "=== Part F: pre-commit section markers on stderr (#2762) ==="

F_SECTIONS=(enforce-worktree settings-effort-unstage code-lang sh-exec-bit prompt-extraction
    tests-frontmatter agents-repo-gates comment-block-size repo-visibility env-file-block outbound-scan)
F_GATES=()
for c in "${E_CHECKERS[@]}"; do F_GATES+=("agents-repo-gate-$(basename "$c" .sh)"); done
# The full sequence of a commit in the agents repo: the gate markers sit inside agents-repo-gates.
F_ALL=("${F_SECTIONS[@]:0:7}" "${F_GATES[@]}" "${F_SECTIONS[@]:7}")

# f_fixture <name> [keep-origin] — Part E's fixture plus a passing outbound-scanner stub; without
# keep-origin the non-GitHub origin is removed so the hook runs through outbound-scan.
f_fixture() {
    e_fixture "f-$1"
    [ "${2:-}" = keep-origin ] || git -C "$R" remote remove origin
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$R/bin/scan-outbound.sh"
    chmod +x "$R/bin/scan-outbound.sh"
}

# f_commit <repo> <hook-repo> — real git commit through <hook-repo>'s hooks with stdout and stderr
# kept apart; sets CRC and FMARKS (the marker names of stderr, in order, one per line).
f_commit() {
    local root
    root="$(np "$2")"
    git -C "$1" config core.hooksPath "$(np "$2/hooks")"
    CRC=0
    (cd "$1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX && export ENFORCE_WORKTREE=off \
        && export AGENTS_MAIN_ROOT="$root" && run_with_timeout 60 git commit -q -m marker \
        >"$1.out" 2>"$1.err") || CRC=$?
    FMARKS="$(grep '^pre-commit-section: ' "$1.err" | sed 's/^pre-commit-section: //')"
}

# f_expect <label> <names...> — FMARKS must be exactly <names>, in order, with nothing else.
f_expect() {
    local label="$1" want; shift
    want="$(printf '%s\n' "$@")"
    if [ "$FMARKS" = "$want" ]; then
        pass "$label"
    else
        fail "$label" "want: $(e_flat "$want") got: $(e_flat "$FMARKS")"
    fi
}

case_begin "F1-agents-repo-commit-prints-the-exact-marker-sequence" "hooks/pre-commit"
f_fixture clean
f_commit "$R" "$R"
if [ "$CRC" -eq 0 ]; then
    pass "F1: clean commit through the hook copy"
else
    fail "F1: clean commit through the hook copy" "rc=$CRC err: $(e_flat "$(cat "$R.err")")"
fi
f_expect "F1: the eleven section markers, with the six gate markers inside agents-repo-gates, exactly once each" "${F_ALL[@]}"
if grep -q 'pre-commit-section' "$R.out"; then
    fail "F1: markers go to stderr only" "stdout: $(e_flat "$(cat "$R.out")")"
else
    pass "F1: markers go to stderr only"
fi
bad="$(grep 'pre-commit-section' "$R.err" | grep -vE '^pre-commit-section: [a-z0-9][a-z0-9-]*$' || true)"
if [ -z "$bad" ] && [ -n "$FMARKS" ]; then
    pass "F1: every marker line is exactly 'pre-commit-section: <[a-z0-9][a-z0-9-]*>'"
else
    fail "F1: marker line format" "bad lines: $(e_flat "$bad") markers: $(e_flat "$FMARKS")"
fi
case_end

case_begin "F2-foreign-repo-prints-no-gate-markers" "hooks/lib/precommit-agents-repo-gates.sh"
H="$R"
F="$TMPBASE/f-foreign"
init_repo_bare "$F"
git -C "$F" commit -q --allow-empty -m seed >/dev/null 2>&1
printf 'x\n' > "$F/app.txt"
git -C "$F" add -- app.txt >/dev/null 2>&1
f_commit "$F" "$H"
[ "$CRC" -eq 0 ] || fail "F2: foreign commit through the hook copy" "rc=$CRC err: $(e_flat "$(cat "$F.err")")"
f_expect "F2: a foreign repo prints exactly the eleven section markers and no agents-repo-gate marker" "${F_SECTIONS[@]}"
case_end

case_begin "F3-last-marker-names-where-the-hook-stopped" "hooks/pre-commit"
# A non-GitHub origin ends the hook at repo-visibility: no later section starts.
f_fixture visibility keep-origin
f_commit "$R" "$R"
[ "$CRC" -eq 0 ] || fail "F3: early-exit commit" "rc=$CRC err: $(e_flat "$(cat "$R.err")")"
f_expect "F3: an early exit at repo-visibility ends the sequence at repo-visibility" "${F_ALL[@]:0:15}"
# A blocking checker (the last one called): the sequence ends with its gate marker.
f_fixture blocked
e_stub "$R" "${E_CHECKERS[5]}" 1
f_commit "$R" "$R"
[ "$CRC" -ne 0 ] || fail "F3: blocked commit is rejected" "rc=0"
f_expect "F3: a commit blocked by ${E_CHECKERS[5]} ends with ${F_GATES[5]}" "${F_ALL[@]:0:13}"
case_end

case_begin "F4-missing-marker-helper-still-commits" "hooks/pre-commit"
# The marker helper is optional: without it the hook still runs every section, unmarked.
f_fixture nohelper
rm -f "$R/hooks/lib/precommit-section-marker.sh"
f_commit "$R" "$R"
if [ "$CRC" -eq 0 ]; then
    pass "F4: commit succeeds without the marker helper"
else
    fail "F4: commit succeeds without the marker helper" "rc=$CRC err: $(e_flat "$(cat "$R.err")")"
fi
if [ -z "$FMARKS" ] && ! grep -q 'pre-commit-section:' "$R.err"; then
    pass "F4: no marker line on stderr without the helper"
else
    fail "F4: no marker line on stderr without the helper" "markers: $(e_flat "$FMARKS")"
fi
case_end

case_begin "F5-missing-marker-helper-blocked-checker-still-rejects" "hooks/lib/precommit-agents-repo-gates.sh"
# Without the marker helper a failing checker must still block the commit, unmarked.
f_fixture nohelper-blocked
rm -f "$R/hooks/lib/precommit-section-marker.sh"
e_stub "$R" "${E_CHECKERS[5]}" 1
f_commit "$R" "$R"
if [ "$CRC" -ne 0 ]; then
    pass "F5: a commit blocked by ${E_CHECKERS[5]} is rejected without the marker helper"
else
    fail "F5: a commit blocked by ${E_CHECKERS[5]} is rejected without the marker helper" "rc=0"
fi
if [ -z "$FMARKS" ] && ! grep -q 'pre-commit-section:' "$R.err"; then
    pass "F5: no marker line on stderr for the blocked commit without the helper"
else
    fail "F5: no marker line on stderr for the blocked commit without the helper" "markers: $(e_flat "$FMARKS")"
fi
case_end

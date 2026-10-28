# Part E (commit wiring) — a real `git commit` through the installed hooks/pre-commit (#2589).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.
# Only these fixtures point core.hooksPath at their own hooks/; every other fixture keeps /dev/null.
# The agents-repo fixture IS the hook's checkout, so the six gates arm; a non-GitHub origin ends
# the hook right after the gates, before the outbound scan.

echo ""
echo "=== Part E: agents-repo gates reached by a real git commit ==="

E_CHECKERS=(
    bin/check-on-demand-rules.sh
    bin/check-session-id-ssot.sh
    bin/check-migration-blocks.sh
    bin/check-plans-artifacts
    bin/check-plans-dir-isolation.sh
    bin/check-root-names.sh
)

# The hook, the libraries it sources and the env OS filter, committed once; each case copies it.
E_TEMPLATE="$TMPBASE/e-template"
if ! script_checkout_fixture_copy "$E_TEMPLATE" hooks/pre-commit hooks/lib bin/env-os-filter bin/size-check bin/lib/size-check; then
    fail "E: commit-wiring template" "script_checkout_fixture_copy failed"
fi
init_repo_bare "$E_TEMPLATE"
printf 'ENFORCE_WORKTREE=off\n' > "$E_TEMPLATE/.env"
printf '.env\n' > "$E_TEMPLATE/.gitignore"
git -C "$E_TEMPLATE" add -A >/dev/null 2>&1
git -C "$E_TEMPLATE" commit -q -m template >/dev/null 2>&1
git -C "$E_TEMPLATE" remote add origin https://example.invalid/agents-fixture.git

# e_stub <repo> <checker> <rc> — a checker that records its own name in <repo>.calls, then exits <rc>.
e_stub() {
    local f="$1/$2" log
    log="$(np "$1.calls")"
    mkdir -p "$(dirname "$f")"
    if [ "$2" = bin/check-plans-artifacts ]; then
        printf '%s\n' "require(\"fs\").appendFileSync(\"$log\", \"$2\\n\");" "process.exit($3);" > "$f"
    else
        printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$2' >> '$log'" "exit $3" > "$f"
    fi
    chmod +x "$f"
}

# e_fixture <name> — copy of the template with the hook armed, six clean checkers and app.txt staged.
e_fixture() {
    local c
    R="$TMPBASE/e-$1"
    rm -rf "$R" "$R.calls"
    cp -R "$E_TEMPLATE" "$R"
    for c in "${E_CHECKERS[@]}"; do e_stub "$R" "$c" 0; done
    git -C "$R" add -A >/dev/null 2>&1
    git -C "$R" commit -q -m checkers >/dev/null 2>&1
    git -C "$R" config core.hooksPath "$(np "$R/hooks")"
    rm -f "$R.calls"
    printf 'x\n' > "$R/app.txt"
    git -C "$R" add -- app.txt >/dev/null 2>&1
}

# e_commit <repo> — real git commit; sets COUT / CRC / CHEAD (commits on the branch afterwards).
# AGENTS_MAIN_ROOT moves from the harness decoy to the fixture, the settings root load-env reads.
e_commit() {
    CRC=0
    COUT="$(cd "$1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX && export ENFORCE_WORKTREE=off && \
        export AGENTS_MAIN_ROOT="$(np "$1")" && run_with_timeout 60 git commit -q -m wiring 2>&1)" || CRC=$?
    CHEAD="$(git -C "$1" rev-list --count HEAD 2>/dev/null)"
}

e_flat() { printf '%s' "$1" | tr '\n' ' '; }

case_begin "E1-clean-commit-reaches-all-six-gates" "hooks/pre-commit"
e_fixture clean
e_commit "$R"
if [ "$CRC" -ne 0 ] || [ "$CHEAD" != 3 ]; then
    fail "E1: clean commit" "want rc 0 and a new commit, got rc $CRC, $CHEAD commits — out: $(e_flat "$COUT")"
else
    pass "E1: a commit with six clean checkers goes through the real hook"
fi
for c in "${E_CHECKERS[@]}"; do
    if grep -qxF "$c" "$R.calls" 2>/dev/null; then
        pass "E1: the hook ran $c during git commit"
    else
        fail "E1: the hook ran $c during git commit" "calls: $(e_flat "$(cat "$R.calls" 2>/dev/null)")"
    fi
done
case_end

case_begin "E2-missing-checker-rejects-the-commit" "hooks/pre-commit"
for c in "${E_CHECKERS[@]}"; do
    e_fixture "missing-${c##*/}"
    rm -f "$R/$c"
    e_commit "$R"
    if [ "$CRC" -eq 0 ] || [ "$CHEAD" != 2 ]; then
        fail "E2: missing $c rejects the commit" "rc $CRC, $CHEAD commits — out: $(e_flat "$COUT")"
    elif ! printf '%s' "$COUT" | grep -qF "${c##*/}"; then
        fail "E2: missing $c names the checker" "out: $(e_flat "$COUT")"
    else
        pass "E2: git commit is rejected when $c is missing, and the hook names it"
    fi
done
case_end

case_begin "E3-unexpected-checker-rc-rejects-the-commit" "hooks/pre-commit"
for c in "${E_CHECKERS[@]}"; do
    e_fixture "rc3-${c##*/}"
    e_stub "$R" "$c" 3
    e_commit "$R"
    if [ "$CRC" -eq 0 ] || [ "$CHEAD" != 2 ]; then
        fail "E3: rc 3 from $c rejects the commit" "rc $CRC, $CHEAD commits — out: $(e_flat "$COUT")"
    elif ! printf '%s' "$COUT" | grep -qF "${c##*/}" || ! printf '%s' "$COUT" | grep -qF 'rc=3'; then
        fail "E3: rc 3 from $c names the checker and the rc" "out: $(e_flat "$COUT")"
    else
        pass "E3: git commit is rejected when $c answers rc 3, and the hook names it with rc=3"
    fi
done
case_end

# E4: mutation control — the same fixture with the gates call removed from the hook commits and
# runs no checker, so E1-E3 can only pass while hooks/pre-commit really calls the gates.
case_begin "E4-gates-call-removed-is-detected" "hooks/pre-commit"
e_fixture mutant
sed -i 's/^_precommit_agents_repo_gates\([[:space:]].*\)\{0,1\}$/: gates call removed/' "$R/hooks/pre-commit"
if ! grep -qx ': gates call removed' "$R/hooks/pre-commit"; then
    fail "E4: mutation applied" "hooks/pre-commit has no top-level _precommit_agents_repo_gates call line"
else
    rm -f "$R/bin/check-root-names.sh"
    e_commit "$R"
    if [ "$CRC" -eq 0 ] && [ ! -s "$R.calls" ]; then
        pass "E4: without the call the commit goes through and no checker runs (E1-E3 discriminate)"
    else
        fail "E4: mutant" "want rc 0 and no checker call, got rc $CRC, calls: $(e_flat "$(cat "$R.calls" 2>/dev/null)")"
    fi
fi
case_end

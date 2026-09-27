# Part D — staged case-marker gate _precommit_check_tests_case_markers (#2388).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.
# Fixture test bodies carrying marker text live only in heredoc bodies below.

echo ""
echo "=== Part D: staged case-marker gate (#2388) ==="

LOAD_ENV_SH="$AGENTS_DIR/hooks/lib/load-env.sh"
# shellcheck source=hooks/lib/load-env.sh
[ -f "$LOAD_ENV_SH" ] && . "$LOAD_ENV_SH"

# CM_CFG — a fixture config dir: a copy of the real checker plus its predicate
# library, so each case controls $_cfg_dir/.env without touching the developer's.
CM_CFG="$TMPBASE/cm-cfg"
mkdir -p "$CM_CFG/bin"
cp "$AGENTS_DIR/bin/check-case-markers.sh" "$CM_CFG/bin/check-case-markers.sh"
cp -R "$AGENTS_DIR/bin/lib" "$CM_CFG/bin/lib"

# CM_BROKEN_CFG — checker replaced by a stub that exits 2 (infrastructure error).
CM_BROKEN_CFG="$TMPBASE/cm-cfg-broken"
mkdir -p "$CM_BROKEN_CFG/bin"
printf '#!/usr/bin/env bash\necho "stub infra failure" >&2\nexit 2\n' > "$CM_BROKEN_CFG/bin/check-case-markers.sh"

CM_BODIES="$TMPBASE/cm-bodies"
mkdir -p "$CM_BODIES"

cat > "$CM_BODIES/missing.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
echo no markers
EOF

cat > "$CM_BODIES/malformed.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
  case_begin "a" "bin/a.sh"
  case_end
EOF

cat > "$CM_BODIES/conforming.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# Tags: scope:common
case_begin "a" "bin/a.sh"
echo a
case_end
case_begin "b" "bin/b.sh"
echo b
case_end
EOF

cat > "$CM_BODIES/uncertain.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
node -e '
for (const a of [1]) console.log(a)
'
case_begin "a" "bin/a.sh"
case_end
EOF

cat > "$CM_BODIES/single-path.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh
# Tags: scope:common
echo single path needs no markers
EOF

# cm_repo <name> [noharness] — fixture repo with HEAD; tests/lib/harness.sh is
# committed unless "noharness" (the gate's applicability condition).
cm_repo() {
    local dir="$TMPBASE/cm-$1"
    init_fixture "$dir"
    if [ "${2:-}" != "noharness" ]; then
        mkdir -p "$dir/tests/lib"
        printf '#!/usr/bin/env bash\n' > "$dir/tests/lib/harness.sh"
        git -C "$dir" add tests/lib/harness.sh >/dev/null 2>&1
        git -C "$dir" commit -q -m harness >/dev/null 2>&1
    fi
    printf '%s' "$dir"
}

# cm_put <repo> <rel> <body> — copy a body into the working tree (no staging).
cm_put() {
    mkdir -p "$(dirname "$1/$2")"
    cp "$CM_BODIES/$3" "$1/$2"
}

# cm_stage <repo> <rel> <body> — write and stage a body.
cm_stage() {
    cm_put "$1" "$2" "$3"
    git -C "$1" add -- "$2" >/dev/null 2>&1
}

# cm_commit <repo> <rel> <body> — write, stage and commit a body (lands in HEAD).
cm_commit() {
    cm_stage "$1" "$2" "$3"
    git -C "$1" commit -q -m "add $2" >/dev/null 2>&1
}

# run_cm <repo> [cfg] — call the gate in a subshell with the fixture as CWD.
# Sets CM_RC, CM_OUT (stdout), CM_ERR (stderr). Extra environment for the
# subshell comes from the CM_ENV array (NAME=value words, exported inside).
CM_OUT=""; CM_ERR=""; CM_RC=0
CM_ENV=()
run_cm() {
    local repo="$1" cfg="${2:-$CM_CFG}"
    if ! declare -F _precommit_check_tests_case_markers >/dev/null 2>&1; then
        CM_RC=127; CM_OUT=""
        CM_ERR="IMPLEMENTATION MISSING: _precommit_check_tests_case_markers"
        return 0
    fi
    CM_RC=0
    (
        cd "$repo" || exit 99
        local kv
        for kv in "${CM_ENV[@]+"${CM_ENV[@]}"}"; do
            export "${kv?}"
        done
        _cfg_dir="$cfg"
        _precommit_check_tests_case_markers
    ) >"$TMPBASE/cm.out" 2>"$TMPBASE/cm.err" || CM_RC=$?
    CM_OUT="$(cat "$TMPBASE/cm.out")"
    CM_ERR="$(cat "$TMPBASE/cm.err")"
}

# cm_env_file <content> — (re)write the fixture cfg .env; empty removes it.
cm_env_file() {
    rm -f "$CM_CFG/.env"
    [ -n "$1" ] && printf '%s\n' "$1" > "$CM_CFG/.env"
    return 0
}

# expect_block <label> <regex-on-combined-output>
expect_block() {
    assert_eq "$CM_RC" "1"
    printf '%s\n%s\n' "$CM_OUT" "$CM_ERR" | grep -Eq "$2" \
        && pass "$1: output matches /$2/" \
        || fail "$1: output" "want /$2/ got out=[$CM_OUT] err=[$CM_ERR]"
}

# expect_pass_silent <label> — rc 0 and no HIGH line anywhere.
expect_pass_silent() {
    assert_eq "$CM_RC" "0"
    printf '%s\n%s\n' "$CM_OUT" "$CM_ERR" | grep -q '^HIGH:' \
        && fail "$1: unexpected HIGH" "out=[$CM_OUT] err=[$CM_ERR]" \
        || pass "$1: no HIGH line"
}

cm_env_file ""

case_begin "new-staged-missing-blocks" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo missing)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
run_cm "$R"
expect_block "new-staged-missing-blocks" '^HIGH: tests/hooks/new-missing\.sh \(2 paths in # Tests: header.*code=MISSING_CASE_MARKERS$'
expect_block "new-staged-missing-blocks cause message" 'Wrap each case in '
printf '%s\n%s\n' "$CM_OUT" "$CM_ERR" | grep -q "$TMPBASE\|/tmp/" \
    && fail "new-staged-missing-blocks: temp path leaked into output" "$CM_OUT $CM_ERR" \
    || pass "new-staged-missing-blocks: temp path replaced by the rel path"
case_end

case_begin "new-staged-malformed-blocks" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo malformed)"
cm_stage "$R" tests/bin/new-bad.sh malformed.sh
run_cm "$R"
expect_block "new-staged-malformed-blocks" '^HIGH: tests/bin/new-bad\.sh line 3: malformed case marker \(grammar\) code=MALFORMED_CASE_MARKER$'
expect_block "new-staged-malformed-blocks cause message" 'Fix marker placement'
case_end

case_begin "new-staged-conforming-passes" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo conforming)"
cm_stage "$R" tests/hooks/new-good.sh conforming.sh
run_cm "$R"
expect_pass_silent "new-staged-conforming-passes"
case_end

case_begin "new-staged-uncertain-warns" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo uncertain)"
cm_stage "$R" tests/hooks/new-unc.sh uncertain.sh
run_cm "$R"
expect_pass_silent "new-staged-uncertain-warns"
printf '%s\n' "$CM_ERR" | grep -Eq '^WARN: tests/hooks/new-unc\.sh line [0-9]+: .*code=UNCERTAIN_CASE_MARKER$' \
    && pass "new-staged-uncertain-warns: WARN forwarded to stderr" \
    || fail "new-staged-uncertain-warns: WARN on stderr" "err=[$CM_ERR]"
case_end

case_begin "renamed-to-new-path-judged" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo rename-bad)"
cm_commit "$R" tests/hooks/old-name.sh missing.sh
git -C "$R" mv tests/hooks/old-name.sh tests/hooks/new-name.sh
run_cm "$R"
expect_block "renamed-to-new-path-judged" '^HIGH: tests/hooks/new-name\.sh .*code=MISSING_CASE_MARKERS$'
case_end

case_begin "renamed-existing-content-conforming-passes" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo rename-good)"
cm_commit "$R" tests/hooks/old-good.sh conforming.sh
git -C "$R" mv tests/hooks/old-good.sh tests/hooks/new-good.sh
run_cm "$R"
expect_pass_silent "renamed-existing-content-conforming-passes"
case_end

case_begin "deleted-file-ignored" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo deleted)"
cm_commit "$R" tests/hooks/gone.sh missing.sh
git -C "$R" rm -q tests/hooks/gone.sh
run_cm "$R"
expect_pass_silent "deleted-file-ignored"
assert_eq "$CM_ERR" ""
case_end

case_begin "existing-file-skipped" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo existing)"
cm_commit "$R" tests/hooks/legacy.sh missing.sh
printf 'echo edited\n' >> "$R/tests/hooks/legacy.sh"
git -C "$R" add tests/hooks/legacy.sh
run_cm "$R"
expect_pass_silent "existing-file-skipped"
case_end

case_begin "partial-stage-blob-judged" "hooks/lib/precommit-tests-frontmatter.sh"
# Staged blob violates; the working tree was fixed but not re-staged → block.
R="$(cm_repo partial)"
cm_stage "$R" tests/hooks/partial.sh missing.sh
cm_put "$R" tests/hooks/partial.sh conforming.sh
run_cm "$R"
expect_block "partial-stage-blob-judged" '^HIGH: tests/hooks/partial\.sh .*code=MISSING_CASE_MARKERS$'
case_end

case_begin "partial-stage-inverse" "hooks/lib/precommit-tests-frontmatter.sh"
# Staged blob conforms; only the unstaged working tree violates → pass.
R="$(cm_repo partial-inv)"
cm_stage "$R" tests/hooks/partial.sh conforming.sh
cm_put "$R" tests/hooks/partial.sh missing.sh
run_cm "$R"
expect_pass_silent "partial-stage-inverse"
assert_eq "$CM_RC" "0"
case_end

case_begin "no-harness-repo-skipped" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo noharness noharness)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
run_cm "$R"
expect_pass_silent "no-harness-repo-skipped"
assert_eq "$CM_OUT" ""
case_end

case_begin "suite-subfile-skipped" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo subfile)"
cm_stage "$R" tests/hooks/suite/part.sh missing.sh
run_cm "$R"
expect_pass_silent "suite-subfile-skipped"
assert_eq "$CM_OUT" ""
case_end

case_begin "run-all-skipped" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo runall)"
cm_stage "$R" tests/run-all.sh missing.sh
run_cm "$R"
expect_pass_silent "run-all-skipped"
assert_eq "$CM_OUT" ""
case_end

case_begin "single-path-header-skipped" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo single)"
cm_stage "$R" tests/hooks/single.sh single-path.sh
run_cm "$R"
expect_pass_silent "single-path-header-skipped"
case_end

case_begin "enforce-off-disabled-message" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo enforce-off)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
cm_env_file "CASE_MARKERS_ENFORCE=off"
run_cm "$R"
cm_env_file ""
expect_pass_silent "enforce-off-disabled-message"
printf '%s\n' "$CM_ERR" | grep -qF 'pre-commit: case-marker gate disabled by CASE_MARKERS_ENFORCE=off' \
    && pass "enforce-off-disabled-message: stderr names the .env switch" \
    || fail "enforce-off-disabled-message: stderr" "err=[$CM_ERR]"
case_end

case_begin "ambient-env-off-ignored" "hooks/lib/precommit-tests-frontmatter.sh"
# Only $_cfg_dir/.env may disable the gate; an ambient export must not.
R="$(cm_repo ambient)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
cm_env_file "CASE_MARKERS_ENFORCE=on"
CM_ENV=("CASE_MARKERS_ENFORCE=off")
run_cm "$R"
CM_ENV=()
cm_env_file ""
expect_block "ambient-env-off-ignored" 'code=MISSING_CASE_MARKERS'
case_end

case_begin "checker-infra-error-fail-open" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo infra)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
run_cm "$R" "$CM_BROKEN_CFG"
assert_eq "$CM_RC" "0"
printf '%s\n' "$CM_ERR" | grep -qF 'pre-commit: check-case-markers rc=2 for tests/hooks/new-missing.sh — case-marker check incomplete (commit continues)' \
    && pass "checker-infra-error-fail-open: diagnostic on stderr" \
    || fail "checker-infra-error-fail-open: diagnostic" "err=[$CM_ERR]"
case_end

case_begin "tmpdir-cleaned" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo tmpclean)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
cm_stage "$R" tests/hooks/new-good.sh conforming.sh
CM_TMPDIR="$TMPBASE/cm-tmpdir"
mkdir -p "$CM_TMPDIR"
CM_ENV=("TMPDIR=$CM_TMPDIR")
run_cm "$R"
CM_ENV=()
assert_eq "$CM_RC" "1"
assert_eq "$(ls -A "$CM_TMPDIR")" ""
case_end

case_begin "hook-line-wired" "hooks/pre-commit"
# The call sits on the line right after the frontmatter gate call.
fm_ln="$(grep -n '^[[:space:]]*_precommit_check_tests_frontmatter || exit 1[[:space:]]*$' "$PRECOMMIT" | head -n 1 | cut -d: -f1)"
next_line=""
[ -n "$fm_ln" ] && next_line="$(sed -n "$((fm_ln + 1))p" "$PRECOMMIT" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
assert_eq "$next_line" "_precommit_check_tests_case_markers || exit 1"
case_end

case_begin "entrypoint-helper-classification" "hooks/lib/precommit-tests-frontmatter.sh"
# rel|expected (0 = .sh test entrypoint, 1 = not)
CM_ROWS=(
    "tests/hooks/x.sh|0" "tests/bin/x.sh|0" "tests/skills/x.sh|0"
    "tests/agents/x.sh|0" "tests/install/x.sh|0" "tests/tests/x.sh|0"
    "tests/flat.sh|0" "tests/run-all.sh|1" "tests/_archive/x.sh|1"
    "tests/lib/harness.sh|1" "tests/hooks/suite/x.sh|1" "tests/unknown/x.sh|1"
    "tests/hooks/x.Tests.ps1|1" "tests/hooks/test_x.py|1"
)
cm_fn_ok=0
declare -F _precommit_is_sh_test_entrypoint >/dev/null 2>&1 && cm_fn_ok=1
assert_eq "$cm_fn_ok" "1"
for _row in "${CM_ROWS[@]}"; do
    _rel="${_row%|*}"
    _want="${_row##*|}"
    _got=127
    if [ "$cm_fn_ok" -eq 1 ]; then
        _got=0
        _precommit_is_sh_test_entrypoint "$_rel" || _got=$?
        [ "$_got" -ne 0 ] && _got=1
    fi
    [ "$_got" = "$_want" ] && pass "entrypoint-helper: $_rel -> $_want" \
        || fail "entrypoint-helper: $_rel" "want $_want got $_got"
done
case_end

unset R CM_ROWS _row _rel _want _got cm_fn_ok fm_ln next_line CM_TMPDIR

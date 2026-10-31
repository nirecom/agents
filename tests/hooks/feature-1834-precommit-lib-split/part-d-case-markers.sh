# Part D — staged case-marker gate of the tests-frontmatter check (#2388; Node since #2507).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.
# Fixture test bodies carrying marker text live only in heredoc bodies below.

echo ""
echo "=== Part D: staged case-marker gate (#2388) ==="

# CM_BAD_CFG — an agents checkout whose test language registry is unreadable (Part C's template
# with a corrupt table): the gate cannot classify, so it fails open with a diagnostic.
CM_BAD_CFG="$TMPBASE/cm-cfg-bad-registry"
cp -R "$G_TEMPLATE" "$CM_BAD_CFG"
printf '{ not json\n' > "$CM_BAD_CFG/hooks/lib/test-language-registry.json"

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

# run_cm <repo> [cfg] — the case-marker gate alone, with the fixture as CWD. Sets CM_RC, CM_OUT
# (stdout), CM_ERR (stderr). Extra environment comes from the CM_ENV array (NAME=value words).
CM_OUT=""; CM_ERR=""; CM_RC=0
CM_ENV=()
run_cm() {
    local repo="$1" cfg="${2:-$SCRIPT_CHECKOUT_ROOT}"
    CM_RC=0
    (
        cd "$repo" || exit 99
        local kv
        for kv in "${CM_ENV[@]+"${CM_ENV[@]}"}"; do
            export "${kv?}"
        done
        node "$RUNNER" --cfg "$(np "$cfg")" tests-frontmatter case-markers
    ) >"$TMPBASE/cm.out" 2>"$TMPBASE/cm.err" || CM_RC=$?
    CM_OUT="$(cat "$TMPBASE/cm.out")"
    CM_ERR="$(cat "$TMPBASE/cm.err")"
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

case_begin "new-staged-missing-blocks" "hooks/pre-commit"
R="$(cm_repo missing)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
run_cm "$R"
expect_block "new-staged-missing-blocks" '^HIGH: tests/hooks/new-missing\.sh \(2 paths in # Tests: header.*code=MISSING_CASE_MARKERS$'
expect_block "new-staged-missing-blocks cause message" 'Wrap each case in '
printf '%s\n%s\n' "$CM_OUT" "$CM_ERR" | grep -q "$TMPBASE\|/tmp/" \
    && fail "new-staged-missing-blocks: temp path leaked into output" "$CM_OUT $CM_ERR" \
    || pass "new-staged-missing-blocks: temp path replaced by the rel path"
case_end

case_begin "new-staged-malformed-blocks" "hooks/pre-commit"
R="$(cm_repo malformed)"
cm_stage "$R" tests/bin/new-bad.sh malformed.sh
run_cm "$R"
expect_block "new-staged-malformed-blocks" '^HIGH: tests/bin/new-bad\.sh line 3: malformed case marker \(grammar\) code=MALFORMED_CASE_MARKER$'
expect_block "new-staged-malformed-blocks cause message" 'Fix marker placement'
case_end

case_begin "new-staged-conforming-passes" "hooks/pre-commit"
R="$(cm_repo conforming)"
cm_stage "$R" tests/hooks/new-good.sh conforming.sh
run_cm "$R"
expect_pass_silent "new-staged-conforming-passes"
case_end

case_begin "new-staged-uncertain-warns" "hooks/pre-commit"
R="$(cm_repo uncertain)"
cm_stage "$R" tests/hooks/new-unc.sh uncertain.sh
run_cm "$R"
expect_pass_silent "new-staged-uncertain-warns"
printf '%s\n' "$CM_ERR" | grep -Eq '^WARN: tests/hooks/new-unc\.sh line [0-9]+: .*code=UNCERTAIN_CASE_MARKER$' \
    && pass "new-staged-uncertain-warns: WARN forwarded to stderr" \
    || fail "new-staged-uncertain-warns: WARN on stderr" "err=[$CM_ERR]"
case_end

case_begin "renamed-to-new-path-judged" "hooks/pre-commit"
R="$(cm_repo rename-bad)"
cm_commit "$R" tests/hooks/old-name.sh missing.sh
git -C "$R" mv tests/hooks/old-name.sh tests/hooks/new-name.sh
run_cm "$R"
expect_block "renamed-to-new-path-judged" '^HIGH: tests/hooks/new-name\.sh .*code=MISSING_CASE_MARKERS$'
case_end

case_begin "renamed-existing-content-conforming-passes" "hooks/pre-commit"
R="$(cm_repo rename-good)"
cm_commit "$R" tests/hooks/old-good.sh conforming.sh
git -C "$R" mv tests/hooks/old-good.sh tests/hooks/new-good.sh
run_cm "$R"
expect_pass_silent "renamed-existing-content-conforming-passes"
case_end

case_begin "deleted-file-ignored" "hooks/pre-commit"
R="$(cm_repo deleted)"
cm_commit "$R" tests/hooks/gone.sh missing.sh
git -C "$R" rm -q tests/hooks/gone.sh
run_cm "$R"
expect_pass_silent "deleted-file-ignored"
assert_eq "$CM_ERR" ""
case_end

case_begin "existing-file-skipped" "hooks/pre-commit"
R="$(cm_repo existing)"
cm_commit "$R" tests/hooks/legacy.sh missing.sh
printf 'echo edited\n' >> "$R/tests/hooks/legacy.sh"
git -C "$R" add tests/hooks/legacy.sh
run_cm "$R"
expect_pass_silent "existing-file-skipped"
case_end

case_begin "partial-stage-blob-judged" "hooks/pre-commit"
# Staged blob violates; the working tree was fixed but not re-staged → block.
R="$(cm_repo partial)"
cm_stage "$R" tests/hooks/partial.sh missing.sh
cm_put "$R" tests/hooks/partial.sh conforming.sh
run_cm "$R"
expect_block "partial-stage-blob-judged" '^HIGH: tests/hooks/partial\.sh .*code=MISSING_CASE_MARKERS$'
case_end

case_begin "partial-stage-inverse" "hooks/pre-commit"
# Staged blob conforms; only the unstaged working tree violates → pass.
R="$(cm_repo partial-inv)"
cm_stage "$R" tests/hooks/partial.sh conforming.sh
cm_put "$R" tests/hooks/partial.sh missing.sh
run_cm "$R"
expect_pass_silent "partial-stage-inverse"
assert_eq "$CM_RC" "0"
case_end

case_begin "no-harness-repo-skipped" "hooks/pre-commit"
R="$(cm_repo noharness noharness)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
run_cm "$R"
expect_pass_silent "no-harness-repo-skipped"
assert_eq "$CM_OUT" ""
case_end

case_begin "suite-subfile-skipped" "hooks/pre-commit"
R="$(cm_repo subfile)"
cm_stage "$R" tests/hooks/suite/part.sh missing.sh
run_cm "$R"
expect_pass_silent "suite-subfile-skipped"
assert_eq "$CM_OUT" ""
case_end

case_begin "run-all-skipped" "hooks/pre-commit"
R="$(cm_repo runall)"
cm_stage "$R" tests/run-all.sh missing.sh
run_cm "$R"
expect_pass_silent "run-all-skipped"
assert_eq "$CM_OUT" ""
case_end

case_begin "single-path-header-skipped" "hooks/pre-commit"
R="$(cm_repo single)"
cm_stage "$R" tests/hooks/single.sh single-path.sh
run_cm "$R"
expect_pass_silent "single-path-header-skipped"
case_end

case_begin "env-off-still-blocks" "hooks/pre-commit"
# The gate has no disable switch: an off value in the environment is ignored.
R="$(cm_repo env-off)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
CM_ENV=("CASE_MARKERS_ENFORCE=off")
run_cm "$R"
CM_ENV=()
expect_block "env-off-still-blocks" 'code=MISSING_CASE_MARKERS'
case_end

case_begin "registry-unreadable-fail-open" "hooks/pre-commit"
R="$(cm_repo infra)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
run_cm "$R" "$CM_BAD_CFG"
assert_eq "$CM_RC" "0"
printf '%s\n' "$CM_ERR" | grep -qF 'pre-commit: test language registry not readable — case-marker check skipped (commit continues)' \
    && pass "registry-unreadable-fail-open: diagnostic on stderr" \
    || fail "registry-unreadable-fail-open: diagnostic" "err=[$CM_ERR]"
case_end

case_begin "tmpdir-cleaned" "hooks/pre-commit"
R="$(cm_repo tmpclean)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
cm_stage "$R" tests/hooks/new-good.sh conforming.sh
CM_TMPDIR="$TMPBASE/cm-tmpdir"
mkdir -p "$CM_TMPDIR"
CM_ENV=("TMPDIR=$CM_TMPDIR" "TMP=$CM_TMPDIR" "TEMP=$CM_TMPDIR")
run_cm "$R"
CM_ENV=()
assert_eq "$CM_RC" "1"
assert_eq "$(ls -A "$CM_TMPDIR")" ""
case_end

case_begin "hook-line-wired" "hooks/pre-commit"
# #2507: the gate runs right after the frontmatter gate in the Node tests-frontmatter check.
gates_line="$(grep -E '^const GATES = ' "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/tests-frontmatter.js")"
assert_eq "$gates_line" "const GATES = [frontmatter, caseMarkers, languageMatch];"
case_end

case_begin "entrypoint-helper-classification" "hooks/pre-commit"
# rel|expected (0 = case-marker target: a placed entrypoint whose registry entry has a
# caseMarkerReader; 1 = not). A bare ".sh" names no entry (the registry's * is 1+ chars).
CM_ROWS=(
    "tests/hooks/x.sh|0" "tests/bin/x.sh|0" "tests/skills/x.sh|0"
    "tests/agents/x.sh|0" "tests/install/x.sh|0" "tests/tests/x.sh|0"
    "tests/flat.sh|0" "tests/run-all.sh|1" "tests/_archive/x.sh|1"
    "tests/lib/harness.sh|1" "tests/hooks/suite/x.sh|1" "tests/unknown/x.sh|1"
    "tests/hooks/x.Tests.ps1|0" "tests/hooks/test_x.py|0" "tests/hooks/x.js|0"
    "tests/hooks/suite/x.Tests.ps1|1" "tests/lib/test_x.py|1" "tests/hooks/suite/x.js|1"
    "tests/hooks/x.test.ts|1" "tests/hooks/.sh|1"
)
# The gate's predicate (hooks/lib/test-gates/placement.js isCaseMarkerTarget), one "rel|0/1" per row.
CM_GOT="$(node -e '
const p = require(process.argv[1]);
for (const r of process.argv.slice(2)) console.log(`${r}|${p.isCaseMarkerTarget(r) ? 0 : 1}`);
' "$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-gates/placement.js")" "${CM_ROWS[@]%|*}" 2>&1)"
for _row in "${CM_ROWS[@]}"; do
    printf '%s\n' "$CM_GOT" | grep -qxF -- "$_row" && pass "entrypoint-helper: $_row" \
        || fail "entrypoint-helper: ${_row%|*}" "want ${_row##*|}; predicate said: $(printf '%s' "$CM_GOT" | grep -F -- "${_row%|*}|" | head -n 1)"
done
case_end

unset R CM_ROWS CM_GOT _row CM_TMPDIR

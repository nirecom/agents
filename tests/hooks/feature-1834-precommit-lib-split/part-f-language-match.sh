# Part F — staged language-match gate of the tests-frontmatter check (#2502 S4-7; Node since #2507).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals
# (TMPBASE, cm_repo, CM_BAD_CFG, RUNNER, SCRIPT_CHECKOUT_ROOT, pass/fail/assert_eq).
# #2507 retired the bash call-contract cases (--rel / --head arguments, stub rc handling): the
# gate now judges in process. Its verdict rows for new/existing/unregistered files and the
# HIGH/WARN output are pinned by tests/hooks/feature-2502-language-match-gate.js; the cases
# below pin what only a staged index shows (staged blob, deletions, temp files, rc 2).

echo ""
echo "=== Part F: staged language-match gate (#2502) ==="

# Bodies: a bash test naming a .js code path is a language mismatch; a .sh one is clean.
LMF_BAD="$(printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/foo.js' '# Tags: scope:common' 'echo bad')"
LMF_GOOD="$(printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/foo.sh' '# Tags: scope:common' 'echo good')"
LMF_OUT=""; LMF_ERR=""; LMF_RC=0
LMF_ENV=()

# run_lmf <repo> [cfg] — the language-match gate alone, with the fixture as CWD.
run_lmf() {
    local repo="$1" cfg="${2:-$SCRIPT_CHECKOUT_ROOT}"
    LMF_RC=0
    (
        cd "$repo" || exit 99
        local kv
        for kv in "${LMF_ENV[@]+"${LMF_ENV[@]}"}"; do
            export "${kv?}"
        done
        node "$RUNNER" --cfg "$(np "$cfg")" tests-frontmatter language-match
    ) >"$TMPBASE/lmf.out" 2>"$TMPBASE/lmf.err" || LMF_RC=$?
    LMF_OUT="$(cat "$TMPBASE/lmf.out")"
    LMF_ERR="$(cat "$TMPBASE/lmf.err")"
}

# lmf_put <repo> <rel> <body> — write a file in the working tree; lmf_stage also stages it.
lmf_put() {
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
}
lmf_stage() {
    lmf_put "$1" "$2" "$3"
    git -C "$1" add -- "$2" >/dev/null 2>&1
}

lmf_has_mismatch() {
    printf '%s\n%s\n' "$LMF_OUT" "$LMF_ERR" | grep -qF 'code=TEST_LANGUAGE_MISMATCH'
}

case_begin "lmf-partial-stage-judges-the-staged-blob" "hooks/pre-commit"
# Staged blob mismatches; the working tree was fixed but not re-staged → block.
R="$(cm_repo lmf-partial)"
lmf_stage "$R" tests/hooks/p.sh "$LMF_BAD"
lmf_put "$R" tests/hooks/p.sh "$LMF_GOOD"
run_lmf "$R"
assert_eq "$LMF_RC" "1"
lmf_has_mismatch && pass "lmf-partial-stage: mismatch reported from the staged blob" \
    || fail "lmf-partial-stage: mismatch" "out=[$LMF_OUT] err=[$LMF_ERR]"
case_end

case_begin "lmf-partial-stage-inverse" "hooks/pre-commit"
# Staged blob is clean; only the unstaged working tree mismatches → pass.
R="$(cm_repo lmf-partial-inv)"
lmf_stage "$R" tests/hooks/p.sh "$LMF_GOOD"
lmf_put "$R" tests/hooks/p.sh "$LMF_BAD"
run_lmf "$R"
assert_eq "$LMF_RC" "0"
lmf_has_mismatch && fail "lmf-partial-stage-inverse: working tree judged" "out=[$LMF_OUT] err=[$LMF_ERR]" \
    || pass "lmf-partial-stage-inverse: the unstaged mismatch is not judged"
case_end

case_begin "lmf-deleted-file-ignored" "hooks/pre-commit"
R="$(cm_repo lmf-deleted)"
lmf_stage "$R" tests/hooks/gone.sh "$LMF_BAD"
git -C "$R" commit -q -m gone >/dev/null 2>&1
git -C "$R" rm -q tests/hooks/gone.sh
run_lmf "$R"
assert_eq "$LMF_RC" "0"
assert_eq "$LMF_OUT$LMF_ERR" ""
case_end

case_begin "lmf-rc2-continues-with-a-diagnostic" "hooks/pre-commit"
# An unreadable registry cannot judge: the commit continues with a per-file diagnostic.
R="$(cm_repo lmf-rc2)"
lmf_stage "$R" tests/hooks/n.sh "$LMF_BAD"
run_lmf "$R" "$CM_BAD_CFG"
assert_eq "$LMF_RC" "0"
printf '%s\n' "$LMF_ERR" | grep -Eq 'rc=2 for tests/hooks/n\.sh .*check incomplete \(commit continues\)' \
    && pass "lmf-rc2: diagnostic on stderr" \
    || fail "lmf-rc2: diagnostic" "err=[$LMF_ERR]"
case_end

case_begin "lmf-tmpdir-cleaned" "hooks/pre-commit"
R="$(cm_repo lmf-tmpclean)"
lmf_stage "$R" tests/hooks/n.sh "$LMF_BAD"
lmf_stage "$R" tests/hooks/e.sh "$LMF_GOOD"
LMF_TMPDIR="$TMPBASE/lmf-tmpdir"
mkdir -p "$LMF_TMPDIR"
LMF_ENV=("TMPDIR=$LMF_TMPDIR" "TMP=$LMF_TMPDIR" "TEMP=$LMF_TMPDIR")
run_lmf "$R"
LMF_ENV=()
assert_eq "$LMF_RC" "1"
assert_eq "$(ls -A "$LMF_TMPDIR")" ""
case_end

case_begin "lmf-hook-line-wired" "hooks/pre-commit"
# #2507: the gate runs right after the case-marker gate in the Node tests-frontmatter check.
gates_line="$(grep -E '^const GATES = ' "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/tests-frontmatter.js")"
assert_eq "$gates_line" "const GATES = [frontmatter, caseMarkers, languageMatch];"
case_end

unset R LMF_TMPDIR LMF_BAD LMF_GOOD

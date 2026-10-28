# Part F — staged language-match gate _precommit_check_test_language_match (#2502 S4-7),
# and the --rel the case-marker gate now passes (#2502 S3-0).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals
# (TMPBASE, init_fixture, cm_repo, CM_BODIES, PRECOMMIT, pass/fail/assert_eq).
# The checkers are stubs that log what they were given, so these cases pin the call contract
# (arguments, staged vs HEAD blob, rc handling); the verdicts are pinned by
# tests/bin/feature-2502-test-language-match.sh.

echo ""
echo "=== Part F: staged language-match gate (#2502) ==="

# LMF_CFG — a fixture agents main root: the test language registry plus two stub checkers.
LMF_CFG="$TMPBASE/lmf-cfg"
mkdir -p "$LMF_CFG/bin"
install_test_language_registry "$LMF_CFG" "$SCRIPT_CHECKOUT_ROOT"
# Each stub appends one line per argument to $LMF_LOG (file arguments as their basename and
# first line), prints $LMF_STUB_OUT and exits $LMF_STUB_RC.
printf '%s\n' '#!/usr/bin/env bash' \
    'while [ $# -gt 0 ]; do' \
    '  case "$1" in' \
    '    --rel) printf "rel=%s\n" "$2" >> "$LMF_LOG"; shift 2 ;;' \
    '    --head) printf "head=%s headbase=%s\n" "$(head -n 1 "$2")" "${2##*/}" >> "$LMF_LOG"; shift 2 ;;' \
    '    *) printf "work=%s workbase=%s\n" "$(head -n 1 "$1")" "${1##*/}" >> "$LMF_LOG"; shift ;;' \
    '  esac' \
    'done' \
    '[ -n "${LMF_STUB_OUT:-}" ] && printf "%s\n" "$LMF_STUB_OUT"' \
    'exit "${LMF_STUB_RC:-0}"' > "$LMF_CFG/bin/check-test-language-match.sh"
cp "$LMF_CFG/bin/check-test-language-match.sh" "$LMF_CFG/bin/check-case-markers.sh"

LMF_LOG="$TMPBASE/lmf.log"
LMF_OUT=""; LMF_ERR=""; LMF_RC=0
LMF_STUB_RC=0; LMF_STUB_OUT=""

# run_lmf <repo> [function] — call the gate (default _precommit_check_test_language_match)
# in a subshell with the fixture as CWD and LMF_CFG as the agents main root.
run_lmf() {
    local repo="$1" fn="${2:-_precommit_check_test_language_match}"
    : > "$LMF_LOG"
    if ! declare -F "$fn" >/dev/null 2>&1; then
        LMF_RC=127; LMF_OUT=""
        LMF_ERR="IMPLEMENTATION MISSING: $fn"
        return 0
    fi
    LMF_RC=0
    (
        cd "$repo" || exit 99
        export LMF_LOG LMF_STUB_RC LMF_STUB_OUT
        [ -n "${LMF_TMPDIR:-}" ] && export TMPDIR="$LMF_TMPDIR"
        _cfg_dir="$LMF_CFG"
        "$fn"
    ) >"$TMPBASE/lmf.out" 2>"$TMPBASE/lmf.err" || LMF_RC=$?
    LMF_OUT="$(cat "$TMPBASE/lmf.out")"
    LMF_ERR="$(cat "$TMPBASE/lmf.err")"
}

# lmf_put <repo> <rel> <first-line> — a one-line file in the working tree.
lmf_put() {
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
}
lmf_stage() {
    lmf_put "$1" "$2" "$3"
    git -C "$1" add -- "$2" >/dev/null 2>&1
}

# lmf_log_has <label> <fixed-line> / lmf_log_lacks <label> <fixed-prefix>
lmf_log_has() {
    grep -qxF -- "$2" "$LMF_LOG" \
        && pass "$1: checker got [$2]" \
        || fail "$1: checker args" "want line [$2] in log=[$(cat "$LMF_LOG")] err=[$LMF_ERR]"
}
lmf_log_lacks() {
    grep -qF -- "$2" "$LMF_LOG" \
        && fail "$1: checker args" "must not get [$2]: log=[$(cat "$LMF_LOG")]" \
        || pass "$1: checker did not get [$2]"
}

case_begin "lmf-new-file-gets-rel-and-no-head" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-new)"
lmf_stage "$R" tests/hooks/n.sh "echo staged-new"
run_lmf "$R"
assert_eq "$LMF_RC" "0"
lmf_log_has "lmf-new-file" "rel=tests/hooks/n.sh"
lmf_log_has "lmf-new-file" "work=echo staged-new workbase=n.sh"
lmf_log_lacks "lmf-new-file" "head="
case_end

case_begin "lmf-existing-file-gets-the-head-copy" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-existing)"
lmf_stage "$R" tests/hooks/e.sh "echo in-head"
git -C "$R" commit -q -m e >/dev/null 2>&1
lmf_stage "$R" tests/hooks/e.sh "echo staged-edit"
run_lmf "$R"
assert_eq "$LMF_RC" "0"
lmf_log_has "lmf-existing-file" "rel=tests/hooks/e.sh"
lmf_log_has "lmf-existing-file" "head=echo in-head headbase=e.sh"
lmf_log_has "lmf-existing-file" "work=echo staged-edit workbase=e.sh"
case_end

case_begin "lmf-partial-stage-judges-the-staged-blob" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-partial)"
lmf_stage "$R" tests/hooks/p.sh "echo staged-blob"
lmf_put "$R" tests/hooks/p.sh "echo working-tree"
run_lmf "$R"
lmf_log_has "lmf-partial-stage" "work=echo staged-blob workbase=p.sh"
lmf_log_lacks "lmf-partial-stage" "working-tree"
case_end

case_begin "lmf-unregistered-tests-file-is-checked" "hooks/lib/precommit-tests-frontmatter.sh"
# A tests/ file no registry entry matches still reaches the checker, which answers WARN.
R="$(cm_repo lmf-unreg)"
lmf_stage "$R" tests/hooks/x.rb "puts 1"
run_lmf "$R"
lmf_log_has "lmf-unregistered" "rel=tests/hooks/x.rb"
case_end

case_begin "lmf-deleted-file-ignored" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-deleted)"
lmf_stage "$R" tests/hooks/gone.sh "echo gone"
git -C "$R" commit -q -m gone >/dev/null 2>&1
git -C "$R" rm -q tests/hooks/gone.sh
run_lmf "$R"
assert_eq "$LMF_RC" "0"
lmf_log_lacks "lmf-deleted" "gone.sh"
case_end

case_begin "lmf-rc1-blocks-with-the-high-line" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-rc1)"
lmf_stage "$R" tests/hooks/n.sh "echo staged-new"
LMF_STUB_RC=1
LMF_STUB_OUT="HIGH: tests/hooks/n.sh: test language bash does not match code language js of bin/foo.js (new file shape: <name>.js) code=TEST_LANGUAGE_MISMATCH"
run_lmf "$R"
assert_eq "$LMF_RC" "1"
printf '%s\n%s\n' "$LMF_OUT" "$LMF_ERR" | grep -qxF -- "$LMF_STUB_OUT" \
    && pass "lmf-rc1: HIGH line shown" \
    || fail "lmf-rc1: HIGH line" "out=[$LMF_OUT] err=[$LMF_ERR]"
LMF_STUB_RC=0; LMF_STUB_OUT=""
case_end

case_begin "lmf-rc0-warn-passes-and-is-shown" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-warn)"
lmf_stage "$R" tests/hooks/x.rb "puts 1"
LMF_STUB_OUT="WARN: tests/hooks/x.rb: test language not registered code=TEST_LANGUAGE_UNSUPPORTED"
run_lmf "$R"
assert_eq "$LMF_RC" "0"
printf '%s\n%s\n' "$LMF_OUT" "$LMF_ERR" | grep -qF 'code=TEST_LANGUAGE_UNSUPPORTED' \
    && pass "lmf-rc0-warn: WARN shown" \
    || fail "lmf-rc0-warn: WARN" "out=[$LMF_OUT] err=[$LMF_ERR]"
LMF_STUB_OUT=""
case_end

case_begin "lmf-rc2-continues-with-a-diagnostic" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-rc2)"
lmf_stage "$R" tests/hooks/n.sh "echo staged-new"
LMF_STUB_RC=2
run_lmf "$R"
assert_eq "$LMF_RC" "0"
printf '%s\n' "$LMF_ERR" | grep -Eq 'rc=2 for tests/hooks/n\.sh .*check incomplete \(commit continues\)' \
    && pass "lmf-rc2: diagnostic on stderr" \
    || fail "lmf-rc2: diagnostic" "err=[$LMF_ERR]"
LMF_STUB_RC=0
case_end

case_begin "lmf-tmpdir-cleaned" "hooks/lib/precommit-tests-frontmatter.sh"
R="$(cm_repo lmf-tmpclean)"
lmf_stage "$R" tests/hooks/n.sh "echo staged-new"
lmf_stage "$R" tests/hooks/e.sh "echo second"
LMF_TMPDIR="$TMPBASE/lmf-tmpdir"
mkdir -p "$LMF_TMPDIR"
run_lmf "$R"
assert_eq "$(ls -A "$LMF_TMPDIR")" ""
LMF_TMPDIR=""
case_end

case_begin "lmf-hook-line-wired" "hooks/pre-commit"
# The call sits on the line right after the case-marker gate call.
cm_ln="$(grep -n '^[[:space:]]*_precommit_check_tests_case_markers || exit 1[[:space:]]*$' "$PRECOMMIT" | head -n 1 | cut -d: -f1)"
next_line=""
[ -n "$cm_ln" ] && next_line="$(sed -n "$((cm_ln + 1))p" "$PRECOMMIT" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
assert_eq "$next_line" "_precommit_check_test_language_match || exit 1"
case_end

case_begin "lmf-case-marker-gate-passes-rel" "hooks/lib/precommit-tests-frontmatter.sh"
# The case-marker gate hands its checker the repo-relative path next to the temp copy.
R="$(cm_repo lmf-cm-rel)"
cm_stage "$R" tests/hooks/new-missing.sh missing.sh
run_lmf "$R" _precommit_check_tests_case_markers
lmf_log_has "lmf-case-marker-rel" "rel=tests/hooks/new-missing.sh"
lmf_log_has "lmf-case-marker-rel" "work=#!/usr/bin/env bash workbase=new-missing.sh"
case_end

unset R cm_ln next_line LMF_TMPDIR

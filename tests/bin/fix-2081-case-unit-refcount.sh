#!/usr/bin/env bash
# tests/bin/fix-2081-case-unit-refcount.sh
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/case-parser.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# TL2 contract for #2081 (case-unit refcount GC) + #1864 (.ps1/.py scan). A
# case_begin/case_end pair is one case; refcount = surviving cases; refcount==0
# → whole-unit GC, refcount>0+orphan → case-block removal, marker-less → the
# current file-level trp_survival_verdict fallback. Fail-before-fix: parser and
# new fns absent, so direct-call groups short-circuit (require_fn) and audit
# groups assert OLD behavior. TL3 gap: no real gh api/cron/scale — mitigated at
# WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh).

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-2081-case-unit-refcount"
# The #1833 gh-stub helper is standalone-sourceable and reused verbatim.
GH_STUBS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-1833-audit-tests-survival-first/helpers-gh-stubs.sh"
AUDIT="${AUDIT_TESTS_BIN:-$AGENTS_ROOT/bin/audit-tests.sh}"
AUDIT_COMMON="${AUDIT_TESTS_COMMON_BIN:-$AGENTS_ROOT/bin/audit-tests-common.sh}"
RETIRE_LIB="$AGENTS_ROOT/bin/lib/test-retire-predicate.sh"
CASE_PARSER="$AGENTS_ROOT/bin/lib/test-retire-predicate/case-parser.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() { bash "$AGENTS_ROOT/bin/run-with-timeout.sh" 120 "$@"; }
GH_TIMEOUT_PIN=30

# ── gh stubs (reused from #1833) ────────────────────────────────────────────
if [[ -f "$GH_STUBS" ]]; then
    # shellcheck source=fix-1833-audit-tests-survival-first/helpers-gh-stubs.sh
    . "$GH_STUBS"
else
    fail "precondition: #1833 gh-stub helper not found at $GH_STUBS"
    install_gh_mock() { :; }
fi

# ── The predicate module under test ─────────────────────────────────────────
# Sourced into THIS shell (not a subshell) so the new functions' TRP_* output
# globals are readable by the direct-call groups; require_fn() detects absence.
if [[ -f "$RETIRE_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$RETIRE_LIB" 2>/dev/null || true
fi

# ── Preconditions (documented pre-implementation state) ─────────────────────
if [[ -f "$CASE_PARSER" ]]; then
    pass "P1 case-parser sibling bin/lib/test-retire-predicate/case-parser.sh exists"
else
    fail "P1 case-parser sibling missing — NOTE: passes after write-code step"
fi
for _p_fn in trp_enumerate_cases trp_case_refcount_verdict trp_remove_orphan_cases; do
    if declare -F "$_p_fn" >/dev/null 2>&1; then
        pass "P2 predicate defines $_p_fn"
    else
        fail "P2 predicate does not define $_p_fn yet — NOTE: passes after write-code step"
    fi
done
unset _p_fn

# require_fn <fn> <group-label> — 0 when defined; else records ONE
# pre-implementation FAIL and returns 1 so the group `return`s.
require_fn() {
    if declare -F "$1" >/dev/null 2>&1; then return 0; fi
    fail "$2: $1 not defined yet — NOTE: passes after write-code step"
    return 1
}

# ── Fixture builders ────────────────────────────────────────────────────────

# make_repo — throwaway git repo with tests/ and bin/. Echoes its root.
make_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_BASE")"
    git -C "$root" init -q
    git -C "$root" config core.hooksPath /dev/null
    git -C "$root" config core.autocrlf false
    git -C "$root" config user.email "t@example.com"
    git -C "$root" config user.name "t"
    mkdir -p "$root/tests" "$root/bin"
    printf 'init\n' > "$root/README.md"
    echo "$root"
}

# add_src <root> <relpath> — creates a real (alive) target path.
add_src() {
    local root="$1" rel="$2"
    mkdir -p "$root/$(dirname "$rel")"
    printf '#!/usr/bin/env bash\necho src\n' > "$root/$rel"
}

# add_raw <root> <name> — file body read from stdin verbatim, so a fixture can
# carry arbitrary case_begin/case_end markers (valid or malformed).
add_raw() {
    local root="$1" name="$2"
    mkdir -p "$(dirname "$root/tests/$name")"
    cat > "$root/tests/$name"
}

# add_test_file <root> <name> <tests-header> [tags] — marker-LESS `# Tests:`
# file (the fallback shape), matching the #1833 helper of the same name.
add_test_file() {
    local root="$1" name="$2" hdr="$3" tags="${4:-TL2, scope:common}"
    mkdir -p "$(dirname "$root/tests/$name")"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Tests: %s\n' "$hdr"
        printf '# Tags: %s\n' "$tags"
        printf 'echo fixture\n'
    } > "$root/tests/$name"
}

commit_repo() {
    local root="$1" msg="${2:-fixture}"
    git -C "$root" add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
        git -C "$root" commit -q --no-verify -m "$msg" >/dev/null 2>&1
}

# ── Direct-call drivers (globals must survive → never a subshell) ────────────

# run_enum <repo> <rel> — cd into the repo (mirrors the audit scripts) and
# enumerate the file's cases.
run_enum() {
    local repo="$1" rel="$2" saved="$PWD"
    cd "$repo" 2>/dev/null || return 2
    trp_enumerate_cases "$repo" "$rel"
    local rc=$?
    cd "$saved" 2>/dev/null || true
    return $rc
}

# run_verdict <repo> <rel> — top-level refcount verdict; sets TRP_VERDICT,
# TRP_REFCOUNT, TRP_UNIT_MODE.
run_verdict() {
    local repo="$1" rel="$2" saved="$PWD"
    cd "$repo" 2>/dev/null || return 2
    trp_case_refcount_verdict "$repo" "$rel" >/dev/null 2>&1
    local rc=$?
    cd "$saved" 2>/dev/null || true
    return $rc
}

# join_sp <elem...> — space-joined args (call as join_sp "${ARR[@]:-}").
join_sp() {
    local IFS=' '
    echo "$*"
}

# ── Text-report readers (audit-script groups) ───────────────────────────────

re_escape() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|/]/\\&/g'; }

line_has() {
    local out="$1" token="$2" rel="$3"
    printf '%s\n' "$out" | grep -qE "^${token}: $(re_escape "$rel")([[:space:]:].*)?$"
}

count_lines() {
    printf '%s\n' "$1" | grep -cE "^$2: " || true
}

fs_of() {
    if [[ -e "$1/$2" ]]; then echo kept; else echo gone; fi
}

# run_in_repo <root> <stubdir|-> <script> [args...] — sets OUT / ERR / RC.
run_in_repo() {
    local root="$1" stubdir="$2" script="$3"; shift 3
    local outf errf pathpfx=""
    outf="$(mktemp)"; errf="$(mktemp)"
    [[ "$stubdir" != "-" ]] && pathpfx="$stubdir:"
    (
        cd "$root" || exit 2
        PATH="${pathpfx}$PATH" MOCK_ISSUES="${MOCK_ISSUES:-}" \
            GH_TIMEOUT="$GH_TIMEOUT_PIN" \
            run_with_timeout bash "$script" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

# ── Preconditions ───────────────────────────────────────────────────────────
if [[ ! -f "$AUDIT" ]]; then fail "precondition: bin/audit-tests.sh missing at $AUDIT"; fi
if [[ ! -f "$AUDIT_COMMON" ]]; then fail "precondition: bin/audit-tests-common.sh missing at $AUDIT_COMMON"; fi

# ── Group dispatch ──────────────────────────────────────────────────────────
for _g in a b c d e f g h i j k l m n o; do
    _gf="$GROUP_DIR/group-$_g.sh"
    if [[ -f "$_gf" ]]; then
        # shellcheck source=/dev/null
        . "$_gf"
    else
        fail "dispatch: group file missing: group-$_g.sh"
    fi
done
unset _g _gf

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

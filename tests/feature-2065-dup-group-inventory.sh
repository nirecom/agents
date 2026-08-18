#!/usr/bin/env bash
# tests/feature-2065-dup-group-inventory.sh
# Tests: bin/lib/test-dup-group.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh, bin/lib/test-retire-predicate.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, scope:issue-specific, audit-tests, dup-groups, frontmatter, parser, tsv, escaping
# Dispatcher: shared harness only. Cases live in the sibling folder of the same name.
# TL2 contract for #2065: the shared `# Tests:` parser extraction (S1) and the
# read-only `--dup-groups` mode (S2/S3) on both audit entrypoints. Guard cases
# assert the SPECIFIC guard message, so a regression to "unknown argument" exit 2
# cannot green them for the wrong reason.
# TL3 gap — skill/nightly-sweep orchestration over the live corpus: checked at
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2065-dup-group-inventory"
AUDIT="${AUDIT_TESTS_BIN:-$AGENTS_ROOT/bin/audit-tests.sh}"
AUDIT_COMMON="${AUDIT_TESTS_COMMON_BIN:-$AGENTS_ROOT/bin/audit-tests-common.sh}"
DUP_LIB="$AGENTS_ROOT/bin/lib/test-dup-group.sh"
FM_CONST="$AGENTS_ROOT/bin/lib/test-frontmatter-constants.sh"
FM_FIX="$AGENTS_ROOT/bin/lib/test-frontmatter-fix.sh"
RETIRE_LIB="$AGENTS_ROOT/bin/lib/test-retire-predicate.sh"
FM_CHECK="$AGENTS_ROOT/bin/check-test-frontmatter.sh"

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

# assert_eq — table-driven assertion helper (skills/_shared/test-design/parser-regex-tests.md).
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

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin the workflow dirs
# and drop the parent session ids so no child resolves the live session.
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Neutral CWD for the "outside any git repository" cases (never a git repo).
NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

run_with_timeout() { bash "$AGENTS_ROOT/bin/run-with-timeout.sh" 120 "$@"; }

# Platform probe — the backslash-filename case is POSIX-only.
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) IS_POSIX_FS=0 ;;
    *) IS_POSIX_FS=1 ;;
esac

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

# add_test_file <root> <relname-under-tests> <tests-header-value> [tags]
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

# add_test_file_raw <root> <relname-under-tests> — body read verbatim from stdin.
# Used by structural cases needing control over line numbers and header count.
add_test_file_raw() {
    local root="$1" name="$2"
    mkdir -p "$(dirname "$root/tests/$name")"
    cat > "$root/tests/$name"
}

# add_src <root> <relpath> — creates a real (alive) target path.
add_src() {
    local root="$1" rel="$2"
    mkdir -p "$root/$(dirname "$rel")"
    printf '#!/usr/bin/env bash\necho src\n' > "$root/$rel"
}

# commit_repo <root> [msg]
commit_repo() {
    local root="$1" msg="${2:-fixture}"
    git -C "$root" add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
        git -C "$root" commit -q --no-verify -m "$msg" >/dev/null 2>&1
}

# ── Runners (all set OUT / ERR / RC) ────────────────────────────────────────

# run_in_repo <root> <script> [args...]
run_in_repo() {
    local root="$1" script="$2"; shift 2
    local outf errf
    outf="$(mktemp)"; errf="$(mktemp)"
    (
        cd "$root" || exit 2
        GH_TIMEOUT=30 run_with_timeout bash "$script" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

# run_dup <root> <script> [extra-args...] — the mode under test.
run_dup() { local root="$1" script="$2"; shift 2; run_in_repo "$root" "$script" --dup-groups "$@"; }

# run_no_repo <script> [args...] — CWD is a non-repo dir, no GIT_DIR exported.
run_no_repo() {
    local script="$1"; shift
    local outf errf
    outf="$(mktemp)"; errf="$(mktemp)"
    (
        cd "$NEUTRAL_DIR" || exit 2
        unset GIT_DIR GIT_WORK_TREE
        GH_TIMEOUT=30 run_with_timeout bash "$script" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

# Completion ledger: every case file's LAST line is `grp_done <its own basename>`.
# The `.` exit status cannot stand in for this — a bare `return` yields the status
# of the last command run, so a file that bails after its fixture setup still
# sources "successfully" while its whole case family silently disappears.
GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1
"; }

# ── Assertion harness (TSV reader, escape codec, verdict extractors) ────────
# shellcheck source=feature-2065-dup-group-inventory/harness-tsv-reader.sh
. "$GROUP_DIR/harness-tsv-reader.sh"

# ── Preconditions ───────────────────────────────────────────────────────────

for _p in "$AUDIT:bin/audit-tests.sh" "$AUDIT_COMMON:bin/audit-tests-common.sh" \
          "$FM_CONST:bin/lib/test-frontmatter-constants.sh" "$FM_FIX:bin/lib/test-frontmatter-fix.sh" \
          "$RETIRE_LIB:bin/lib/test-retire-predicate.sh" "$FM_CHECK:bin/check-test-frontmatter.sh"; do
    if [[ -f "${_p%%:*}" ]]; then pass "P0 ${_p#*:} exists"; else fail "P0 ${_p#*:} missing at ${_p%%:*}"; fi
done

# P1 — the new shared grouping library (S2). Absent until /write-code lands it.
if [[ -f "$DUP_LIB" ]]; then
    pass "P1 shared grouping library bin/lib/test-dup-group.sh exists"
else
    fail "P1 shared grouping library bin/lib/test-dup-group.sh missing (not implemented yet)"
fi

# P2 — the header-position contract constant (S1-1) is the SSOT the classifier
# keys on. Read it out of the constants file rather than assuming the value.
if grep -qE '^[[:space:]]*FRONTMATTER_HEADER_MAX_LINE=10([[:space:]]|$)' "$FM_CONST" 2>/dev/null; then
    pass "P2 FRONTMATTER_HEADER_MAX_LINE=10 is defined in test-frontmatter-constants.sh"
else
    fail "P2 FRONTMATTER_HEADER_MAX_LINE=10 not defined in $FM_CONST (not implemented yet)"
fi

# shellcheck source=feature-2065-dup-group-inventory/golden-comparison.sh
. "$GROUP_DIR/golden-comparison.sh"
# shellcheck source=feature-2065-dup-group-inventory/token-parsing-equivalence.sh
. "$GROUP_DIR/token-parsing-equivalence.sh"
# shellcheck source=feature-2065-dup-group-inventory/structural-inspection.sh
. "$GROUP_DIR/structural-inspection.sh"
# shellcheck source=feature-2065-dup-group-inventory/flag-defaults.sh
. "$GROUP_DIR/flag-defaults.sh"
# shellcheck source=feature-2065-dup-group-inventory/normal-cases.sh
. "$GROUP_DIR/normal-cases.sh"
# shellcheck source=feature-2065-dup-group-inventory/error-cases.sh
. "$GROUP_DIR/error-cases.sh"
# shellcheck source=feature-2065-dup-group-inventory/contract-cases.sh
. "$GROUP_DIR/contract-cases.sh"
# shellcheck source=feature-2065-dup-group-inventory/escaping-hostile-names.sh
. "$GROUP_DIR/escaping-hostile-names.sh"
# shellcheck source=feature-2065-dup-group-inventory/verdict-coverage.sh
. "$GROUP_DIR/verdict-coverage.sh"

# ── Case-file set integrity ─────────────────────────────────────────────────
# The `. "$GROUP_DIR/…"` lines above are the only wiring a case file has, so a
# dropped line removes a whole behavioural family with the suite still green.
GRP_PRESENT="$(ls -1 "$GROUP_DIR" 2>/dev/null | grep '\.sh$' | sort)"
GRP_SOURCED="$(sed -n 's|^\. "\$GROUP_DIR/\(.*\.sh\)"$|\1|p' "${BASH_SOURCE[0]}" | sort)"

grp_only_in_first() {
    comm -23 <(printf '%s\n' "$1" | grep -v '^$') <(printf '%s\n' "$2" | grep -v '^$') \
        | tr '\n' ' ' | sed 's/ *$//'
}
GRP_UNSOURCED="$(grp_only_in_first "$GRP_PRESENT" "$GRP_SOURCED")"
GRP_ABSENT="$(grp_only_in_first "$GRP_SOURCED" "$GRP_PRESENT")"

if [[ -z "$GRP_UNSOURCED" && -z "$GRP_ABSENT" ]]; then
    pass "GRP1 every case file is sourced and every sourced case file exists"
else
    fail "GRP1 case file set mismatch — present-but-unsourced: [${GRP_UNSOURCED:-none}] sourced-but-missing: [${GRP_ABSENT:-none}]"
fi

# GRP1 only proves the two NAME lists agree; it passes while a case file returns
# early or fails to source. The ledger is what proves each one reached its end.
GRP_DONE_SORTED="$(printf '%s' "$GRP_DONE" | sort)"
GRP_UNFINISHED="$(grp_only_in_first "$GRP_SOURCED" "$GRP_DONE_SORTED")"
GRP_UNEXPECTED="$(grp_only_in_first "$GRP_DONE_SORTED" "$GRP_SOURCED")"

if [[ -z "$GRP_UNFINISHED" && -z "$GRP_UNEXPECTED" ]]; then
    pass "GRP2 every sourced case file ran through to its completion marker"
else
    fail "GRP2 case file completion mismatch — sourced-but-unfinished: [${GRP_UNFINISHED:-none}] marked-but-not-sourced: [${GRP_UNEXPECTED:-none}]"
fi

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

#!/usr/bin/env bash
# tests/fix-1833-audit-tests-survival-first.sh
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
#
# TL2 contract test for #1833 — the retire-candidate PRIMARY FILTER moves from
# "issue CLOSED + closed_at older than N months" to "every `# Tests:` token's
# target is gone (format-OK, missing, no rename)". Issue state is demoted to a
# DELETE-TIME safety check that can hold a deletion but can never create or
# suppress a candidate.
#
# Fail-before-fix (BUGFIX session): bin/lib/test-retire-predicate.sh does not
# exist yet and neither script implements the inverted order, so most cases here
# are EXPECTED TO FAIL until the fix lands.
#
# Everything runs against throwaway git fixture repos under $TMPDIR_BASE with a
# `gh` PATH stub; the real tests/ tree and the real GitHub API are never inputs.
#
# TL3 gap (what this test does NOT catch):
# - Real `gh api` transport, auth, rate-limiting and 404-from-another-repo
#   behavior: the stub always answers instantly and locally.
# - Real `gh repo view` slug resolution against github.com.
# - The nightly GitHub Actions cron actually running both scripts on a runner
#   (sweep.yml is grepped, not executed).
# - Real-scale `find_renamed_path` cost over a multi-thousand-commit history.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-1833-audit-tests-survival-first"
AUDIT="${AUDIT_TESTS_BIN:-$AGENTS_ROOT/bin/audit-tests.sh}"
AUDIT_COMMON="${AUDIT_TESTS_COMMON_BIN:-$AGENTS_ROOT/bin/audit-tests-common.sh}"
SWEEP_YML="$AGENTS_ROOT/.github/workflows/sweep.yml"
RETIRE_LIB="$AGENTS_ROOT/bin/lib/test-retire-predicate.sh"
# Worktree copy (the state under test), never the deployed $HOME/.claude/ copy.
LOCAL_SKILL_MD="$AGENTS_ROOT/skills/sweep-tests/SKILL.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

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

# Neutral CWD used by the repo-outside cases (never a git repo).
NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

run_with_timeout() { bash "$AGENTS_ROOT/bin/run-with-timeout.sh" 120 "$@"; }

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

# add_test_file <root> <name> <tests-header-value> [tags]
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

# add_test_file_nohdr <root> <name> — no `# Tests:` line at all.
add_test_file_nohdr() {
    local root="$1" name="$2"
    mkdir -p "$(dirname "$root/tests/$name")"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Tags: TL2, scope:common\n'
        printf 'echo fixture\n'
    } > "$root/tests/$name"
}

# add_test_file_emptyhdr <root> <name> — `# Tests:` present but with no value.
add_test_file_emptyhdr() {
    local root="$1" name="$2"
    mkdir -p "$(dirname "$root/tests/$name")"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Tests:\n'
        printf '# Tags: TL2, scope:common\n'
        printf 'echo fixture\n'
    } > "$root/tests/$name"
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

# ── gh stubs ────────────────────────────────────────────────────────────────
# install_gh_mock / _api_fails / _repo_view_fails / _slow live in the helper
# file below, so the dispatcher stays a harness rather than a stub library.
# shellcheck source=fix-1833-audit-tests-survival-first/helpers-gh-stubs.sh
. "$GROUP_DIR/helpers-gh-stubs.sh"

# ── Runners ─────────────────────────────────────────────────────────────────
# All runners set OUT / ERR / RC.

# GH_TIMEOUT is a config-dependent branch input (bin/audit-tests.sh reads it as
# `GH_TIMEOUT="${GH_TIMEOUT:-30}"`). Per skills/_shared/test-design.md every
# branch under test must PIN it rather than inherit whatever the developer's
# shell or .env happens to carry — an ambient `GH_TIMEOUT=1` would silently turn
# every online case into a metadata-unavailable case and green the suite for the
# wrong reason. Every runner below exports $GH_TIMEOUT_PIN; the short-timeout
# case in group M overrides it per-call (`GH_TIMEOUT_PIN=1 run_in_repo ...`).
GH_TIMEOUT_PIN=30

# run_in_repo <root> <stubdir|-> <script> [args...]
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

# path_without_gh — $PATH with every directory that provides an executable `gh`
# removed. Used to reproduce "the gh CLI is not installed on this host", which is
# a DIFFERENT branch from "gh exists and returns non-zero": the former never
# reaches the CLI at all, so a `command -v gh` guard is what has to fire.
# Split with `tr`, not `read -ra <<<`: $PATH can legitimately contain a newline
# (a shell profile that exports a multi-line value), and `read` stops at the
# first one — which would silently reduce the sanitized PATH to its first
# element and strip bash itself. That failure looks exactly like "the script
# crashed without gh", i.e. it would green M1 for the wrong reason.
path_without_gh() {
    local out="" d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        [[ -x "$d/gh" || -x "$d/gh.exe" || -x "$d/gh.cmd" || -x "$d/gh.bat" ]] && continue
        out="${out:+$out:}$d"
    done < <(printf '%s' "$PATH" | tr ':' '\n')
    printf '%s' "$out"
}

# run_in_repo_with_path <root> <path> <script> [args...] — like run_in_repo but
# the PATH is stated outright instead of prefixed onto the inherited one.
run_in_repo_with_path() {
    local root="$1" newpath="$2" script="$3"; shift 3
    local outf errf
    outf="$(mktemp)"; errf="$(mktemp)"
    (
        cd "$root" || exit 2
        PATH="$newpath" MOCK_ISSUES="${MOCK_ISSUES:-}" \
            GH_TIMEOUT="$GH_TIMEOUT_PIN" \
            run_with_timeout bash "$script" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

# run_outside_repo <root> <stubdir|-> <script> [args...]
# CWD is a non-repo temp dir; the repo is designated via GIT_DIR/GIT_WORK_TREE
# so `git rev-parse --show-toplevel` still resolves it. This is the shape that
# exposes a CWD-relative `[[ -e ]]` existence check.
run_outside_repo() {
    local root="$1" stubdir="$2" script="$3"; shift 3
    local outf errf pathpfx=""
    outf="$(mktemp)"; errf="$(mktemp)"
    [[ "$stubdir" != "-" ]] && pathpfx="$stubdir:"
    (
        cd "$NEUTRAL_DIR" || exit 2
        PATH="${pathpfx}$PATH" MOCK_ISSUES="${MOCK_ISSUES:-}" \
            GH_TIMEOUT="$GH_TIMEOUT_PIN" \
            GIT_DIR="$root/.git" GIT_WORK_TREE="$root" \
            run_with_timeout bash "$script" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

# run_no_repo <stubdir|-> <script> [args...] — CWD is a non-repo dir and no
# GIT_DIR is exported, so repo-root resolution must fail closed.
run_no_repo() {
    local stubdir="$1" script="$2"; shift 2
    local outf errf pathpfx=""
    outf="$(mktemp)"; errf="$(mktemp)"
    [[ "$stubdir" != "-" ]] && pathpfx="$stubdir:"
    (
        cd "$NEUTRAL_DIR" || exit 2
        unset GIT_DIR GIT_WORK_TREE
        PATH="${pathpfx}$PATH" GH_TIMEOUT="$GH_TIMEOUT_PIN" \
            run_with_timeout bash "$script" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

# ── Assertion helpers ───────────────────────────────────────────────────────

# json_query <json> <node-expression-body> — runs node with `d` bound to the
# parsed document; exits non-zero when the document does not parse.
json_query() {
    local doc="$1" expr="$2"
    printf '%s' "$doc" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            let d;
            try { d = JSON.parse(b); } catch (e) { process.exit(3); }
            try { process.stdout.write(String(($expr))); } catch (e) { process.exit(4); }
        });
    " 2>/dev/null
}

json_parses() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            try { JSON.parse(b); } catch (e) { process.exit(1); }
        });
    " >/dev/null 2>&1
}

# ── Verdict extractors (feed the table-driven matrices in groups A/B/G) ─────
# Both scripts report one verdict line per file. The extractors turn a whole
# text report into a single token per file so a matrix row can state the
# expected verdict directly instead of open-coding a grep per assertion.

re_escape() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|/]/\\&/g'; }

# line_has <output> <TOKEN> <relpath> — a "TOKEN: relpath" line (trailing text ok)
line_has() {
    local out="$1" token="$2" rel="$3"
    printf '%s\n' "$out" | grep -qE "^${token}: $(re_escape "$rel")([[:space:]].*)?$"
}

# report_of <output> <relpath> -> candidate|orphan|malformed|no-header|none
report_of() {
    local out="$1" rel="$2"
    line_has "$out" CANDIDATE "$rel" && { echo candidate; return 0; }
    line_has "$out" ORPHAN "$rel" && { echo orphan; return 0; }
    line_has "$out" MALFORMED_HEADER "$rel" && { echo malformed; return 0; }
    line_has "$out" NO_TESTS_HEADER "$rel" && { echo no-header; return 0; }
    echo none
}

# gate_of <output> <relpath> -> deleted|issue-active|metadata-unavailable|ambiguous-ref|none
gate_of() {
    local out="$1" rel="$2"
    line_has "$out" DELETED "$rel" && { echo deleted; return 0; }
    line_has "$out" SKIP_DELETE_ISSUE_ACTIVE "$rel" && { echo issue-active; return 0; }
    line_has "$out" SKIP_DELETE_METADATA_UNAVAILABLE "$rel" && { echo metadata-unavailable; return 0; }
    line_has "$out" SKIP_DELETE_AMBIGUOUS_REF "$rel" && { echo ambiguous-ref; return 0; }
    echo none
}

# fs_of <root> <relpath> -> gone|kept  (ground truth, independent of the report)
fs_of() {
    if [[ -e "$1/$2" ]]; then echo kept; else echo gone; fi
}

# count_lines <output> <TOKEN> — how many "TOKEN: " lines the report carries
count_lines() {
    printf '%s\n' "$1" | grep -cE "^$2: " || true
}

# assert_gate_row — one matrix row = three coupled facts about one file: the
# report verdict, the delete-gate verdict, and the file's real fate on disk.
# Asserting all three together is what stops a "reported but silently kept" or
# "held in the report but actually deleted" divergence from passing.
assert_gate_row() {
    local label="$1" out="$2" root="$3" rel="$4" want_report="$5" want_gate="$6" want_fs="$7"
    assert_eq "$label" \
        "report=$want_report gate=$want_gate fs=$want_fs" \
        "report=$(report_of "$out" "$rel") gate=$(gate_of "$out" "$rel") fs=$(fs_of "$root" "$rel")"
}

# run_gate_table <label-prefix> <output> <root> — reads `name|file|report|gate|fs`
# rows on stdin; blank and `#` rows are skipped.
run_gate_table() {
    local prefix="$1" out="$2" root="$3"
    local name file want_report want_gate want_fs
    while IFS='|' read -r name file want_report want_gate want_fs; do
        [[ -z "${name//[[:space:]]/}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
        want_report="${want_report//[[:space:]]/}"
        want_gate="${want_gate//[[:space:]]/}"
        want_fs="${want_fs//[[:space:]]/}"
        assert_gate_row "$prefix[$name]" "$out" "$root" "tests/$file" \
            "$want_report" "$want_gate" "$want_fs"
    done
}

# ── Preconditions ───────────────────────────────────────────────────────────

if [[ ! -f "$AUDIT" ]]; then
    fail "precondition: bin/audit-tests.sh not found at $AUDIT"
fi
if [[ ! -f "$AUDIT_COMMON" ]]; then
    fail "precondition: bin/audit-tests-common.sh not found at $AUDIT_COMMON"
fi

# The shared predicate module is the SSOT the two scripts must both source.
if [[ -f "$RETIRE_LIB" ]]; then
    pass "P1 shared predicate module bin/lib/test-retire-predicate.sh exists"
else
    fail "P1 shared predicate module bin/lib/test-retire-predicate.sh missing (not implemented yet)"
fi

# shellcheck source=fix-1833-audit-tests-survival-first/group-a-primary-filter.sh
. "$GROUP_DIR/group-a-primary-filter.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-b-delete-gate.sh
. "$GROUP_DIR/group-b-delete-gate.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-c-cwd-independence.sh
. "$GROUP_DIR/group-c-cwd-independence.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-d-output-contract.sh
. "$GROUP_DIR/group-d-output-contract.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-e-scan-range.sh
. "$GROUP_DIR/group-e-scan-range.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-f-zero-result.sh
. "$GROUP_DIR/group-f-zero-result.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-g-e2e-scale.sh
. "$GROUP_DIR/group-g-e2e-scale.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-h-cli-errors.sh
. "$GROUP_DIR/group-h-cli-errors.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-i-injection.sh
. "$GROUP_DIR/group-i-injection.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-j-idempotency.sh
. "$GROUP_DIR/group-j-idempotency.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-k-shared-predicate.sh
. "$GROUP_DIR/group-k-shared-predicate.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-l-regression-families.sh
. "$GROUP_DIR/group-l-regression-families.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-m-offline-fallback.sh
. "$GROUP_DIR/group-m-offline-fallback.sh"
# shellcheck source=fix-1833-audit-tests-survival-first/group-n-sibling-unit.sh
. "$GROUP_DIR/group-n-sibling-unit.sh"

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1

#!/usr/bin/env bash
# tests/feature-2223-show-local-env-overrides.sh
# Tests: bin/show-local-env-overrides, hooks/lib/load-env.js, hooks/lib/local-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, secret-leakage, trust-boundary, cli, pwsh-not-required
# Issue #2223 — the reporter naming which keys of a project's own local override
# file reached the effective config and which the blocklist refused. Pinned:
# key NAMES only, never values; exit 0 in every reportable outcome; exit 64 with
# empty stdout on a usage error; a git-tracked override file warns on stderr
# (DD-7, fail-open) without ever withholding the stdout report.

set -u

# TL3 gap (what this test does NOT catch):
# - A real repo whose override file is edited mid-session, with the reporter run
#   from the live Claude Code session's own cwd and inherited environment.
# - A PATH shim symlinked into ~/.local/bin resolving the library through
#   realpathSync back to the repo it points at.
# - A symlinked AGENTS_CONFIG_DIR whose hooks/lib is reached through the link.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Never named as a whole path literal: hooks/block-dotenv.js blocks that (DD-1).
LOCAL_ENV_BASENAME=".env"".local"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Isolation: pin both halves of the plans-dir pair, drop inherited session ids,
# and let no ambient AGENTS_CONFIG_DIR, project dir, or tested key reach a child.
export CLAUDE_WORKFLOW_DIR="$TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PROJECT_DIR
unset AGENTS_CONFIG_DIR
unset CODE_LANG
unset PROJECT_NFR

PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name — expected to contain '$needle'; got: $haystack"
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$name — expected NOT to contain '$needle'; got: $haystack"
    else
        pass "$name"
    fi
}

# A negative assertion over an empty report passes for the wrong reason: the
# report must exist before "the value is absent from it" means anything.
assert_report_lacks() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"project-root:"*) assert_not_contains "$name" "$haystack" "$needle" ;;
        *) fail "$name — no report produced (got: $haystack); absence not provable" ;;
    esac
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

decode() { local s="$1"; s="${s//@NL@/$'\n'}"; printf '%s' "$s"; }

CLI="$AGENTS_DIR/bin/show-local-env-overrides"
CLI_NODE="$(to_node_path "$CLI")"
if [ ! -f "$CLI" ]; then
    echo "NOTE: bin/show-local-env-overrides absent — every case below is expected RED."
fi

# new_case <name> <global-env-content> <local-env-content|__NONE__>
# Sets CASE_CFG / CASE_ROOT / CASE_ROOT_NODE. A bare .git entry is enough:
# resolveProjectRoot never spawns git, so no git init.
new_case() {
    local name="$1" global_content="$2" local_content="$3"
    CASE_CFG="$TMP_ROOT/c-$name/cfg"
    CASE_ROOT="$TMP_ROOT/c-$name/repo"
    rm -rf "$TMP_ROOT/c-$name"
    mkdir -p "$CASE_CFG" "$CASE_ROOT/.git"
    printf '%s\n' "$(decode "$global_content")" > "$CASE_CFG/.env"
    if [ "$local_content" != "__NONE__" ]; then
        printf '%s\n' "$(decode "$local_content")" > "$CASE_ROOT/$LOCAL_ENV_BASENAME"
    fi
    CASE_ROOT_NODE="$(to_node_path "$CASE_ROOT")"
}

# new_git_case — same, but CASE_ROOT is a real repository, because the tracked-
# file warning is the one behaviour a bare .git directory cannot exercise.
new_git_case() {
    local name="$1" global_content="$2" local_content="$3"
    CASE_CFG="$TMP_ROOT/g-$name/cfg"
    CASE_ROOT="$TMP_ROOT/g-$name/repo"
    rm -rf "$TMP_ROOT/g-$name"
    mkdir -p "$CASE_CFG" "$CASE_ROOT"
    printf '%s\n' "$(decode "$global_content")" > "$CASE_CFG/.env"
    git -C "$CASE_ROOT" init --quiet >/dev/null 2>&1
    git -C "$CASE_ROOT" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$CASE_ROOT" config user.email "fixture@example.com" >/dev/null 2>&1
    git -C "$CASE_ROOT" config user.name "Fixture" >/dev/null 2>&1
    printf '%s\n' "$(decode "$local_content")" > "$CASE_ROOT/$LOCAL_ENV_BASENAME"
    CASE_ROOT_NODE="$(to_node_path "$CASE_ROOT")"
}

# run_cli_in <cwd> [args...] -> CLI_OUT / CLI_ERR / CLI_RC. The two streams are
# captured separately: stderr carries a diagnostic that must never be able to
# satisfy a stdout assertion. Paths go through to_node_path first — MSYS
# rewrites a POSIX-looking value on its way to native node.exe.
run_cli_in() {
    local cwd="$1"; shift
    local outf="$TMP_ROOT/cli-out.txt" errf="$TMP_ROOT/cli-err.txt"
    CLI_RC=0
    (
        cd "$cwd" || exit 70
        AGENTS_CONFIG_DIR="$(to_node_path "$CASE_CFG")" \
            run_with_timeout 20 node "$CLI_NODE" "$@"
    ) >"$outf" 2>"$errf" || CLI_RC=$?
    CLI_OUT="$(cat "$outf")"
    CLI_ERR="$(cat "$errf")"
}

run_cli() { run_cli_in "$TMP_ROOT" "$@"; }

# section_keys <stdout> <heading> — the indented key names under one heading.
section_keys() {
    printf '%s\n' "$1" | awk -v h="$2" '
        index($0, h " (") == 1 { grab = 1; next }
        grab == 1 && substr($0, 1, 2) == "  " { print substr($0, 3); next }
        grab == 1 { grab = 0 }
    '
}

# section_count <stdout> <heading> — the N the heading itself declares.
section_count() {
    printf '%s\n' "$1" | sed -n "s/^$2 (\([0-9]*\))\$/\1/p"
}

# header_value <stdout> <label> — one header line's value, slash-normalized.
# process.cwd() and path.resolve() print native C:\... under MSYS, while
# to_node_path yields C:/...; the two are the same path, so compare one form.
header_value() {
    printf '%s\n' "$1" | sed -n "s/^$2 *//p" | tr '\\' '/'
}

# The DD-7 stderr warning text, named once: G3 and G16 assert on it too.
WARN_TEXT="is tracked by git in this repository"

# ---------------------------------------------------------------------------
# L1: applied vs refused partitioning, and the no-value-leakage contract.
# Sentinel values exist nowhere but the fixture file, so finding one in the
# report can only mean the reporter printed it.
# ---------------------------------------------------------------------------
S_ORDINARY="SENT2223-ordinary-b41d9c"
S_NFR="SENT2223-nfr-7e0a52"
S_EXACT="SENT2223-refused-exact-3fc8a1"
S_PREFIX="SENT2223-refused-prefix-9d26b7"
S_WF="SENT2223-refused-wf-5c14e8"

new_case partition \
  "CODE_LANG=english@NL@AGENTS_CONFIG_DIR=/global-cfg@NL@CODEX_NFR_MAX_LINES=200" \
  "PROJECT_TAGLINE=$S_ORDINARY@NL@PROJECT_NFR=$S_NFR@NL@AGENTS_CONFIG_DIR=$S_EXACT@NL@CODEX_NFR_MAX_LINES=$S_PREFIX@NL@CLAUDE_WORKFLOW_DIR=$S_WF"
run_cli --repo-root "$CASE_ROOT_NODE"

assert_eq "T2223S-partition-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-partition-project-root-line" "$CLI_OUT" "project-root: "
assert_contains "T2223S-partition-local-file-line" "$CLI_OUT" "local-file:   "
assert_contains "T2223S-partition-local-file-basename" "$CLI_OUT" "$LOCAL_ENV_BASENAME"
assert_not_contains "T2223S-partition-no-status-line" "$CLI_OUT" "status:"

# G13: a substring check passes for a regression that prints the basename alone
# or the wrong root, so both header lines are pinned by equality.
assert_eq "T2223S-partition-root-line-exact" "$(to_node_path "$CASE_ROOT")" \
  "$(header_value "$CLI_OUT" "project-root:")"
assert_eq "T2223S-partition-local-file-line-exact" \
  "$(to_node_path "$CASE_ROOT")/$LOCAL_ENV_BASENAME" \
  "$(header_value "$CLI_OUT" "local-file:")"

# G6: this stream is asserted empty, so every not_contains below it means
# something. It also pins warnIfTracked's fail-open on a bare-.git non-repository.
assert_eq "T2223S-partition-clean-stderr" "" "$CLI_ERR"

PART_APPLIED="$(section_keys "$CLI_OUT" applied)"
PART_REFUSED="$(section_keys "$CLI_OUT" "refused by blocklist")"

assert_eq "T2223S-partition-applied-keys" "$(printf 'PROJECT_NFR\nPROJECT_TAGLINE')" "$PART_APPLIED"
assert_eq "T2223S-partition-refused-keys" \
  "$(printf 'AGENTS_CONFIG_DIR\nCLAUDE_WORKFLOW_DIR\nCODEX_NFR_MAX_LINES')" "$PART_REFUSED"
assert_eq "T2223S-partition-applied-count" "2" "$(section_count "$CLI_OUT" applied)"
assert_eq "T2223S-partition-refused-count" "3" "$(section_count "$CLI_OUT" "refused by blocklist")"
# G18: the second new blocklist entry, refused at the reporter level (CPR-ORTH).
assert_contains "T2223S-partition-workflow-dir-refused" "$PART_REFUSED" "CLAUDE_WORKFLOW_DIR"
assert_report_lacks "T2223S-noleak-refused-wf-stdout" "$CLI_OUT" "$S_WF"

# The whole point of #2223: a project's own PROJECT_NFR applies with nothing
# declaring it, while the CODEX_ cap on that very text stays refused.
assert_contains "T2223S-partition-nfr-applied" "$PART_APPLIED" "PROJECT_NFR"
assert_not_contains "T2223S-partition-nfr-not-refused" "$PART_REFUSED" "PROJECT_NFR"
assert_contains "T2223S-partition-codex-cap-refused" "$PART_REFUSED" "CODEX_NFR_MAX_LINES"

# No value leakage — the highest-value case: an applied key's value and a
# refused key's value are equally forbidden from stdout AND stderr.
assert_report_lacks "T2223S-noleak-applied-ordinary-stdout" "$CLI_OUT" "$S_ORDINARY"
assert_report_lacks "T2223S-noleak-applied-nfr-stdout" "$CLI_OUT" "$S_NFR"
assert_report_lacks "T2223S-noleak-refused-exact-stdout" "$CLI_OUT" "$S_EXACT"
assert_report_lacks "T2223S-noleak-refused-prefix-stdout" "$CLI_OUT" "$S_PREFIX"
assert_not_contains "T2223S-noleak-applied-ordinary-stderr" "$CLI_ERR" "$S_ORDINARY"
assert_not_contains "T2223S-noleak-applied-nfr-stderr" "$CLI_ERR" "$S_NFR"
assert_not_contains "T2223S-noleak-refused-exact-stderr" "$CLI_ERR" "$S_EXACT"
assert_not_contains "T2223S-noleak-refused-prefix-stderr" "$CLI_ERR" "$S_PREFIX"
# The shared sentinel stem catches a partial or truncated value print too.
assert_report_lacks "T2223S-noleak-no-sentinel-stem-stdout" "$CLI_OUT" "SENT2223-"
assert_not_contains "T2223S-noleak-no-sentinel-stem-stderr" "$CLI_ERR" "SENT2223-"

# A global-layer secret the local file never mentions must not surface either.
new_case noleak-global "CODE_LANG=english@NL@GLOBAL_SECRET=SENT2223-global-only-c05e13" \
  "PROJECT_NFR=SENT2223-nfr-again-118bd4"
run_cli --repo-root "$CASE_ROOT_NODE"
assert_report_lacks "T2223S-noleak-global-value" "$CLI_OUT" "SENT2223-global-only-c05e13"
assert_report_lacks "T2223S-noleak-global-key-absent" "$CLI_OUT" "GLOBAL_SECRET"

# ---------------------------------------------------------------------------
# L2: the matcher is case-folded, so a lower-cased blocklist key is still
# refused — and is reported under the spelling the file actually used.
# ---------------------------------------------------------------------------
new_case lowercase 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' \
  'enforce_worktree=SENT2223-lower-46ae70@NL@PROJECT_NFR=SENT2223-lower-nfr-2b91fd'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-lowercase-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-lowercase-blocked-refused" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")" "enforce_worktree"
assert_not_contains "T2223S-lowercase-blocked-not-applied" \
  "$(section_keys "$CLI_OUT" applied)" "enforce_worktree"
assert_eq "T2223S-lowercase-refused-count" "1" "$(section_count "$CLI_OUT" "refused by blocklist")"
assert_report_lacks "T2223S-lowercase-no-value-leak" "$CLI_OUT" "SENT2223-"

# A mixed-case prefix key is the symmetric counterpart of the exact-set case.
new_case mixedcase 'CODE_LANG=english' 'Codex_Mode=SENT2223-mixed-8c4f0a'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_contains "T2223S-mixedcase-prefix-refused" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")" "Codex_Mode"
assert_eq "T2223S-mixedcase-applied-count" "0" "$(section_count "$CLI_OUT" applied)"
assert_report_lacks "T2223S-mixedcase-no-value-leak" "$CLI_OUT" "SENT2223-"

# ---------------------------------------------------------------------------
# L3: absent, empty, and unreadable local files. Absent is an answer, not a
# failure — so it is exit 0 with a status line and no partition at all.
# ---------------------------------------------------------------------------
new_case absent 'CODE_LANG=english' '__NONE__'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-absent-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-absent-status-line" "$CLI_OUT" \
  "status:       absent or unreadable — no key is overridden"
assert_not_contains "T2223S-absent-no-applied-section" "$CLI_OUT" "applied ("
assert_not_contains "T2223S-absent-no-refused-section" "$CLI_OUT" "refused by blocklist ("
assert_contains "T2223S-absent-still-names-file" "$CLI_OUT" "$LOCAL_ENV_BASENAME"
# G13: with no partition to read, the two header lines carry all the information.
assert_eq "T2223S-absent-root-line-exact" "$(to_node_path "$CASE_ROOT")" \
  "$(header_value "$CLI_OUT" "project-root:")"
assert_eq "T2223S-absent-local-file-line-exact" \
  "$(to_node_path "$CASE_ROOT")/$LOCAL_ENV_BASENAME" \
  "$(header_value "$CLI_OUT" "local-file:")"

# Unreadable-as-a-file: a directory at that name is the portable form of "open
# fails", since chmod 000 is not honoured on every filesystem this suite runs on.
new_case unreadable 'CODE_LANG=english' '__NONE__'
mkdir -p "$CASE_ROOT/$LOCAL_ENV_BASENAME"
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-unreadable-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-unreadable-status-line" "$CLI_OUT" "status:       absent or unreadable"

# Empty file: readable, so it is a real (empty) partition — not the absent path.
new_case empty 'CODE_LANG=english' '__NONE__'
: > "$CASE_ROOT/$LOCAL_ENV_BASENAME"
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-empty-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-empty-applied-count" "0" "$(section_count "$CLI_OUT" applied)"
assert_eq "T2223S-empty-refused-count" "0" "$(section_count "$CLI_OUT" "refused by blocklist")"
assert_not_contains "T2223S-empty-no-status-line" "$CLI_OUT" "status:"
assert_eq "T2223S-empty-clean-stderr" "" "$CLI_ERR"

# Comments and blank lines only — parses to zero keys without crashing.
new_case comments-only 'CODE_LANG=english' '# just a comment@NL@@NL@# another'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-comments-only-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-comments-only-applied-count" "0" "$(section_count "$CLI_OUT" applied)"

# ---------------------------------------------------------------------------
# L4: no project root resolves at all. The null expectation only holds when no
# ancestor of the start dir carries .git, so the precondition is measured.
# ---------------------------------------------------------------------------
new_case noroot 'CODE_LANG=english' '__NONE__'
NOROOT_DIR="$TMP_ROOT/c-noroot/nogit"
mkdir -p "$NOROOT_DIR"
ANCESTOR_GIT=0
_probe_dir="$NOROOT_DIR"
while [ -n "$_probe_dir" ] && [ "$_probe_dir" != "/" ]; do
    if [ -e "$_probe_dir/.git" ]; then ANCESTOR_GIT=1; break; fi
    _next="$(dirname "$_probe_dir")"
    [ "$_next" != "$_probe_dir" ] || break
    _probe_dir="$_next"
done
if [ "$ANCESTOR_GIT" -eq 0 ]; then
    run_cli_in "$NOROOT_DIR"
    assert_eq "T2223S-noroot-exit-0" "0" "$CLI_RC"
    assert_eq "T2223S-noroot-line" "project-root: (none resolved)" "$CLI_OUT"
    assert_eq "T2223S-noroot-clean-stderr" "" "$CLI_ERR"
else
    fail "T2223S-noroot — precondition broken: an ancestor of $NOROOT_DIR carries .git"
fi

# ---------------------------------------------------------------------------
# L5: usage errors. Exit 64, nothing on stdout, the usage line on stderr.
# ---------------------------------------------------------------------------
new_case usage 'CODE_LANG=english' 'PROJECT_NFR=SENT2223-usage-5a7e21'
run_cli --bogus-flag
assert_eq "T2223S-usage-unknown-flag-exit-64" "64" "$CLI_RC"
assert_eq "T2223S-usage-unknown-flag-empty-stdout" "" "$CLI_OUT"
assert_contains "T2223S-usage-unknown-flag-stderr" "$CLI_ERR" \
  "usage: show-local-env-overrides"

# G6 positive control for the capture path itself: this is the one case whose
# stderr is legitimately non-empty, so an always-empty CLI_ERR (a redirect typo
# in run_cli_in) would make every stderr negative elsewhere vacuous.
if [ -n "$CLI_ERR" ]; then
    pass "T2223S-stderr-capture-path-works"
else
    fail "T2223S-stderr-capture-path-works — usage error produced no stderr"
fi

run_cli --repo-root
assert_eq "T2223S-usage-valueless-repo-root-exit-64" "64" "$CLI_RC"
assert_eq "T2223S-usage-valueless-repo-root-empty-stdout" "" "$CLI_OUT"
assert_contains "T2223S-usage-valueless-repo-root-stderr" "$CLI_ERR" \
  "usage: show-local-env-overrides"

# A bare positional is not a flag either — it must not be read as a repo root.
run_cli "$CASE_ROOT_NODE"
assert_eq "T2223S-usage-positional-exit-64" "64" "$CLI_RC"
assert_eq "T2223S-usage-positional-empty-stdout" "" "$CLI_OUT"

# ---------------------------------------------------------------------------
# L6: a project root whose path carries a space. The local keys must still be
# partitioned — proving the path survived every hop unsplit.
# ---------------------------------------------------------------------------
new_case spaced 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' '__NONE__'
SPACED_ROOT="$CASE_ROOT/holder/pr oj dir/repo"
mkdir -p "$SPACED_ROOT/.git"
printf 'PROJECT_NFR=SENT2223-spaced-nfr-d92c46\nENFORCE_WORKTREE=SENT2223-spaced-blocked-71fa38\n' \
  > "$SPACED_ROOT/$LOCAL_ENV_BASENAME"
run_cli --repo-root "$(to_node_path "$SPACED_ROOT")"
assert_eq "T2223S-spaced-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-spaced-root-line-keeps-space" "$CLI_OUT" "pr oj dir"
assert_eq "T2223S-spaced-applied-keys" "PROJECT_NFR" "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-spaced-refused-keys" "ENFORCE_WORKTREE" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")"
assert_report_lacks "T2223S-spaced-no-value-leak" "$CLI_OUT" "SENT2223-"

# ---------------------------------------------------------------------------
# L7: output ordering. Both sections are sorted regardless of file order, and
# the report is stable across repeated runs over an unchanged fixture.
# ---------------------------------------------------------------------------
new_case sorted 'CODE_LANG=english' \
  'ZULU_KEY=z@NL@ALPHA_KEY=a@NL@MIKE_KEY=m@NL@WORKTREE_BASE_DIR=w@NL@AGENTS_CONFIG_DIR=g@NL@SWEEP_AGE_DAYS=s'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-sorted-applied" "$(printf 'ALPHA_KEY\nMIKE_KEY\nZULU_KEY')" \
  "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-sorted-refused" \
  "$(printf 'AGENTS_CONFIG_DIR\nSWEEP_AGE_DAYS\nWORKTREE_BASE_DIR')" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")"
assert_eq "T2223S-sorted-applied-count" "3" "$(section_count "$CLI_OUT" applied)"
assert_eq "T2223S-sorted-refused-count" "3" "$(section_count "$CLI_OUT" "refused by blocklist")"

SORTED_FIRST="$CLI_OUT"
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-sorted-stable-across-runs" "$SORTED_FIRST" "$CLI_OUT"

# Section order on the page: applied is reported before refused.
_a="$(printf '%s\n' "$SORTED_FIRST" | grep -c '^applied (')"
_r="$(printf '%s\n' "$SORTED_FIRST" | grep -c '^refused by blocklist (')"
if [ "$_a" -eq 1 ] && [ "$_r" -eq 1 ]; then
    _al="$(printf '%s\n' "$SORTED_FIRST" | grep -n '^applied (' | cut -d: -f1)"
    _rl="$(printf '%s\n' "$SORTED_FIRST" | grep -n '^refused by blocklist (' | cut -d: -f1)"
    if [ "$_al" -lt "$_rl" ]; then
        pass "T2223S-sorted-applied-section-first"
    else
        fail "T2223S-sorted-applied-section-first — applied at $_al, refused at $_rl"
    fi
else
    fail "T2223S-sorted-applied-section-first — headings not found exactly once ($_a/$_r)"
fi

# ---------------------------------------------------------------------------
# L8: the tracked-override-file warning (DD-7). A committed override file is
# distributed to every clone, so the reporter says so on stderr — and never
# withholds the stdout report over it. Real repositories only: a bare .git
# directory cannot answer `git ls-files`.
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    fail "T2223S-tracked — git unavailable; the DD-7 warning cannot be exercised"
else
    new_git_case tracked 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' \
      'PROJECT_NFR=SENT2223-tracked-nfr-6b30ee@NL@ENFORCE_WORKTREE=SENT2223-tracked-blocked-a17c95'
    TRACKED_ADD_RC=0
    git -C "$CASE_ROOT" add -- "$LOCAL_ENV_BASENAME" >/dev/null 2>&1 || TRACKED_ADD_RC=$?
    assert_eq "T2223S-tracked-fixture-staged" "0" "$TRACKED_ADD_RC"
    run_cli --repo-root "$CASE_ROOT_NODE"
    assert_eq "T2223S-tracked-exit-0" "0" "$CLI_RC"
    assert_contains "T2223S-tracked-warning-on-stderr" "$CLI_ERR" "$WARN_TEXT"
    assert_contains "T2223S-tracked-warning-names-file" "$CLI_ERR" "$LOCAL_ENV_BASENAME"
    assert_not_contains "T2223S-tracked-warning-not-on-stdout" "$CLI_OUT" "$WARN_TEXT"
    assert_eq "T2223S-tracked-report-still-applied" "PROJECT_NFR" \
      "$(section_keys "$CLI_OUT" applied)"
    assert_eq "T2223S-tracked-report-still-refused" "ENFORCE_WORKTREE" \
      "$(section_keys "$CLI_OUT" "refused by blocklist")"
    assert_eq "T2223S-tracked-applied-count" "1" "$(section_count "$CLI_OUT" applied)"
    # The warning is a second output path, so it gets its own leak assertion.
    assert_report_lacks "T2223S-tracked-no-value-leak-stdout" "$CLI_OUT" "SENT2223-"
    assert_not_contains "T2223S-tracked-no-value-leak-stderr" "$CLI_ERR" "SENT2223-"

    # Symmetric counterpart: a real repository that leaves the file untracked
    # and gitignored must draw no warning at all.
    new_git_case untracked 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' \
      'PROJECT_NFR=SENT2223-untracked-nfr-4e8d17@NL@ENFORCE_WORKTREE=SENT2223-untracked-blocked-c62b09'
    printf '%s\n' "$LOCAL_ENV_BASENAME" > "$CASE_ROOT/.gitignore"
    run_cli --repo-root "$CASE_ROOT_NODE"
    assert_eq "T2223S-untracked-exit-0" "0" "$CLI_RC"
    assert_not_contains "T2223S-untracked-no-warning" "$CLI_ERR" "$WARN_TEXT"
    # G6: the two negatives above only mean something once the stream they read
    # is pinned — an untracked file in a real repository writes nothing at all.
    assert_eq "T2223S-untracked-stderr-exactly-empty" "" "$CLI_ERR"
    assert_eq "T2223S-untracked-report-still-applied" "PROJECT_NFR" \
      "$(section_keys "$CLI_OUT" applied)"
    assert_eq "T2223S-untracked-report-still-refused" "ENFORCE_WORKTREE" \
      "$(section_keys "$CLI_OUT" "refused by blocklist")"
    assert_report_lacks "T2223S-untracked-no-value-leak-stdout" "$CLI_OUT" "SENT2223-"
    assert_not_contains "T2223S-untracked-no-value-leak-stderr" "$CLI_ERR" "SENT2223-"
fi

# ---------------------------------------------------------------------------
# Sibling case files. Sourced (not executed) so they share the helpers, fixtures
# and counters above; split off to stay under the 500-line HARD limit of
# rules/coding/file-split.md, the same shape feature-2223-local-env-overlay uses.
# ---------------------------------------------------------------------------
CASES_DIR="$AGENTS_DIR/tests/feature-2223-show-local-env-overrides"
for _case in resolution security degradation readonly; do
    _case_file="$CASES_DIR/$_case.sh"
    if [ -f "$_case_file" ]; then
        . "$_case_file"
    else
        fail "T2223S-cases-file-present-$_case — $_case_file missing"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

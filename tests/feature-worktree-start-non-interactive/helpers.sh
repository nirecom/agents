#!/bin/bash
# lang-check: ignore — intentional non-ASCII/CJK test fixture data (locale disambiguation / slugify robustness cases for issue #1910), not a comment-language violation
# tests/feature-worktree-start-non-interactive/helpers.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, skills/worktree-start/SKILL.md
# Tags: worktree, start, helpers, fixture, TL2, scope:issue-specific
# Shared helpers for feature-worktree-start-non-interactive tests.
# Sourced by sub-files — not a standalone runner.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL_MD="$AGENTS_DIR/skills/worktree-start/SKILL.md"
SCRIPT="$AGENTS_DIR/skills/worktree-start/scripts/derive-worktree-name.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Table-driven assertion helper (skills/_shared/test-design/parser-regex-tests.md).
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

# assert_match <name> <ERE> <got> — for values carrying the UTC disambiguator.
assert_match() {
    local name="$1" want_re="$2" got="$3"
    if printf '%s' "$got" | grep -qE "$want_re"; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want~$(printf '%q' "$want_re") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

# The D3b disambiguator is a pure UTC timestamp: `date -u +%Y%m%d%H%M%S`.
TS_RE='[0-9]{14}'

# ── Source-scoping helpers ──────────────────────────────────────────────────
#
# Mechanism pins must be anchored to the function or section that owns the line,
# never to the whole file: derive-worktree-name.sh now carries several LC_ALL=C
# pins and two `tr 'A-Z' 'a-z'` sites, so a file-wide grep can pass on a line the
# assertion was never about.

# extract_fn <fn-name> <file> — body of a top-level `<fn-name>() {` ... `}` block.
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { inside = 1; next }
        inside && /^\}/                     { inside = 0; next }
        inside                              { print }
    ' "$2"
}

# extract_section <start-marker> <end-marker> <file> — lines between two banner
# comments (markers are matched as literal line prefixes, exclusive of both).
extract_section() {
    awk -v s="$1" -v e="$2" '
        index($0, s) == 1 { inside = 1; next }
        inside && index($0, e) == 1 { inside = 0; next }
        inside { print }
    ' "$3"
}

# native_path <path> — the platform-native spelling git itself prints for a path.
# `git worktree list --porcelain` reports Windows drive-letter paths under Git Bash
# (`C:/Users/...`) while a mktemp-built fixture path is MSYS-style (`/tmp/...`), so the
# two are not comparable as strings until one side is translated. cygpath is purely
# lexical, so the path does not have to exist yet. No-op where cygpath is absent
# (Linux/macOS), which is exactly the identity translation those platforms need.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
}

# ── Behavioral fixture (TL2) ────────────────────────────────────────────────
#
# Fixture isolation (rules/test/fixture-isolation.md): dual-pin the state dirs and
# drop any inherited session id so the script can never touch the real $HOME state.
# The script under test resolves its helper CLIs from AGENTS_CONFIG_DIR; pin it
# unconditionally to the checkout under test. Honouring an inherited value would make
# the suite assert against whatever config dir the invoking shell happened to export
# (typically the deployed $HOME/.claude copy) instead of the worktree being tested.
setup_fixture() {
    FIXTURE="$(mktemp -d)"
    # STUBDIR is allocated on demand by ensure_stubdir(): only derive-gh.sh and
    # reuse-safety.sh need a PATH shim, and the other sub-files would otherwise create
    # and immediately abandon a temp dir. Cleanup is registered here regardless — the trap tolerates
    # the unallocated case, so the owner of the creation never has to re-register it.
    STUBDIR=""
    trap 'rm -rf "$FIXTURE" ${STUBDIR:+"$STUBDIR"}' EXIT

    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    mkdir -p "$FIXTURE/wf" "$FIXTURE/plans"
    export CLAUDE_WORKFLOW_DIR="$FIXTURE/wf"
    export WORKFLOW_PLANS_DIR="$FIXTURE/plans"
    unset CLAUDE_SESSION_ID 2>/dev/null || true
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

    # Live-`gh` insulation. derive-worktree-name.sh resolves the user's private-repo
    # name list once per run (bin/list-private-repo-names.js -> `gh repo list
    # --visibility private`) and scan_clean() then checks every emitted value against
    # it via bin/check-private-repo-name.js. Left undeclared, every run_derive call in
    # this suite issues a live, credentialed, network round trip: slow, rate-limited,
    # broken offline, and — worse — the derived name would depend on which private
    # repos the running user happens to own. Declaring the cache pins the list for the
    # whole suite, so no sub-file needs its own `gh` PATH shim for this path
    # (rules/test/fixture-isolation.md).
    #
    # SET=1 means "this list is authoritative", so the empty CACHE below means
    # "confirmed: no private repos" — behaviorally identical to the "no private repo
    # name matched" outcome every existing fixture title/label already assumed.
    # A case that needs a populated list overrides these two for its own invocation
    # (see private-repo-gate.sh); nothing here forces them to stay empty.
    export PRIVATE_REPO_NAMES_CACHE_SET=1
    export PRIVATE_REPO_NAMES_CACHE=''

    ABSENT_INTENT="$FIXTURE/absent/intent.md"
    TITLE_B1='worktree-start: 対話/非対話モード分岐を廃止し、task-name/branch-type をスキル内自動生成に統一する'
    INTENT_B1="$FIXTURE/b1-intent.md"
    write_intent "$INTENT_B1" "$TITLE_B1" '- #1910: worktree-start auto naming'
}

# ensure_stubdir — allocate $STUBDIR the first time a sub-file actually needs a
# PATH shim. Idempotent; cleanup is already registered by setup_fixture's trap.
ensure_stubdir() {
    [ -n "${STUBDIR:-}" ] || STUBDIR="$(mktemp -d)"
}

# write_intent <path> <title> <issues-body>
write_intent() {
    local path="$1" title="$2" issues="$3"
    mkdir -p "$(dirname "$path")"
    {
        printf '**Title:** %s\n\n' "$title"
        printf '## Issues\n\n'
        [ -n "$issues" ] && printf '%s\n' "$issues"
        printf '\n## Scope\n\n- fixture\n'
    } > "$path"
}

OUT=""; ERR=""; RC=0
SHAPE_VIOLATIONS=""

# run_derive <label> [args...] — captures stdout/stderr/exit code and applies the
# B10 cross-cutting shape assertion to any TASK_NAME/BRANCH_TYPE/REPO_NAME it emits.
# REPO_NAME joined the stdout contract with #1910 (D0); its allowed shape is
# safe_component()'s domain, not TASK_NAME's.
run_derive() {
    local label="$1"; shift
    local errfile="$FIXTURE/stderr.$$"
    # stdin is closed: any prompt the script might grow would EOF instead of
    # hanging the suite, so "never asks" is enforced rather than assumed.
    OUT="$(bash "$SCRIPT" "$@" 2>"$errfile" </dev/null)"
    RC=$?
    ERR="$(cat "$errfile")"
    rm -f "$errfile"

    local tn bt rn
    tn="$(printf '%s\n' "$OUT" | sed -n 's/^TASK_NAME=//p' | head -1)"
    bt="$(printf '%s\n' "$OUT" | sed -n 's/^BRANCH_TYPE=//p' | head -1)"
    rn="$(printf '%s\n' "$OUT" | sed -n 's/^REPO_NAME=//p' | head -1)"
    if [ -n "$tn" ] && ! printf '%s' "$tn" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        SHAPE_VIOLATIONS="$SHAPE_VIOLATIONS $label:TASK_NAME='$tn'"
    fi
    if [ -n "$bt" ] && ! printf '%s' "$bt" | grep -qE '^(feature|fix|refactor|docs|chore)$'; then
        SHAPE_VIOLATIONS="$SHAPE_VIOLATIONS $label:BRANCH_TYPE='$bt'"
    fi
    # A successful run must carry all three lines: a missing REPO_NAME on rc=0 is
    # itself a contract violation, not merely an unchecked field.
    if [ "$RC" -eq 0 ] && [ -n "$tn" ] && [ -z "$rn" ]; then
        SHAPE_VIOLATIONS="$SHAPE_VIOLATIONS $label:REPO_NAME=<missing>"
    fi
    case "$rn" in
        '') ;;
        .|..|*[!a-zA-Z0-9._-]*) SHAPE_VIOLATIONS="$SHAPE_VIOLATIONS $label:REPO_NAME='$rn'" ;;
    esac
}

has_line() { printf '%s\n' "$OUT" | grep -qxF "$1"; }
task_name() { printf '%s\n' "$OUT" | sed -n 's/^TASK_NAME=//p' | head -1; }
branch_type() { printf '%s\n' "$OUT" | sed -n 's/^BRANCH_TYPE=//p' | head -1; }
repo_name() { printf '%s\n' "$OUT" | sed -n 's/^REPO_NAME=//p' | head -1; }

# --- B10: cross-cutting output shape ----------------------------------------
# Guarded on `-f $SCRIPT` too: an empty accumulator means "nothing ran", not "all clean".
report_shape() {
    local group="$1"
    if [ -f "$SCRIPT" ] && [ -z "$SHAPE_VIOLATIONS" ]; then
        pass "B10/$group: every emitted TASK_NAME/BRANCH_TYPE matches the allowed shape"
    elif [ ! -f "$SCRIPT" ]; then
        fail "B10/$group: derive-worktree-name.sh missing — no behavioral output to shape-check"
    else
        fail "B10/$group: shape violations:$SHAPE_VIOLATIONS"
    fi
}

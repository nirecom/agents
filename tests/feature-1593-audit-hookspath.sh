#!/usr/bin/env bash
# Tests: bin/audit-hookspath-neutralization.sh
# Tags: audit, hookspath, neutralization, security, hermetic, scope:issue-specific
# Hermetic self-test for the #1603 cross-checkout inventory scanner: it sweeps
# the git repos under each `--roots <dir>` and reports any whose repo-local
# core.hooksPath is neutralized (/dev/null, empty, NUL, out-of-tree). report-only
# — it never unsets. The script does not exist pre-#1603, so every case fails
# NO_SCRIPT (a clean fail-before-fix). Roots are always fixture dirs, so the
# default real-machine sweep is never exercised (fixture-isolation.md).

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/harness.sh
. "$HERE/lib/harness.sh"
harness_isolate

AUDIT="$AGENTS_DIR/bin/audit-hookspath-neutralization.sh"

BROOT="$(make_tmp)"
trap 'rm -rf "$BROOT"' EXIT INT TERM HUP

# A_RC / A_OUT capture the last audit run. When the script is absent we short
# out to NO_SCRIPT so every case reports a clean fail-before-fix, never a crash.
A_RC=0; A_OUT=""
run_audit() {
    if [ ! -f "$AUDIT" ]; then A_RC=127; A_OUT="NO_SCRIPT"; return; fi
    local ofile; ofile="$(mktemp)"
    run_with_timeout 30 bash "$AUDIT" "$@" >"$ofile" 2>&1
    A_RC=$?
    A_OUT="$(cat "$ofile")"; rm -f "$ofile"
}

# mk_repo <dir> — inert git repo, core.hooksPath left UNSET (clean baseline).
# No commit is ever made here, so no hook fires; leaving hooksPath unset is safe
# and is exactly the state the scanner must treat as clean.
mk_repo() { git init -q "$1"; }
# mk_neutralized <dir> <value> — repo whose repo-local core.hooksPath is set to a
# neutralizing value the scanner must flag.
mk_neutralized() { git init -q "$1"; git -C "$1" config --local core.hooksPath "$2"; }

has() { case "$A_OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ─────────────────────────────────────────────────────────────────────────────
# F1: a root holding a repo with core.hooksPath=/dev/null → flagged by path.
# ─────────────────────────────────────────────────────────────────────────────
R1="$BROOT/r1"; mkdir -p "$R1"
mk_neutralized "$R1/bad1repo" /dev/null
run_audit --roots "$R1"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F1: bin/audit-hookspath-neutralization.sh absent (fail-before-fix, #1603)"
elif has "bad1repo"; then
    pass "F1: /dev/null neutralization detected + repo reported (rc=$A_RC)"
else
    fail "F1: expected bad1repo flagged, rc=$A_RC out=[$A_OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2: a root holding a repo with core.hooksPath UNSET → clean, not reported.
# ─────────────────────────────────────────────────────────────────────────────
R2="$BROOT/r2"; mkdir -p "$R2"
mk_repo "$R2/clean2repo"
run_audit --roots "$R2"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F2: audit script absent (fail-before-fix, #1603)"
elif ! has "clean2repo"; then
    pass "F2: unset core.hooksPath treated as clean (not reported, rc=$A_RC)"
else
    fail "F2: clean repo wrongly flagged, rc=$A_RC out=[$A_OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F3: a root holding a NON-git directory → skipped, no crash, nothing reported.
# ─────────────────────────────────────────────────────────────────────────────
R3="$BROOT/r3"; mkdir -p "$R3/plain3dir"
printf 'x\n' > "$R3/plain3dir/file.txt"
run_audit --roots "$R3"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F3: audit script absent (fail-before-fix, #1603)"
elif ! has "plain3dir"; then
    pass "F3: non-git dir skipped, not reported (rc=$A_RC)"
else
    fail "F3: non-git dir wrongly reported, rc=$A_RC out=[$A_OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F4: mixed root (one neutralized + one clean) → only the neutralized repo is
#     reported, AND its core.hooksPath is UNCHANGED after the run (report-only:
#     the scanner never unsets — no implicit state change to a PUBLIC repo).
# ─────────────────────────────────────────────────────────────────────────────
R4="$BROOT/r4"; mkdir -p "$R4"
mk_neutralized "$R4/bad4repo" /dev/null
mk_repo "$R4/good4repo"
before="$(git -C "$R4/bad4repo" config --local --get core.hooksPath 2>/dev/null)"
run_audit --roots "$R4"
after="$(git -C "$R4/bad4repo" config --local --get core.hooksPath 2>/dev/null)"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F4: audit script absent (fail-before-fix, #1603)"
elif has "bad4repo" && ! has "good4repo" && [ "$before" = "$after" ]; then
    pass "F4: only neutralized repo reported; report-only leaves config intact"
else
    fail "F4: expected bad4repo-only report + no unset, rc=$A_RC before=[$before] after=[$after] out=[$A_OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F5: core.hooksPath set to empty string → flagged (empty neutralizes hook dispatch).
# ─────────────────────────────────────────────────────────────────────────────
R5="$BROOT/r5"; mkdir -p "$R5"
mk_neutralized "$R5/empty5repo" ""
run_audit --roots "$R5"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F5: audit script absent (fail-before-fix, #1603)"
elif has "empty5repo"; then
    pass "F5: empty-string core.hooksPath detected + repo reported (rc=$A_RC)"
else
    fail "F5: empty-string hooksPath not detected, rc=$A_RC out=[$A_OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F6: core.hooksPath set to NUL (Windows equivalent of /dev/null) → flagged.
# ─────────────────────────────────────────────────────────────────────────────
R6="$BROOT/r6"; mkdir -p "$R6"
mk_neutralized "$R6/nul6repo" "NUL"
run_audit --roots "$R6"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F6: audit script absent (fail-before-fix, #1603)"
elif has "nul6repo"; then
    pass "F6: NUL core.hooksPath detected + repo reported (rc=$A_RC)"
else
    fail "F6: NUL hooksPath not detected, rc=$A_RC out=[$A_OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F7: core.hooksPath set to an out-of-tree absolute path → flagged.
#     Any absolute path that is not the repo's own .git/hooks is a bypass.
# ─────────────────────────────────────────────────────────────────────────────
R7="$BROOT/r7"; mkdir -p "$R7"
mk_neutralized "$R7/outtree7repo" "/tmp/external-hooks"
run_audit --roots "$R7"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F7: audit script absent (fail-before-fix, #1603)"
elif has "outtree7repo"; then
    pass "F7: out-of-tree core.hooksPath detected + repo reported (rc=$A_RC)"
else
    fail "F7: out-of-tree hooksPath not detected, rc=$A_RC out=[$A_OUT]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F8: core.hooksPath set to the repo's own .git/hooks (in-tree) → CLEAN, not
#     reported. An in-tree override is not a bypass; it still exercises the
#     installed hooks. This guards against over-reporting.
# ─────────────────────────────────────────────────────────────────────────────
R8="$BROOT/r8"; mkdir -p "$R8"
git init -q "$R8/intree8repo"
# Set hooksPath to the repo's own .git/hooks — an in-tree, non-neutralizing path.
INTREE_HOOKS_PATH="$R8/intree8repo/.git/hooks"
git -C "$R8/intree8repo" config --local core.hooksPath "$INTREE_HOOKS_PATH"
run_audit --roots "$R8"
if [ "$A_OUT" = "NO_SCRIPT" ]; then
    fail "F8: audit script absent (fail-before-fix, #1603)"
elif ! has "intree8repo"; then
    pass "F8: in-tree core.hooksPath treated as clean (not reported, rc=$A_RC)"
else
    fail "F8: in-tree hooksPath wrongly flagged as neutralized, rc=$A_RC out=[$A_OUT]"
fi

echo ""
echo "─────────────────────────────────────────"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

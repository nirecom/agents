#!/usr/bin/env bash
# Tests: skills/issue-reconcile/scripts/backfill-batch.sh
# Tags: history, docs, backdate, bin, issue-reconcile, scope:issue-specific
#
# Coverage for #1672's backfill-batch.sh: batch-appends a list of closed
# issue numbers into docs/history.md via issue-to-history.sh, then runs
# sort-history.py / doc-rotate.py exactly once for the whole batch (not once
# per issue -- that single-invocation property is the point of the
# --no-auto-rotate design in the per-issue append call).
#
# Stubbing approach: AGENTS_CONFIG_DIR/bin/github-issues/issue-to-history.sh
# is stubbed (its own coverage lives in tests/feature-1672-doc-append-backdate.sh
# and tests/feature-401-issue-to-history-shapes.sh) so this file can assert on
# call args/counts and control per-issue success/failure deterministically.
# bin/sort-history.py and bin/doc-rotate.py under --repo-dir are also stubbed
# (rather than exercised for real) so call-count assertions are exact and
# independent of real history.md content/size -- `uv run bin/<stub>.py`
# behaves identically to the real scripts from the invoking script's point of
# view (cwd + argv + exit code), which is all backfill-batch.sh depends on.
#
# TL3 gap (what this test does NOT catch):
# - Real issue-to-history.sh + real sort-history.py/doc-rotate.py running
#   against a live gh CLI and a real docs/history.md end-to-end.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: none (docs-only
# backfill tool, not in the risk-category list).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/skills/issue-reconcile/scripts/backfill-batch.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

if [ ! -f "$SCRIPT" ]; then
    fail "precondition: $SCRIPT missing"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# make_config <fail_numbers_csv_or_empty> — builds a fake AGENTS_CONFIG_DIR
# whose issue-to-history.sh stub logs each invocation to $CFG/call.log and
# fails (exit 1) for any issue number listed in $1 (comma-separated).
make_config() {
    local fail_nums="$1"
    local cfg="$WORKDIR/cfg-$RANDOM"
    mkdir -p "$cfg/bin/github-issues"
    cat > "$cfg/bin/github-issues/issue-to-history.sh" <<EOF
#!/bin/bash
N="\$1"
echo "\$N \$*" >> "$cfg/call.log"
for f in ${fail_nums//,/ }; do
    if [ "\$f" = "\$N" ]; then
        echo "stub: forced failure for #\$N" >&2
        exit 1
    fi
done
exit 0
EOF
    chmod +x "$cfg/bin/github-issues/issue-to-history.sh"
    : > "$cfg/call.log"
    echo "$cfg"
}

# make_repo — builds a fake --repo-dir with docs/history.md plus stub
# sort-history.py / doc-rotate.py that log invocations (cwd + argv) to
# $repo/rotate.log. Prints the repo dir path.
make_repo() {
    local repo="$WORKDIR/repo-$RANDOM"
    mkdir -p "$repo/docs" "$repo/bin"
    cat > "$repo/docs/history.md" <<'EOF'
### FEATURE: Existing entry (2026-01-20)
Background: existing bg
Changes: existing changes
EOF
    # NOTE: stubs write to a *relative* rotate.log, not an absolute path built
    # from $repo -- backfill-batch.sh cd's into --repo-dir before invoking
    # `uv run bin/*.py`, so cwd is already $repo. Embedding the msys-style
    # absolute path ("/tmp/...") as a literal Python string breaks under the
    # native Windows Python that `uv run` launches (no drive letter).
    cat > "$repo/bin/sort-history.py" <<'EOF'
import sys
with open("rotate.log", "a") as f:
    f.write("sort " + " ".join(sys.argv[1:]) + "\n")
EOF
    cat > "$repo/bin/doc-rotate.py" <<'EOF'
import sys
with open("rotate.log", "a") as f:
    f.write("rotate " + " ".join(sys.argv[1:]) + "\n")
EOF
    : > "$repo/rotate.log"
    echo "$repo"
}

# make_repo_failing_rotate — same as make_repo but doc-rotate.py exits 1.
make_repo_failing_rotate() {
    local repo
    repo=$(make_repo)
    cat > "$repo/bin/doc-rotate.py" <<'EOF'
import sys
with open("rotate.log", "a") as f:
    f.write("rotate " + " ".join(sys.argv[1:]) + "\n")
sys.exit(1)
EOF
    echo "$repo"
}

write_numbers() {
    # write_numbers <file> <content> — writes numbers-file content verbatim.
    printf '%s' "$2" > "$1"
}

# ---------------------------------------------------------------------------
# Case 1: --dry-run — prints parsed numbers + "no writes performed", exit 0,
# no .backfill-appended.txt, history.md byte-identical, issue-to-history.sh
# never invoked.
# ---------------------------------------------------------------------------
CFG1=$(make_config "")
REPO1=$(make_repo)
NUMFILE1="$WORKDIR/numbers1.txt"
write_numbers "$NUMFILE1" $'101\n102\n103\n'
BEFORE_SUM1=$(sha256sum "$REPO1/docs/history.md" | awk '{print $1}')
OUT1=$(AGENTS_CONFIG_DIR="$CFG1" bash "$SCRIPT" --repo-dir "$REPO1" --numbers-file "$NUMFILE1" --dry-run 2>&1)
RC1=$?
AFTER_SUM1=$(sha256sum "$REPO1/docs/history.md" | awk '{print $1}')
CALLS1=$(wc -l < "$CFG1/call.log" | tr -d ' ')
if [ "$RC1" -eq 0 ] \
    && echo "$OUT1" | grep -q "101" && echo "$OUT1" | grep -q "102" && echo "$OUT1" | grep -q "103" \
    && echo "$OUT1" | grep -q "no writes performed" \
    && [ ! -e "$REPO1/.backfill-appended.txt" ] \
    && [ "$BEFORE_SUM1" = "$AFTER_SUM1" ] \
    && [ "$CALLS1" -eq 0 ]; then
    pass "1: --dry-run prints numbers + no-writes message, exit 0, no appended file, history.md unchanged, no invocations"
else
    fail "1: rc=$RC1 calls=$CALLS1 before=$BEFORE_SUM1 after=$AFTER_SUM1 out='$OUT1'"
fi

# ---------------------------------------------------------------------------
# Case 2: happy path, 3 issues — exit 0, appended file has exactly the
# numbers in order, "Appended: 3 / 3", sort/rotate each invoked exactly once.
# ---------------------------------------------------------------------------
CFG2=$(make_config "")
REPO2=$(make_repo)
NUMFILE2="$WORKDIR/numbers2.txt"
write_numbers "$NUMFILE2" $'201\n202\n203\n'
OUT2=$(AGENTS_CONFIG_DIR="$CFG2" bash "$SCRIPT" --repo-dir "$REPO2" --numbers-file "$NUMFILE2" 2>&1)
RC2=$?
APPENDED2=$(cat "$REPO2/.backfill-appended.txt" 2>/dev/null | tr '\n' ' ')
SORT_CALLS2=$(grep -c '^sort ' "$REPO2/rotate.log" 2>/dev/null || echo 0)
ROTATE_CALLS2=$(grep -c '^rotate ' "$REPO2/rotate.log" 2>/dev/null || echo 0)
if [ "$RC2" -eq 0 ] && [ "$APPENDED2" = "201 202 203 " ] \
    && echo "$OUT2" | grep -q "Appended: 3 / 3" \
    && [ "$SORT_CALLS2" -eq 1 ] && [ "$ROTATE_CALLS2" -eq 1 ]; then
    pass "2: happy path 3 issues -- exit 0, appended file exact+ordered, sort/rotate each invoked exactly once"
else
    fail "2: rc=$RC2 appended='$APPENDED2' sort_calls=$SORT_CALLS2 rotate_calls=$ROTATE_CALLS2 out='$OUT2'"
fi

# ---------------------------------------------------------------------------
# Case 3: partial failure -- middle issue fails, loop continues, failed
# number absent from appended file, "FAILED: #N" on stderr, sort/rotate still
# run, non-zero exit.
# ---------------------------------------------------------------------------
CFG3=$(make_config "302")
REPO3=$(make_repo)
NUMFILE3="$WORKDIR/numbers3.txt"
write_numbers "$NUMFILE3" $'301\n302\n303\n'
OUT3=$(AGENTS_CONFIG_DIR="$CFG3" bash "$SCRIPT" --repo-dir "$REPO3" --numbers-file "$NUMFILE3" 2>/tmp/c3.err)
RC3=$?
ERR3=$(cat /tmp/c3.err)
APPENDED3=$(cat "$REPO3/.backfill-appended.txt" 2>/dev/null | tr '\n' ' ')
SORT_CALLS3=$(grep -c '^sort ' "$REPO3/rotate.log" 2>/dev/null || echo 0)
ROTATE_CALLS3=$(grep -c '^rotate ' "$REPO3/rotate.log" 2>/dev/null || echo 0)
if [ "$RC3" -ne 0 ] && [ "$APPENDED3" = "301 303 " ] \
    && echo "$ERR3" | grep -q "FAILED: #302" \
    && [ "$SORT_CALLS3" -eq 1 ] && [ "$ROTATE_CALLS3" -eq 1 ]; then
    pass "3: partial failure -- loop continues, failed number excluded, FAILED logged, sort/rotate still ran, non-zero exit"
else
    fail "3: rc=$RC3 appended='$APPENDED3' sort_calls=$SORT_CALLS3 rotate_calls=$ROTATE_CALLS3 err='$ERR3'"
fi
rm -f /tmp/c3.err

# ---------------------------------------------------------------------------
# Case 4: argument errors -- missing --repo-dir, missing --numbers-file,
# unknown argument.
# ---------------------------------------------------------------------------
CFG4=$(make_config "")
NUMFILE4="$WORKDIR/numbers4.txt"
write_numbers "$NUMFILE4" $'401\n'

OUT4A=$(AGENTS_CONFIG_DIR="$CFG4" bash "$SCRIPT" --numbers-file "$NUMFILE4" 2>&1)
RC4A=$?
if [ "$RC4A" -ne 0 ] && echo "$OUT4A" | grep -qi "usage"; then
    pass "4a: missing --repo-dir -- usage message on stderr, non-zero exit"
else
    fail "4a: rc=$RC4A out='$OUT4A'"
fi

OUT4B=$(AGENTS_CONFIG_DIR="$CFG4" bash "$SCRIPT" --repo-dir "$WORKDIR" 2>&1)
RC4B=$?
if [ "$RC4B" -ne 0 ] && echo "$OUT4B" | grep -qi "usage"; then
    pass "4b: missing --numbers-file -- usage message on stderr, non-zero exit"
else
    fail "4b: rc=$RC4B out='$OUT4B'"
fi

OUT4C=$(AGENTS_CONFIG_DIR="$CFG4" bash "$SCRIPT" --repo-dir "$WORKDIR" --numbers-file "$NUMFILE4" --bogus-flag 2>&1)
RC4C=$?
if [ "$RC4C" -ne 0 ] && echo "$OUT4C" | grep -qi "unknown argument"; then
    pass "4c: unknown argument -- error message on stderr, non-zero exit"
else
    fail "4c: rc=$RC4C out='$OUT4C'"
fi

# ---------------------------------------------------------------------------
# Case 5: AGENTS_CONFIG_DIR unset -- explicit error, non-zero exit.
# ---------------------------------------------------------------------------
REPO5=$(make_repo)
NUMFILE5="$WORKDIR/numbers5.txt"
write_numbers "$NUMFILE5" $'501\n'
OUT5=$(env -u AGENTS_CONFIG_DIR bash "$SCRIPT" --repo-dir "$REPO5" --numbers-file "$NUMFILE5" 2>&1)
RC5=$?
if [ "$RC5" -ne 0 ] && echo "$OUT5" | grep -qi "AGENTS_CONFIG_DIR"; then
    pass "5: AGENTS_CONFIG_DIR unset -- explicit error, non-zero exit"
else
    fail "5: rc=$RC5 out='$OUT5'"
fi

# ---------------------------------------------------------------------------
# Case 6: --repo-dir without docs/history.md; nonexistent --numbers-file.
# ---------------------------------------------------------------------------
CFG6=$(make_config "")
REPO6_NOHIST="$WORKDIR/repo6-nohist"
mkdir -p "$REPO6_NOHIST"
NUMFILE6="$WORKDIR/numbers6.txt"
write_numbers "$NUMFILE6" $'601\n'
OUT6A=$(AGENTS_CONFIG_DIR="$CFG6" bash "$SCRIPT" --repo-dir "$REPO6_NOHIST" --numbers-file "$NUMFILE6" 2>&1)
RC6A=$?
if [ "$RC6A" -ne 0 ] && echo "$OUT6A" | grep -qi "not found" && echo "$OUT6A" | grep -q "history.md"; then
    pass "6a: --repo-dir without docs/history.md -- not-found error, non-zero exit"
else
    fail "6a: rc=$RC6A out='$OUT6A'"
fi

REPO6=$(make_repo)
OUT6B=$(AGENTS_CONFIG_DIR="$CFG6" bash "$SCRIPT" --repo-dir "$REPO6" --numbers-file "$WORKDIR/does-not-exist.txt" 2>&1)
RC6B=$?
if [ "$RC6B" -ne 0 ] && echo "$OUT6B" | grep -qi "not found" && echo "$OUT6B" | grep -q "does-not-exist.txt"; then
    pass "6b: nonexistent --numbers-file -- not-found error, non-zero exit"
else
    fail "6b: rc=$RC6B out='$OUT6B'"
fi

# ---------------------------------------------------------------------------
# Case 7: numbers-file with only blank lines and '#' comments -- "no issue
# numbers" error, non-zero exit.
# ---------------------------------------------------------------------------
CFG7=$(make_config "")
REPO7=$(make_repo)
NUMFILE7="$WORKDIR/numbers7.txt"
write_numbers "$NUMFILE7" $'\n# nothing here\n   \n# another comment\n'
OUT7=$(AGENTS_CONFIG_DIR="$CFG7" bash "$SCRIPT" --repo-dir "$REPO7" --numbers-file "$NUMFILE7" 2>&1)
RC7=$?
if [ "$RC7" -ne 0 ] && echo "$OUT7" | grep -qi "no issue numbers"; then
    pass "7: numbers-file with only blanks/comments -- no-issue-numbers error, non-zero exit"
else
    fail "7: rc=$RC7 out='$OUT7'"
fi

# ---------------------------------------------------------------------------
# Case 8: mixed numbers-file -- valid numbers, blanks, full-line comments,
# inline comments, non-numeric garbage -- exactly the valid numbers extracted.
# ---------------------------------------------------------------------------
CFG8=$(make_config "")
REPO8=$(make_repo)
NUMFILE8="$WORKDIR/numbers8.txt"
write_numbers "$NUMFILE8" $'811\n\n# a full-line comment\n822 # closed last week\nnotanumber\n833\n'
OUT8=$(AGENTS_CONFIG_DIR="$CFG8" bash "$SCRIPT" --repo-dir "$REPO8" --numbers-file "$NUMFILE8" --dry-run 2>&1)
RC8=$?
if [ "$RC8" -eq 0 ] && echo "$OUT8" | grep -q "811" && echo "$OUT8" | grep -q "822" && echo "$OUT8" | grep -q "833" \
    && ! echo "$OUT8" | grep -q "notanumber"; then
    pass "8: mixed numbers-file -- exactly the valid numbers extracted (blanks/comments/inline-comments/garbage excluded)"
else
    fail "8: rc=$RC8 out='$OUT8'"
fi

# ---------------------------------------------------------------------------
# Case 9: error propagation -- doc-rotate.py fails after all issues succeeded
# -- non-zero exit, matching error message.
# ---------------------------------------------------------------------------
CFG9=$(make_config "")
REPO9=$(make_repo_failing_rotate)
NUMFILE9="$WORKDIR/numbers9.txt"
write_numbers "$NUMFILE9" $'901\n902\n'
OUT9=$(AGENTS_CONFIG_DIR="$CFG9" bash "$SCRIPT" --repo-dir "$REPO9" --numbers-file "$NUMFILE9" 2>&1)
RC9=$?
APPENDED9=$(cat "$REPO9/.backfill-appended.txt" 2>/dev/null | tr '\n' ' ')
if [ "$RC9" -ne 0 ] && echo "$OUT9" | grep -qi "doc-rotate.py failed" && [ "$APPENDED9" = "901 902 " ]; then
    pass "9: doc-rotate.py failure after successful issues -- non-zero exit, matching error message"
else
    fail "9: rc=$RC9 appended='$APPENDED9' out='$OUT9'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Tests: bin/cc-session-mtime, bin/cc-session-mtime.ps1
# Tags: bin, mtime, session, pwsh-required, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Actual VS Code restart scenario where the extension writes metadata entries live
# - macOS BSD touch -d format differences from GNU touch (GNU assumed here);
#   this also bounds the dash-leading-timestamp cases below, which were verified
#   against GNU coreutils touch only
# - PS1 timezone edge cases when local TZ differs significantly from UTC
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: pwsh-required

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CC_SESSION_MTIME="$REPO_DIR/bin/cc-session-mtime"
CC_SESSION_MTIME_PS1="$REPO_DIR/bin/cc-session-mtime.ps1"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
skip() { echo "  SKIP: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

make_claude_dir() {
    local d="$1"
    mkdir -p "$d/projects/test-proj"
}

echo "=== cc-session-mtime (bash) tests ==="

# --- Normal: mtime set to last timestamp value ---
echo "[bash] Normal: mtime set to last timestamp value"
CLAUDE1="$TMPDIR_BASE/test1/.claude"
make_claude_dir "$CLAUDE1"
echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE1/projects/test-proj/session.jsonl"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE1/projects/test-proj/session.jsonl"
expected_mtime=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
run_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE1" || run_exit=$?
if [ "$run_exit" -ne 0 ]; then
    fail "mtime set to last timestamp value: cc-session-mtime exited $run_exit (binary missing or error)"
elif [ -n "$expected_mtime" ]; then
    actual=$(stat -c %Y "$CLAUDE1/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
    if [ "$actual" -eq "$expected_mtime" ]; then
        pass "mtime set to last timestamp value"
    else
        fail "mtime wrong: expected $expected_mtime got $actual"
    fi
else
    skip "date -d not available on this platform"
fi

# --- Normal: --dry-run does not change mtime ---
echo "[bash] Normal: --dry-run does not change mtime"
CLAUDE2="$TMPDIR_BASE/test2/.claude"
make_claude_dir "$CLAUDE2"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"hello"}' > "$CLAUDE2/projects/test-proj/session.jsonl"
# Set mtime to a known old value
touch -d "2020-01-01T00:00:00Z" "$CLAUDE2/projects/test-proj/session.jsonl" 2>/dev/null || true
before_mtime=$(stat -c %Y "$CLAUDE2/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
dry_exit=0
dry_output=$("$CC_SESSION_MTIME" --dry-run --claude-dir "$CLAUDE2" 2>&1) || dry_exit=$?
after_mtime=$(stat -c %Y "$CLAUDE2/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
if [ "$dry_exit" -ne 0 ] && [ -z "$dry_output" ]; then
    fail "--dry-run: cc-session-mtime exited $dry_exit (binary missing or error)"
else
    if [ "$before_mtime" -eq "$after_mtime" ]; then
        pass "--dry-run does not change mtime"
    else
        fail "--dry-run changed mtime (before=$before_mtime after=$after_mtime)"
    fi
    if echo "$dry_output" | grep -qi "would"; then
        pass "--dry-run output contains 'would'"
    else
        fail "--dry-run output does not contain 'would': $dry_output"
    fi
fi

# --- Edge: metadata tail — last timestamp line (not last line) is used ---
echo "[bash] Edge: metadata tail — last timestamp line used (bug regression)"
CLAUDE3="$TMPDIR_BASE/test3/.claude"
make_claude_dir "$CLAUDE3"
echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE3/projects/test-proj/session.jsonl"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE3/projects/test-proj/session.jsonl"
echo '{"ai-title":"My session","mode":"auto"}' >> "$CLAUDE3/projects/test-proj/session.jsonl"
expected_mtime=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
run3_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE3" || run3_exit=$?
if [ "$run3_exit" -ne 0 ]; then
    fail "metadata tail: cc-session-mtime exited $run3_exit (binary missing or error)"
elif [ -n "$expected_mtime" ]; then
    actual=$(stat -c %Y "$CLAUDE3/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
    wrong_mtime=$(date -d "2024-06-01T08:00:00.000Z" +%s 2>/dev/null || echo "")
    if [ "$actual" -eq "$expected_mtime" ]; then
        pass "metadata tail: mtime from last timestamp line T2"
    elif [ -n "$wrong_mtime" ] && [ "$actual" -eq "$wrong_mtime" ]; then
        fail "metadata tail: mtime set to T1 (head-1 fallback bug) instead of T2"
    else
        fail "metadata tail: mtime wrong (expected=$expected_mtime got=$actual)"
    fi
else
    skip "date -d not available on this platform"
fi

# --- Edge: no timestamp lines → file skipped, exit 0 ---
echo "[bash] Edge: no timestamp lines → skipped"
CLAUDE4="$TMPDIR_BASE/test4/.claude"
make_claude_dir "$CLAUDE4"
echo '{"ai-title":"no timestamps here","mode":"auto"}' > "$CLAUDE4/projects/test-proj/session.jsonl"
touch -d "2020-01-01T00:00:00Z" "$CLAUDE4/projects/test-proj/session.jsonl" 2>/dev/null || true
before_mtime=$(stat -c %Y "$CLAUDE4/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
exit_code=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE4" 2>/dev/null || exit_code=$?
after_mtime=$(stat -c %Y "$CLAUDE4/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
if [ "$exit_code" -eq 0 ]; then
    pass "no-timestamp file: exit 0"
else
    fail "no-timestamp file: exit $exit_code (expected 0)"
fi
if [ "$before_mtime" -eq "$after_mtime" ]; then
    pass "no-timestamp file: mtime unchanged"
else
    fail "no-timestamp file: mtime changed unexpectedly"
fi

# --- Edge: .history.jsonl is excluded ---
echo "[bash] Edge: .history.jsonl excluded"
CLAUDE5="$TMPDIR_BASE/test5/.claude"
make_claude_dir "$CLAUDE5"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"history entry"}' > "$CLAUDE5/projects/.history.jsonl"
touch -d "2020-01-01T00:00:00Z" "$CLAUDE5/projects/.history.jsonl" 2>/dev/null || true
before_mtime=$(stat -c %Y "$CLAUDE5/projects/.history.jsonl" 2>/dev/null || echo "0")
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE5" 2>/dev/null || true
after_mtime=$(stat -c %Y "$CLAUDE5/projects/.history.jsonl" 2>/dev/null || echo "0")
if [ "$before_mtime" -eq "$after_mtime" ]; then
    pass ".history.jsonl excluded from mtime restore"
else
    fail ".history.jsonl was processed (mtime changed)"
fi

# --- Edge: --claude-dir flag uses specified dir ---
echo "[bash] Edge: --claude-dir flag"
CLAUDE6="$TMPDIR_BASE/test6/.claude"
make_claude_dir "$CLAUDE6"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"hello"}' > "$CLAUDE6/projects/test-proj/session.jsonl"
expected_mtime=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
run6_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE6" || run6_exit=$?
if [ "$run6_exit" -ne 0 ]; then
    fail "--claude-dir: cc-session-mtime exited $run6_exit (binary missing or error)"
elif [ -n "$expected_mtime" ]; then
    actual=$(stat -c %Y "$CLAUDE6/projects/test-proj/session.jsonl" 2>/dev/null || echo "0")
    if [ "$actual" -eq "$expected_mtime" ]; then
        pass "--claude-dir flag uses specified directory"
    else
        fail "--claude-dir: mtime wrong (expected=$expected_mtime got=$actual)"
    fi
else
    skip "date -d not available on this platform"
fi

# --- Edge: dash-leading timestamp values (#1218 hardening regression guard) ---
#
# Scope note (read before changing these assertions):
#   The `touch -d "$ts" "$f"` call here was reported as an option-injection
#   sink. Investigated empirically first: with GNU coreutils touch, the argument
#   after `-d` is bound positionally by getopt, so `--reference=<file>`,
#   `-r<file>`, `-t202001010000` and `--date=@0` are all consumed as the *date
#   operand*, rejected with "invalid date format", and leave the file's mtime
#   unchanged. No option injection was demonstrated. The `case "$ts" in -*)`
#   guard is therefore defense-in-depth, not a vulnerability fix, and the
#   assertions below are a REGRESSION GUARD for the new rejection behavior —
#   they do not claim to demonstrate a blocked exploit.
#
#   Verified against GNU coreutils touch only (Windows Git Bash / MSYS2).
#   BSD/macOS touch was not exercised; see the L3 gap block at the top.
echo "[bash] Edge: dash-leading timestamp values are rejected, not passed to touch"
DASH_MARKER="$TMPDIR_BASE/dash-marker"
: > "$DASH_MARKER"
touch -d "1999-12-31T00:00:00Z" "$DASH_MARKER" 2>/dev/null || true
marker_mtime_before=$(stat -c %Y "$DASH_MARKER" 2>/dev/null || echo "0")
BASELINE_TS="2020-01-01T00:00:00Z"

# Table-driven per skills/_shared/test-design/parser-regex-tests.md: a heredoc
# table read with `while IFS='|' read -r`, so the case name is carried into every
# assertion message and rows can be added without touching the loop body.
#
# Columns: case-name | timestamp value embedded in the JSONL row
#   @MARKER@ expands to $DASH_MARKER — an unrelated, pre-existing file that the
#   option-shaped value points at, so row (4) below can prove it stayed untouched.
while IFS='|' read -r label value; do
    label="${label//[[:space:]]/}"
    case "$label" in ''|'#'*) continue ;; esac
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    value="${value//@MARKER@/$DASH_MARKER}"
    CLAUDE_D="$TMPDIR_BASE/dash-$label/.claude"
    make_claude_dir "$CLAUDE_D"
    target="$CLAUDE_D/projects/test-proj/session.jsonl"
    printf '{"timestamp":"%s","type":"user","text":"x"}\n' "$value" > "$target"
    touch -d "$BASELINE_TS" "$target" 2>/dev/null || true
    before=$(stat -c %Y "$target" 2>/dev/null || echo "0")
    dash_exit=0
    dash_err="$TMPDIR_BASE/dash-$label.err"
    "$CC_SESSION_MTIME" --claude-dir "$CLAUDE_D" 2>"$dash_err" || dash_exit=$?
    after=$(stat -c %Y "$target" 2>/dev/null || echo "0")

    # (1) never fatal — a bad timestamp must not abort the whole sweep
    if [ "$dash_exit" -eq 0 ]; then
        pass "dash timestamp [$label]: exit 0"
    else
        fail "dash timestamp [$label]: exit $dash_exit (expected 0)"
    fi
    # (2) the value must never become the file's mtime
    if [ "$before" -eq "$after" ]; then
        pass "dash timestamp [$label]: target mtime unchanged"
    else
        fail "dash timestamp [$label]: target mtime changed ($before -> $after)"
    fi
    # (3) regression guard for the explicit rejection: the empty-timestamp
    #     warning must fire, so a future refactor cannot silently drop the guard.
    #     RED until `case "$ts" in -*) ts= ;; esac` lands in bin/cc-session-mtime.
    if grep -qi "warn" "$dash_err" 2>/dev/null; then
        pass "dash timestamp [$label]: warns on stderr"
    else
        fail "dash timestamp [$label]: no stderr warning (stderr: $(cat "$dash_err"))"
    fi
done <<'TABLE'
long-option-with-value | --reference=@MARKER@
short-option-attached  | -r@MARKER@
short-option-t-form    | -t202001010000
long-option-date-epoch | --date=@0
bare-dash              | -
double-dash-terminator | --
TABLE

# (4) nothing outside the session file was touched by any of the rows above.
marker_mtime_after=$(stat -c %Y "$DASH_MARKER" 2>/dev/null || echo "0")
if [ "$marker_mtime_before" -eq "$marker_mtime_after" ]; then
    pass "dash timestamp: unrelated file referenced by the value is untouched"
else
    fail "dash timestamp: unrelated file mtime changed ($marker_mtime_before -> $marker_mtime_after)"
fi

# (5) --dry-run must not echo an option-shaped value into a `touch -d` preview.
echo "[bash] Edge: --dry-run does not preview a dash-leading timestamp"
CLAUDE_DRY_DASH="$TMPDIR_BASE/dash-dry/.claude"
make_claude_dir "$CLAUDE_DRY_DASH"
printf '{"timestamp":"--reference=%s","type":"user","text":"x"}\n' "$DASH_MARKER" \
    > "$CLAUDE_DRY_DASH/projects/test-proj/session.jsonl"
dry_dash_out=$("$CC_SESSION_MTIME" --dry-run --claude-dir "$CLAUDE_DRY_DASH" 2>/dev/null) || true
if echo "$dry_dash_out" | grep -q -- "--reference="; then
    fail "--dry-run previewed the dash-leading value (output: $dry_dash_out)"
else
    pass "--dry-run does not preview the dash-leading value"
fi

# --- Edge: non-option garbage timestamp is still non-fatal ---
# Boundary partner to the rows above: a value that does NOT start with a dash
# must keep the current tolerant behavior (touch fails, sweep continues).
echo "[bash] Edge: unparseable non-option timestamp is non-fatal"
CLAUDE_GARBAGE="$TMPDIR_BASE/garbage-ts/.claude"
make_claude_dir "$CLAUDE_GARBAGE"
garbage_target="$CLAUDE_GARBAGE/projects/test-proj/session.jsonl"
echo '{"timestamp":"not-a-real-date","type":"user","text":"x"}' > "$garbage_target"
touch -d "$BASELINE_TS" "$garbage_target" 2>/dev/null || true
garbage_before=$(stat -c %Y "$garbage_target" 2>/dev/null || echo "0")
garbage_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE_GARBAGE" 2>/dev/null || garbage_exit=$?
garbage_after=$(stat -c %Y "$garbage_target" 2>/dev/null || echo "0")
if [ "$garbage_exit" -eq 0 ]; then
    pass "unparseable timestamp: exit 0"
else
    fail "unparseable timestamp: exit $garbage_exit (expected 0)"
fi
if [ "$garbage_before" -eq "$garbage_after" ]; then
    pass "unparseable timestamp: mtime unchanged"
else
    fail "unparseable timestamp: mtime changed ($garbage_before -> $garbage_after)"
fi

# --- Edge: projects directory does not exist ---
# The tool's very first branch. It must report the missing directory and exit 0
# (a machine that has never run Claude Code is a normal state, not an error),
# and it must not create the directory as a side effect.
echo "[bash] Edge: nonexistent projects directory"
CLAUDE_NOPROJ="$TMPDIR_BASE/no-projects/.claude"
mkdir -p "$CLAUDE_NOPROJ"          # .claude exists, projects/ deliberately does not
noproj_err="$TMPDIR_BASE/no-projects.err"
noproj_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE_NOPROJ" 2>"$noproj_err" || noproj_exit=$?
if [ "$noproj_exit" -eq 0 ]; then
    pass "nonexistent projects dir: exit 0"
else
    fail "nonexistent projects dir: exit $noproj_exit (expected 0)"
fi
if grep -qi "not found" "$noproj_err" 2>/dev/null; then
    pass "nonexistent projects dir: reported on stderr"
else
    fail "nonexistent projects dir: silent (stderr: $(cat "$noproj_err"))"
fi
if [ ! -d "$CLAUDE_NOPROJ/projects" ]; then
    pass "nonexistent projects dir: not created as a side effect"
else
    fail "nonexistent projects dir: the tool created $CLAUDE_NOPROJ/projects"
fi

# --- Edge: empty JSONL file (zero bytes) ---
# Boundary partner of the "no timestamp lines" case above: there, the file has
# content but no timestamp; here there is no content at all. Both must be
# skipped without touching the file and without aborting the sweep. A second,
# well-formed file in the same directory pins that the sweep continued past it.
echo "[bash] Edge: empty JSONL file"
CLAUDE_EMPTY="$TMPDIR_BASE/empty-jsonl/.claude"
make_claude_dir "$CLAUDE_EMPTY"
empty_target="$CLAUDE_EMPTY/projects/test-proj/empty.jsonl"
: > "$empty_target"
touch -d "$BASELINE_TS" "$empty_target" 2>/dev/null || true
empty_before=$(stat -c %Y "$empty_target" 2>/dev/null || echo "0")
sibling_target="$CLAUDE_EMPTY/projects/test-proj/sibling.jsonl"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"hi"}' > "$sibling_target"
empty_exit=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE_EMPTY" 2>/dev/null || empty_exit=$?
empty_after=$(stat -c %Y "$empty_target" 2>/dev/null || echo "0")
if [ "$empty_exit" -eq 0 ]; then
    pass "empty JSONL: exit 0"
else
    fail "empty JSONL: exit $empty_exit (expected 0)"
fi
if [ "$empty_before" -eq "$empty_after" ]; then
    pass "empty JSONL: mtime unchanged"
else
    fail "empty JSONL: mtime changed ($empty_before -> $empty_after)"
fi
expected_sibling=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
if [ -z "$expected_sibling" ]; then
    skip "empty JSONL: date -d unavailable — sibling continuation not checked"
elif [ "$(stat -c %Y "$sibling_target" 2>/dev/null || echo 0)" -eq "$expected_sibling" ]; then
    pass "empty JSONL: the sweep continued to the next file"
else
    fail "empty JSONL: the empty file stopped the sweep — sibling mtime not restored"
fi

# --- Security/Edge: path with spaces and shell metacharacters ---
# The filename reaches `grep`, `touch` and the `find | while read -r` pipeline.
# An unquoted expansion anywhere on that path would either lose the file (mtime
# never restored) or evaluate the embedded command substitution (CWE-78).
echo "[bash] Edge: JSONL path with spaces and shell metacharacters"
CLAUDE_META="$TMPDIR_BASE/meta-path/.claude"
make_claude_dir "$CLAUDE_META"
# The tool is run from an empty scratch CWD so that any *relative* side effect an
# evaluated substitution would produce lands somewhere observable (and not in the
# developer's checkout). The payloads stay relative on purpose: a path separator
# inside a filename is not expressible on either filesystem.
META_CWD="$TMPDIR_BASE/meta-cwd"
mkdir -p "$META_CWD"
# Metacharacters chosen to be legal on both NTFS and POSIX filesystems:
# spaces, $(...) command substitution, backticks, ';', '&', quotes.
meta_name="odd \$(touch pwned-subst) name ;& \`touch pwned-backtick\` 'q'.jsonl"
meta_target="$CLAUDE_META/projects/test-proj/$meta_name"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"user","text":"hi"}' > "$meta_target"
touch -d "$BASELINE_TS" "$meta_target" 2>/dev/null || true
meta_exit=0
( cd "$META_CWD" && "$CC_SESSION_MTIME" --claude-dir "$CLAUDE_META" 2>/dev/null ) || meta_exit=$?
if [ "$meta_exit" -eq 0 ]; then
    pass "metacharacter path: exit 0"
else
    fail "metacharacter path: exit $meta_exit (expected 0)"
fi
if [ -z "$(ls -A "$META_CWD" 2>/dev/null)" ]; then
    pass "metacharacter path: embedded command substitution not evaluated"
else
    fail "metacharacter path: embedded command substitution executed (created: $(ls -A "$META_CWD" | tr '\n' ' '))"
fi
expected_meta=$(date -d "2024-06-01T10:30:00.000Z" +%s 2>/dev/null || echo "")
if [ -z "$expected_meta" ]; then
    skip "metacharacter path: date -d unavailable — mtime not checked"
elif [ "$(stat -c %Y "$meta_target" 2>/dev/null || echo 0)" -eq "$expected_meta" ]; then
    pass "metacharacter path: mtime restored despite spaces and metacharacters"
else
    fail "metacharacter path: mtime not restored (got $(stat -c %Y "$meta_target" 2>/dev/null || echo 0), expected $expected_meta)"
fi

# --- Idempotency: a second consecutive run changes nothing ---
# The tool is wired into startup paths, so it runs repeatedly against the same
# tree. Run 2 must leave run 1's mtime exactly as it was and must not add,
# remove or rename anything under projects/.
echo "[bash] Idempotency: second consecutive run is a no-op"
CLAUDE_IDEM="$TMPDIR_BASE/idempotent/.claude"
make_claude_dir "$CLAUDE_IDEM"
idem_target="$CLAUDE_IDEM/projects/test-proj/session.jsonl"
echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$idem_target"
echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$idem_target"
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE_IDEM" 2>/dev/null || true
idem_mtime_1=$(stat -c %Y "$idem_target" 2>/dev/null || echo "0")
idem_listing_1=$(cd "$CLAUDE_IDEM/projects" && find . | LC_ALL=C sort)
idem_sum_1=$(cat "$idem_target")
idem_exit_2=0
"$CC_SESSION_MTIME" --claude-dir "$CLAUDE_IDEM" 2>/dev/null || idem_exit_2=$?
idem_mtime_2=$(stat -c %Y "$idem_target" 2>/dev/null || echo "0")
idem_listing_2=$(cd "$CLAUDE_IDEM/projects" && find . | LC_ALL=C sort)
idem_sum_2=$(cat "$idem_target")
if [ "$idem_exit_2" -eq 0 ]; then
    pass "idempotency: second run exits 0"
else
    fail "idempotency: second run exited $idem_exit_2 (expected 0)"
fi
if [ "$idem_mtime_1" -eq "$idem_mtime_2" ]; then
    pass "idempotency: second run leaves the mtime set by the first run"
else
    fail "idempotency: mtime moved between runs ($idem_mtime_1 -> $idem_mtime_2)"
fi
if [ "$idem_listing_1" = "$idem_listing_2" ] && [ "$idem_sum_1" = "$idem_sum_2" ]; then
    pass "idempotency: second run adds no files and rewrites no content"
else
    fail "idempotency: second run changed the tree or the file content"
fi

echo ""
echo "=== cc-session-mtime.ps1 tests (skipped if pwsh unavailable) ==="

if ! command -v pwsh >/dev/null 2>&1; then
    skip "pwsh not available — PS1 tests skipped"
else
    # --- PS1 Normal: mtime set to last timestamp value ---
    echo "[pwsh] Normal: mtime set to last timestamp value"
    CLAUDE_PS1="$TMPDIR_BASE/test-ps1/.claude"
    make_claude_dir "$CLAUDE_PS1"
    echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE_PS1/projects/test-proj/session.jsonl"
    echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE_PS1/projects/test-proj/session.jsonl"
    ps1_result=$(pwsh -NoProfile -Command "
\$ErrorActionPreference = 'Stop'
& '$(cygpath -w "$CC_SESSION_MTIME_PS1" 2>/dev/null || echo "$CC_SESSION_MTIME_PS1")' -ClaudeDir '$(cygpath -w "$CLAUDE_PS1" 2>/dev/null || echo "$CLAUDE_PS1")'
\$f = Get-Item '$(cygpath -w "$CLAUDE_PS1/projects/test-proj/session.jsonl" 2>/dev/null || echo "$CLAUDE_PS1/projects/test-proj/session.jsonl")'
\$expected = [datetime]::Parse('2024-06-01T10:30:00.000Z').ToLocalTime()
\$diff = [math]::Abs((\$f.LastWriteTime - \$expected).TotalSeconds)
if (\$diff -lt 2) { Write-Output 'PASS' } else { Write-Output \"FAIL: mtime=\$(\$f.LastWriteTime) expected=\$expected\" }
" 2>&1) || true
    if echo "$ps1_result" | grep -q "^PASS"; then
        pass "PS1: mtime set to last timestamp value"
    else
        fail "PS1: mtime wrong: $ps1_result"
    fi

    # --- PS1 Edge: metadata tail ---
    echo "[pwsh] Edge: metadata tail"
    CLAUDE_PS1_2="$TMPDIR_BASE/test-ps1-2/.claude"
    make_claude_dir "$CLAUDE_PS1_2"
    echo '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user","text":"hello"}' > "$CLAUDE_PS1_2/projects/test-proj/session.jsonl"
    echo '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant","text":"world"}' >> "$CLAUDE_PS1_2/projects/test-proj/session.jsonl"
    echo '{"ai-title":"My session","mode":"auto"}' >> "$CLAUDE_PS1_2/projects/test-proj/session.jsonl"
    ps1_result2=$(pwsh -NoProfile -Command "
\$ErrorActionPreference = 'Stop'
& '$(cygpath -w "$CC_SESSION_MTIME_PS1" 2>/dev/null || echo "$CC_SESSION_MTIME_PS1")' -ClaudeDir '$(cygpath -w "$CLAUDE_PS1_2" 2>/dev/null || echo "$CLAUDE_PS1_2")'
\$f = Get-Item '$(cygpath -w "$CLAUDE_PS1_2/projects/test-proj/session.jsonl" 2>/dev/null || echo "$CLAUDE_PS1_2/projects/test-proj/session.jsonl")'
\$expected = [datetime]::Parse('2024-06-01T10:30:00.000Z').ToLocalTime()
\$diff = [math]::Abs((\$f.LastWriteTime - \$expected).TotalSeconds)
if (\$diff -lt 2) { Write-Output 'PASS' } else { Write-Output \"FAIL: mtime=\$(\$f.LastWriteTime) expected=\$expected\" }
" 2>&1) || true
    if echo "$ps1_result2" | grep -q "^PASS"; then
        pass "PS1: metadata tail: mtime from last timestamp line"
    else
        fail "PS1: metadata tail: mtime wrong: $ps1_result2"
    fi
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

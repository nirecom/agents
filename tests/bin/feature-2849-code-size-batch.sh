#!/usr/bin/env bash
# tests/bin/feature-2849-code-size-batch.sh
# Tests: bin/review-code-size
# Tags: TL2, code-size, review, bin, staged, git, decision-time-limit, commit-gate, scope:issue-specific
# #2849 / #2781: review-code-size --staged reads blobs through one `git cat-file --batch`, so its
# git process count does not grow with staged files (counted via GIT_TRACE); verdicts pinned too.
# TL3 gap (what this test does NOT catch):
# - the wall time of a real commit-gate code-size check on a loaded Windows host
# Closest-to-action mitigation: tests/hooks/feature-2849-decision-budget.js (the gate's own fail-open).

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"

export CODE_FILE_EXTENSIONS="js;sh;py"
TOOL="$SCRIPT_CHECKOUT_ROOT/bin/review-code-size"

expect_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then pass "$name"; else fail "$name" "want=[$want] got=[$got]"; fi
}
# expect_le name max got — got is an integer no greater than max.
expect_le() {
  local name="$1" max="$2" got="$3"
  if [[ "$got" =~ ^[0-9]+$ ]] && (( got <= max )); then pass "$name"; else fail "$name" "want<=$max got=[$got]"; fi
}
# A constant that does not depend on the staged-file count (#2849 review C2, user decision A).
MAX_BATCH_READS=2
expect_contains() {
  local name="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"; else fail "$name" "expected [$needle] in: $hay"; fi
}

REPO_SEQ=0
# new_repo — sets REPO to a fresh fixture repo with one baseline commit.
new_repo() {
  REPO_SEQ=$((REPO_SEQ + 1))
  REPO="$TMP_ROOT/repo-$REPO_SEQ"
  mkdir -p "$REPO"
  harness_git_init "$REPO"
  git -C "$REPO" config core.autocrlf false
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "test"
  printf 'baseline\n' > "$REPO/.seed"
  git -C "$REPO" add .seed
  git -C "$REPO" commit -q -m baseline
}
# write_lines <rel> <n> — an n-line file inside the repo.
write_lines() {
  local f="$REPO/$1" i
  mkdir -p "$(dirname "$f")"
  : > "$f"
  for ((i = 1; i <= $2; i++)); do printf 'line %d\n' "$i" >> "$f"; done
}
# stage_files <n> — n staged code files: f1.js is 501 lines (HARD), f2.js 350 (WARN), the rest 5.
stage_files() {
  local n="$1" i
  for ((i = 1; i <= n; i++)); do
    case "$i" in
      1) write_lines "src/f$i.js" 501 ;;
      2) write_lines "src/f$i.js" 350 ;;
      *) write_lines "src/f$i.js" 5 ;;
    esac
  done
  git -C "$REPO" add src
}
# run_traced — the tool with GIT_TRACE on; sets OUT, RC, GIT_PROCS, BATCH_READS, SHOW_READS.
run_traced() {
  local trace="$TMP_ROOT/trace-$REPO_SEQ.log"
  : > "$trace"
  OUT="$(cd "$REPO" && GIT_TRACE="$(np "$trace")" run_with_timeout 120 bash "$TOOL" --staged 2>/dev/null)"
  RC=$?
  GIT_PROCS="$(grep -c 'trace: built-in: git' "$trace")"
  BATCH_READS="$(grep -c 'trace: built-in: git cat-file --batch' "$trace")"
  SHOW_READS="$(grep -cE "trace: built-in: git (show|cat-file 'blob'|cat-file blob)" "$trace")"
}

case_begin "staged-git-processes-do-not-scale-with-files" "bin/review-code-size"
new_repo
stage_files 1
run_traced
ONE_FILE_PROCS="$GIT_PROCS"
expect_le "1 file: blobs read through at most $MAX_BATCH_READS cat-file --batch" "$MAX_BATCH_READS" "$BATCH_READS"
expect_eq "1 file: no per-file git show / cat-file blob" "0" "$SHOW_READS"
new_repo
stage_files 32
run_traced
expect_le "32 files: blobs read through at most $MAX_BATCH_READS cat-file --batch" "$MAX_BATCH_READS" "$BATCH_READS"
expect_eq "32 files: no per-file git show / cat-file blob" "0" "$SHOW_READS"
expect_eq "32 files start as many git processes as 1 file" "$ONE_FILE_PROCS" "$GIT_PROCS"
case_end

case_begin "staged-verdicts-over-many-files" "bin/review-code-size"
new_repo
stage_files 32
run_traced
expect_eq "a HARD file among 32: exit 1" "1" "$RC"
expect_contains "staged mode is reported" "## Code-size Review: PERFORMED (staged mode)" "$OUT"
expect_contains "all 32 files are counted" "Changed code files: 32" "$OUT"
expect_contains "the HARD file is named" "  HARD: src/f1.js — 501 lines total" "$OUT"
expect_contains "the WARN file is named" "WARN: src/f2.js — 350 lines" "$OUT"
expect_contains "a small file is INFO" "INFO: src/f32.js — 5 lines" "$OUT"
case_end

case_begin "staged-no-hard-passes" "bin/review-code-size"
new_repo
write_lines "src/a.js" 350
write_lines "src/b.py" 10
git -C "$REPO" add src
run_traced
expect_eq "WARN only: exit 0" "0" "$RC"
expect_contains "WARN only: the WARN line" "WARN: src/a.js — 350 lines" "$OUT"
case_end

case_begin "staged-nothing-skips" "bin/review-code-size"
new_repo
write_lines "notes.txt" 3
git -C "$REPO" add notes.txt
run_traced
expect_eq "no code file staged: exit 0" "0" "$RC"
expect_contains "no code file staged: SKIPPED" "SKIPPED — no code files staged" "$OUT"
case_end

case_begin "staged-special-path-hard" "bin/review-code-size"
new_repo
write_lines "dir with space/ü-file (1).js" 501
git -C "$REPO" add "dir with space"
run_traced
expect_eq "HARD file under a path with spaces and non-ASCII: exit 1" "1" "$RC"
expect_contains "the special path is named as is" "  HARD: dir with space/ü-file (1).js — 501 lines total" "$OUT"
expect_le "special path: still at most $MAX_BATCH_READS cat-file --batch" "$MAX_BATCH_READS" "$BATCH_READS"
case_end

echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# tests/bin/feature-2473-commit-check-clean.sh
# Tests: bin/github-issues/migration/commit-migration-artifacts.sh
# Tags: TL2, bin, migrate, github-issues, scope:issue-specific, dup-group-keep:size-hard-limit
# Issue #2473 audit run-0021: --check-clean names the allowlist paths with uncommitted changes
# (exit 3) and changes nothing, so the first /migrate-issues run can stop before committing them.
# Contract: the #2473 detail plan, execution order 9.
# TL3 gap: a real /migrate-issues run against a GitHub repo; here every repo is a local fixture.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE
export GIT_CEILING_DIRECTORIES="$TMPBASE"

CMA="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/commit-migration-artifacts.sh"
CMA_REL="bin/github-issues/migration/commit-migration-artifacts.sh"

fx() {
  local d="$TMPBASE/$1"
  harness_git_init "$d"
  git -C "$d" config user.name t
  git -C "$d" config user.email t@example.com
  git -C "$d" config core.autocrlf false
  printf 'fixture\n' >"$d/README"
  git -C "$d" add -A
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}

put() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
}

commit_path() {
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "add $2"
}

# dirty_as <repo> <path> <state> — leaves <path> uncommitted in that state.
dirty_as() {
  case "$3" in
    staged)
      put "$1" "$2" base
      commit_path "$1" "$2"
      put "$1" "$2" edited
      git -C "$1" add -- "$2"
      ;;
    staged-new)
      put "$1" "$2" new
      git -C "$1" add -- "$2"
      ;;
    unstaged)
      put "$1" "$2" base
      commit_path "$1" "$2"
      put "$1" "$2" edited
      ;;
    untracked)
      put "$1" "$2" new
      ;;
    deleted-unstaged)
      put "$1" "$2" base
      commit_path "$1" "$2"
      rm -f -- "$1/$2"
      ;;
    deleted-staged)
      put "$1" "$2" base
      commit_path "$1" "$2"
      git -C "$1" rm -q -- "$2"
      ;;
  esac
}

# run_cc <repo> [skill] — sets RC and OUT (stdout without CR), ERR holds stderr.
run_cc() {
  OUT="$(bash "$CMA" "$1" --skill "${2:-migrate-issues}" --check-clean 2>"$TMPBASE/err")"
  RC=$?
  OUT="${OUT//$'\r'/}"
  ERR="$(cat "$TMPBASE/err")"
}

got() { printf 'rc=%s out=[%s] err=[%s]' "$RC" "$OUT" "$ERR"; }

expect_clean() {
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then pass "$1"; else fail "$1" "want rc=0 and empty stdout; $(got)"; fi
}

expect_dirty() {
  if [[ "$RC" -eq 3 && "$OUT" == "$2" ]]; then pass "$1"; else fail "$1" "want rc=3 and stdout [$2]; $(got)"; fi
}

case_begin "CC-clean" "$CMA_REL"
R="$(fx clean)"
for p in .github/labels.yml .gitignore docs/todo.md; do
  put "$R" "$p" base
  commit_path "$R" "$p"
done
run_cc "$R"
expect_clean "CC-clean: a committed allowlist exits 0 with empty stdout"
case_end

case_begin "CC-no-allowlist-files" "$CMA_REL"
R="$(fx absent)"
run_cc "$R"
expect_clean "CC-no-allowlist-files: a repo holding no allowlist file exits 0"
case_end

case_begin "CC-state-by-entry" "$CMA_REL"
ENTRIES=(.github/labels.yml .github/ISSUE_TEMPLATE/bug.yml .github/workflows/sync-labels.yml .gitignore bin/github-issues/sync-labels.sh docs/todo.md)
for state in staged staged-new unstaged untracked deleted-unstaged deleted-staged; do
  for path in "${ENTRIES[@]}"; do
    name="$state-${path//[\/.]/_}"
    R="$(fx "$name")"
    dirty_as "$R" "$path" "$state"
    run_cc "$R"
    expect_dirty "CC-state-by-entry[$state|$path]: exit 3 naming the path" "$path"
  done
done
case_end

case_begin "CC-near-misses" "$CMA_REL"
while IFS='|' read -r state path; do
  R="$(fx "near-$state-${path//[\/.]/_}")"
  dirty_as "$R" "$path" "$state"
  run_cc "$R"
  expect_clean "CC-near-misses[$state|$path]: outside the allowlist exits 0"
done <<'TABLE'
untracked|.github/labels.yml.bak
untracked|docs/todo.md.orig
untracked|docs/other.md
untracked|.github/workflows/other.yml
untracked|.github/ISSUE_TEMPLATE.bak/bug.yml
untracked|src/a.sh
staged|.github/labels.yml.bak
staged|docs/todo.md.orig
staged|docs/other.md
staged|.github/workflows/other.yml
staged|.github/ISSUE_TEMPLATE.bak/bug.yml
staged|src/a.sh
deleted-unstaged|docs/other.md
deleted-staged|.github/ISSUE_TEMPLATE.bak/bug.yml
TABLE
case_end

case_begin "CC-agents-json-excluded" "$CMA_REL"
for state in untracked unstaged staged; do
  R="$(fx "agents-$state")"
  dirty_as "$R" .agents.json "$state"
  run_cc "$R"
  expect_clean "CC-agents-json-excluded[$state]: .agents.json alone exits 0"
done
case_end

case_begin "CC-mixed" "$CMA_REL"
R="$(fx mixed)"
dirty_as "$R" .agents.json untracked
dirty_as "$R" src/a.sh untracked
dirty_as "$R" .gitignore unstaged
run_cc "$R"
expect_dirty "CC-mixed: only the allowlist path is named beside .agents.json and an outside change" ".gitignore"

R="$(fx mixed-two)"
dirty_as "$R" .gitignore unstaged
dirty_as "$R" docs/todo.md untracked
dirty_as "$R" src/a.sh untracked
run_cc "$R"
SORTED="$(printf '%s\n' "$OUT" | LC_ALL=C sort)"
if [[ "$RC" -eq 3 && "$SORTED" == $'.gitignore\ndocs/todo.md' ]]; then
  pass "CC-mixed: two allowlist paths are named one per line"
else
  fail "CC-mixed: two allowlist paths" "want rc=3 with both paths; $(got)"
fi
case_end

case_begin "CC-no-side-effects" "$CMA_REL"
R="$(fx effects)"
dirty_as "$R" .gitignore staged
dirty_as "$R" docs/todo.md unstaged
dirty_as "$R" .github/labels.yml untracked
dirty_as "$R" src/a.sh staged-new
snapshot() {
  git -C "$R" status --porcelain
  git -C "$R" diff --cached
  git -C "$R" diff
  git -C "$R" rev-parse HEAD
  git -C "$R" rev-list --count HEAD
  cat "$R/.gitignore" "$R/docs/todo.md" "$R/.github/labels.yml" "$R/src/a.sh"
}
BEFORE="$(snapshot)"
run_cc "$R"
AFTER="$(snapshot)"
if [[ "$RC" -eq 3 ]]; then
  pass "CC-no-side-effects: the dirty fixture is reported"
else
  fail "CC-no-side-effects: the dirty fixture is reported" "want rc=3; $(got)"
fi
if [[ "$RC" -eq 3 && "$BEFORE" == "$AFTER" ]]; then
  pass "CC-no-side-effects: index, worktree and history are unchanged"
else
  fail "CC-no-side-effects: index, worktree and history are unchanged" "$(got)"
fi
case_end

case_begin "CC-other-skills" "$CMA_REL"
for skill in migrate-tracker migrate-tests migrate; do
  R="$(fx "skill-$skill")"
  dirty_as "$R" .gitignore unstaged
  run_cc "$R" "$skill"
  expect_clean "CC-other-skills[$skill]: a dirty .gitignore exits 0"
  dirty_as "$R" .agents.json untracked
  run_cc "$R" "$skill"
  expect_clean "CC-other-skills[$skill]: a dirty .agents.json exits 0"
done
case_end

# The primary repo ignores docs: a pathspec through the symlink makes git fail, so the check must go to the docs repo.
symln() { MSYS="winsymlinks:nativestrict" ln -sfn "$1" "$2" 2>/dev/null || ln -sfn "$1" "$2" 2>/dev/null || true; }
docs_fx() {
  local docs="$TMPBASE/$1-docs" primary
  harness_git_init "$docs"
  git -C "$docs" config user.name t
  git -C "$docs" config user.email t@example.com
  git -C "$docs" config core.autocrlf false
  put "$docs" projects/app/todo.md base
  put "$docs" projects/app/other.md base
  put "$docs" projects/sibling/todo.md base
  git -C "$docs" add -A
  git -C "$docs" commit -q -m init
  primary="$(fx "$1-primary")"
  put "$primary" .gitignore docs
  commit_path "$primary" .gitignore
  symln "$docs/projects/app" "$primary/docs"
  DOCS="$docs"
  PRIMARY="$primary"
}

case_begin "CC-external-docs" "$CMA_REL"
docs_fx probe
if [[ ! -L "$PRIMARY/docs" ]]; then
  skip "CC-external-docs: symlinks not available"
else
  run_cc "$PRIMARY"
  expect_clean "CC-external-docs: a clean docs repo exits 0"

  put "$DOCS" projects/app/todo.md edited
  run_cc "$PRIMARY"
  if [[ "$RC" -eq 3 && "$OUT" == *todo.md* ]]; then
    pass "CC-external-docs: a change to docs/todo.md in the docs repo exits 3"
  else
    fail "CC-external-docs: a change to docs/todo.md in the docs repo exits 3" "$(got)"
  fi
  git -C "$DOCS" checkout -q -- projects/app/todo.md

  put "$DOCS" projects/app/other.md edited
  run_cc "$PRIMARY"
  expect_clean "CC-external-docs: another file of the project in the docs repo exits 0"
  git -C "$DOCS" checkout -q -- projects/app/other.md

  put "$DOCS" projects/sibling/todo.md edited
  run_cc "$PRIMARY"
  expect_clean "CC-external-docs: the todo.md of another project in the docs repo exits 0"
fi
case_end

case_begin "CC-git-failure" "$CMA_REL"
NOT_GIT="$TMPBASE/not-git"
mkdir -p "$NOT_GIT"
put "$NOT_GIT" .gitignore edited
run_cc "$NOT_GIT"
if [[ "$RC" -eq 1 && "$ERR" != *"unknown arg"* ]]; then
  pass "CC-git-failure: a root that is no git checkout exits 1"
else
  fail "CC-git-failure: a root that is no git checkout exits 1" "$(got)"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] || exit 1

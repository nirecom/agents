# Commit time: a real `git commit` in a fixture repo whose core.hooksPath names the hooks
# directory of this checkout — the way the installer wires a repo (#2411). Sourced by
# tests/hooks/feature-2411-gate-integration.sh. Only these copies arm a hook; the template
# keeps /dev/null.
# shellcheck shell=bash

echo ""
echo "=== commit: real git commit through hooks/pre-commit ==="

# new_repo <name> <armed|unarmed> — a copy of the template. Sets R.
new_repo() {
  R="$TMPBASE/repo-$1"
  cp -R "$TEMPLATE" "$R"
  if [ "$2" = armed ]; then
    git -C "$R" config core.hooksPath "$(np "$HOOKS_DIR")"
  fi
}

# stage_new <repo> <rel> <body-name> — a new test file, staged; a bash one staged executable.
stage_new() {
  mkdir -p "$(dirname "$1/$2")"
  cp "$BODIES/$3" "$1/$2"
  git -C "$1" add -- "$2" >/dev/null 2>&1
  case "$2" in
    *.sh) git -C "$1" update-index --chmod=+x -- "$2" >/dev/null 2>&1 ;;
  esac
}

# commit_try <repo> — sets COUT (stdout and stderr), CRC, CHEAD (commit count after).
COUT=""; CRC=0; CHEAD=0
commit_try() {
  CRC=0
  COUT="$(cd "$1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX && export ENFORCE_WORKTREE=off && \
      export AGENTS_MAIN_ROOT="$(np "$EMPTY_ROOT")" && run_with_timeout 60 git commit -q -m gate 2>&1)" || CRC=$?
  CHEAD="$(git -C "$1" rev-list --count HEAD 2>/dev/null)"
}

# in_head <repo> <rel> — prints yes or no.
in_head() {
  if git -C "$1" cat-file -e "HEAD:$2" 2>/dev/null; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# commit_pair <language id> — both verdicts for one language, each in its own armed repo.
commit_pair() {
  local lang="$1" rel flat
  lang_set "$lang" "gate-new"
  rel="tests/hooks/$LF"

  new_repo "$lang-ok" armed
  stage_new "$R" "$rel" "$LBODY-conforming"
  commit_try "$R"
  flat="$(printf '%s' "$COUT" | tr '\n' ' ')"
  if [ "$CRC" -eq 0 ] && [ "$CHEAD" = 2 ] && [ "$(in_head "$R" "$rel")" = yes ]; then
    pass "$lang conforming: commit lands with $rel in HEAD"
  else
    fail "$lang conforming: commit" "rc=$CRC commits=$CHEAD in-head=$(in_head "$R" "$rel") out=$flat"
  fi

  if ! command -v "$LREQ" >/dev/null 2>&1; then
    skip "$lang without markers: $LREQ not on PATH, its case reader cannot run"
    return 0
  fi
  new_repo "$lang-missing" armed
  stage_new "$R" "$rel" "$LBODY-missing"
  commit_try "$R"
  flat="$(printf '%s' "$COUT" | tr '\n' ' ')"
  if [ "$CRC" -ne 0 ] && [ "$CHEAD" = 1 ] && [ "$(in_head "$R" "$rel")" = no ]; then
    pass "$lang without markers: commit refused, HEAD unchanged"
  else
    fail "$lang without markers: commit" "rc=$CRC commits=$CHEAD in-head=$(in_head "$R" "$rel") out=$flat"
  fi
  has "$lang without markers: names the file" "$COUT" "HIGH: $rel "
  has "$lang without markers: closing line" "$COUT" "$BLOCKED_LINE"
}

case_begin "commit-bash-both-verdicts" "hooks/pre-commit"
commit_pair bash
case_end

case_begin "commit-refusal-comes-from-the-installed-hook" "hooks/pre-commit"
lang_set bash "gate-new"
new_repo "bash-unarmed" unarmed
stage_new "$R" "tests/hooks/$LF" "sh-missing"
commit_try "$R"
if [ "$CRC" -eq 0 ] && [ "$CHEAD" = 2 ]; then
  pass "same file commits when core.hooksPath is /dev/null: the refusal is the hook's"
else
  fail "unarmed repo commit" "rc=$CRC commits=$CHEAD out=$(printf '%s' "$COUT" | tr '\n' ' ')"
fi
case_end

case_begin "commit-pester-both-verdicts" "hooks/pre-commit"
commit_pair pester
case_end

case_begin "commit-pytest-both-verdicts" "hooks/pre-commit"
commit_pair pytest
case_end

case_begin "commit-js-both-verdicts" "hooks/pre-commit"
commit_pair js
case_end

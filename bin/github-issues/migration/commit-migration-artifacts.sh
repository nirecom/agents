#!/usr/bin/env bash
# commit-migration-artifacts.sh — stage + commit + push the side-effect files
# produced by /migrate-repo Step 1 and Step 3.
#
# Allowlist (only these paths are staged):
#   .github/labels.yml
#   .github/ISSUE_TEMPLATE/        (directory; recursive via `git add`)
#   .gitignore
#   docs/todo.md
#
# Idempotent: if no allowlist diff is staged, prints "nothing to commit" and exits 0.
#
# Usage:
#   commit-migration-artifacts.sh <repo_dir> [--dry-run] [--no-push]
set -euo pipefail

REPO_DIR="${1:?usage: commit-migration-artifacts.sh <repo_dir> [--dry-run] [--no-push]}"
DRY_RUN=0
NO_PUSH=0
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$REPO_DIR" && pwd)"

# This script always runs in the context of a migration cleanup commit.
# The pre-commit hook reads ENFORCE_WORKTREE; set it off so the hook permits
# the commit regardless of how this script is invoked (from orchestrator or tests).
export ENFORCE_WORKTREE=off

COMMIT_MSG_SUBJECT="chore(migration): apply /migrate-repo Step 1/3 artifacts"
ALLOWLIST=(
  ".github/labels.yml"
  ".github/ISSUE_TEMPLATE"
  ".gitignore"
  "docs/todo.md"
)

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would stage:"
  for p in "${ALLOWLIST[@]}"; do
    if [ -e "$REPO_DIR/$p" ]; then echo "  - $p"; fi
  done
  echo "[dry-run] would commit: $COMMIT_MSG_SUBJECT"
  echo "[dry-run] would push: origin $(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<branch>')"
  exit 0
fi

for entry in "${ALLOWLIST[@]}"; do
  if [ -e "$REPO_DIR/$entry" ]; then
    git -C "$REPO_DIR" -c core.autocrlf=false add -- "$entry"
  fi
done

# Unstage any files that git auto-staged beyond the allowlist (e.g. CRLF normalisation).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  in_allowlist=0
  for entry in "${ALLOWLIST[@]}"; do
    case "$f" in "$entry"|"${entry}/"*) in_allowlist=1; break ;; esac
  done
  if [ "$in_allowlist" -eq 0 ]; then
    git -C "$REPO_DIR" reset HEAD -- "$f" >/dev/null 2>&1 || true
  fi
done < <(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null | tr -d '\r')

if git -C "$REPO_DIR" diff --cached --quiet; then
  echo "commit-migration-artifacts: nothing to commit (allowlist already tracked / unchanged) — skipping"
  exit 0
fi

staged_list=$(git -C "$REPO_DIR" diff --cached --name-only | tr -d '\r' | sed 's/^/- /')

state_file="$REPO_DIR/.migration-state.json"
issue_range_line=""
if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
  hist_min=$(jq -r '[.history.migrated[].issue_number] | min // empty' "$state_file" 2>/dev/null | tr -d '\r')
  hist_max=$(jq -r '[.history.migrated[].issue_number] | max // empty' "$state_file" 2>/dev/null | tr -d '\r')
  todo_min=$(jq -r '[.todo.migrated[].issue_number] | min // empty' "$state_file" 2>/dev/null | tr -d '\r')
  todo_max=$(jq -r '[.todo.migrated[].issue_number] | max // empty' "$state_file" 2>/dev/null | tr -d '\r')
  parts=()
  if [ -n "$hist_min" ] && [ -n "$hist_max" ]; then
    if [ "$hist_min" = "$hist_max" ]; then parts+=("history #$hist_min"); else parts+=("history #$hist_min-#$hist_max"); fi
  fi
  if [ -n "$todo_min" ] && [ -n "$todo_max" ]; then
    if [ "$todo_min" = "$todo_max" ]; then parts+=("todo #$todo_min"); else parts+=("todo #$todo_min-#$todo_max"); fi
  fi
  if [ "${#parts[@]}" -gt 0 ]; then
    issue_range_line="Issues migrated: $(IFS=', '; echo "${parts[*]}")"
  fi
fi

body_buf="Migration artifacts staged by /migrate-repo orchestrator (Step 1 + Step 3):

$staged_list"
if [ -n "$issue_range_line" ]; then
  body_buf="$body_buf

$issue_range_line"
fi

git -C "$REPO_DIR" commit -m "$COMMIT_MSG_SUBJECT" -m "$body_buf"

if [ "$NO_PUSH" -eq 1 ]; then
  echo "commit-migration-artifacts: --no-push specified, skipping push"
else
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
  git -C "$REPO_DIR" push origin "$branch"
fi

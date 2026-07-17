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
  ".github/workflows/sync-labels.yml"
  ".gitignore"
  "bin/github-issues/sync-labels.sh"
  "docs/todo.md"
)

# resolve_external_docs_repo: detects when docs/ is a symlink to a separate git root.
# Sets DOCS_REPO_DIR (absolute path to docs-repo root) and DOCS_PREFIX (relative path
# from docs-repo root to the symlink target, with trailing slash).
# Returns 0 when an external docs-repo is detected, 1 otherwise.
resolve_external_docs_repo() {
  DOCS_REPO_DIR=""
  DOCS_PREFIX=""
  local docs_link="$REPO_DIR/docs"
  [ -L "$docs_link" ] || return 1
  local docs_target
  docs_target=$(cd "$docs_link" && git rev-parse --show-toplevel 2>/dev/null) || return 1
  local primary_top
  primary_top=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$docs_target" != "$primary_top" ] || return 1
  DOCS_REPO_DIR="$docs_target"
  local prefix
  prefix=$(cd "$docs_link" && git rev-parse --show-prefix 2>/dev/null) || return 1
  DOCS_PREFIX="$prefix"   # e.g. "projects/engineering/repo-name/"
  return 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would stage:"
  for p in "${ALLOWLIST[@]}"; do
    if [ -e "$REPO_DIR/$p" ]; then echo "  - $p"; fi
  done
  echo "[dry-run] would commit: $COMMIT_MSG_SUBJECT"
  echo "[dry-run] would push: origin $(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<branch>')"
  if resolve_external_docs_repo; then
    echo "[dry-run] docs/ is an external symlink → would also commit docs entries to: $DOCS_REPO_DIR"
  fi
  exit 0
fi

DOCS_REPO_DIR=""
DOCS_PREFIX=""
if resolve_external_docs_repo; then
  HAS_EXTERNAL_DOCS=1
else
  HAS_EXTERNAL_DOCS=0
fi

for entry in "${ALLOWLIST[@]}"; do
  if [ -e "$REPO_DIR/$entry" ]; then
    case "$entry" in
      docs/*)
        if [ "$HAS_EXTERNAL_DOCS" -eq 1 ]; then
          continue   # handled separately below
        fi
        ;;
    esac
    git -C "$REPO_DIR" -c core.autocrlf=false add -- "$entry"
  fi
done

# Ensure staged .sh files carry the executable bit in the git index, so the
# pre-commit hook (which requires 100755 on .sh files) does not reject the
# commit on platforms where core.filemode=false (e.g. Windows).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.sh)
      mode=$(git -C "$REPO_DIR" ls-files -s -- "$f" 2>/dev/null | awk '{print $1}')
      if [ "$mode" = "100644" ]; then
        git -C "$REPO_DIR" update-index --chmod=+x -- "$f" >/dev/null 2>&1 || true
      fi
      ;;
  esac
done < <(git -C "$REPO_DIR" diff --cached --name-only 2>/dev/null | tr -d '\r')

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

# If docs/ is a symlink to an external git repo, commit docs/ entries there separately.
if [ "$HAS_EXTERNAL_DOCS" -eq 1 ]; then
  DOCS_STAGED=0
  for entry in "${ALLOWLIST[@]}"; do
    case "$entry" in
      docs/*)
        local_path="$REPO_DIR/$entry"
        if [ -e "$local_path" ]; then
          rel="${entry#docs/}"
          docs_path="${DOCS_PREFIX}${rel}"
          git -C "$DOCS_REPO_DIR" -c core.autocrlf=false add -- "$docs_path" || true
          DOCS_STAGED=1
        fi
        ;;
    esac
  done
  if [ "$DOCS_STAGED" -eq 1 ] && ! git -C "$DOCS_REPO_DIR" diff --cached --quiet 2>/dev/null; then
    git -C "$DOCS_REPO_DIR" commit -m "$COMMIT_MSG_SUBJECT" -m "$body_buf"
    if [ "$NO_PUSH" -eq 1 ]; then
      echo "commit-migration-artifacts: --no-push specified, skipping push for docs-repo"
    else
      docs_branch=$(git -C "$DOCS_REPO_DIR" rev-parse --abbrev-ref HEAD)
      git -C "$DOCS_REPO_DIR" push origin "$docs_branch"
    fi
  fi
fi

if [ "$NO_PUSH" -eq 1 ]; then
  echo "commit-migration-artifacts: --no-push specified, skipping push"
else
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
  git -C "$REPO_DIR" push origin "$branch"
fi

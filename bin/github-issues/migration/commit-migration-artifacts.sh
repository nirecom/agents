#!/usr/bin/env bash
# commit-migration-artifacts.sh — stage + commit + push the files a /migrate-* skill wrote (#2473).
# --skill names the caller and fixes what is staged:
#   migrate-issues   the /migrate-issues Step 1/3 allowlist below plus .agents.json
#   migrate-tracker, migrate-tests, migrate (the /migrate left-over recovery)   .agents.json only
# Idempotent: nothing changed in the allowlist → "nothing to commit", exit 0; an allowlist commit
# still missing from origin (an earlier failed push) is pushed then, unless --no-push.
# --check-clean (wins over --dry-run and --no-push) changes nothing: it prints the allowlist paths
# with uncommitted changes one per line and exits 3, exits 0 when there are none, 1 when git fails.
# Usage:
#   commit-migration-artifacts.sh <repo_dir> --skill migrate-issues|migrate-tracker|migrate-tests|migrate [--dry-run] [--no-push] [--check-clean]
set -euo pipefail

USAGE="usage: commit-migration-artifacts.sh <repo_dir> --skill migrate-issues|migrate-tracker|migrate-tests|migrate [--dry-run] [--no-push] [--check-clean]"
TARGET_CHECKOUT_ROOT="${1:?$USAGE}"
DRY_RUN=0
NO_PUSH=0
CHECK_CLEAN=0
SKILL=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    --check-clean) CHECK_CLEAN=1; shift ;;
    --skill)
      [ $# -ge 2 ] || { echo "--skill requires a value; $USAGE" >&2; exit 1; }
      SKILL="$2"; shift 2 ;;
    --skill=*) SKILL="${1#--skill=}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
case "$SKILL" in
  migrate-issues|migrate-tracker|migrate-tests|migrate) ;;
  "") echo "--skill is required; $USAGE" >&2; exit 1 ;;
  *) echo "unknown --skill: $SKILL; $USAGE" >&2; exit 1 ;;
esac

TARGET_CHECKOUT_ROOT="$(cd "$TARGET_CHECKOUT_ROOT" && pwd)"

# This script always runs in the context of a migration cleanup commit.
# The pre-commit hook reads ENFORCE_WORKTREE; set it off so the hook permits
# the commit regardless of how this script is invoked (from orchestrator or tests).
export ENFORCE_WORKTREE=off

if [ "$SKILL" = migrate-issues ]; then
  COMMIT_MSG_SUBJECT="chore(migration): apply /migrate-issues Step 1/3 artifacts"
  BODY_LEAD="Migration artifacts staged by /migrate-issues orchestrator (Step 1 + Step 3):"
  ALLOWLIST=(
    ".github/labels.yml"
    ".github/ISSUE_TEMPLATE"
    ".github/workflows/sync-labels.yml"
    ".gitignore"
    "bin/github-issues/sync-labels.sh"
    "docs/todo.md"
    ".agents.json"
  )
else
  COMMIT_MSG_SUBJECT="chore(migration): record /$SKILL in .agents.json"
  BODY_LEAD="Repo settings written by /$SKILL:"
  ALLOWLIST=(".agents.json")
fi

# resolve_external_docs_repo: detects when docs/ is a symlink to a separate git root.
# Sets DOCS_REPO_DIR (absolute path to docs-repo root) and DOCS_PREFIX (relative path
# from docs-repo root to the symlink target, with trailing slash).
# Returns 0 when an external docs-repo is detected, 1 otherwise.
resolve_external_docs_repo() {
  DOCS_REPO_DIR=""
  DOCS_PREFIX=""
  local docs_link="$TARGET_CHECKOUT_ROOT/docs"
  [ -L "$docs_link" ] || return 1
  local docs_target
  docs_target=$(cd "$docs_link" && git rev-parse --show-toplevel 2>/dev/null) || return 1
  local primary_top
  primary_top=$(git -C "$TARGET_CHECKOUT_ROOT" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$docs_target" != "$primary_top" ] || return 1
  DOCS_REPO_DIR="$docs_target"
  local prefix
  prefix=$(cd "$docs_link" && git rev-parse --show-prefix 2>/dev/null) || return 1
  DOCS_PREFIX="$prefix"   # e.g. "projects/engineering/repo-name/"
  return 0
}

# uncommitted_paths <repo_dir> <path>... — those paths (a directory covers its files) with uncommitted changes.
# --no-optional-locks keeps status from refreshing the index, so the check writes nothing.
uncommitted_paths() {
  local repo="$1" rec entry
  shift
  git --no-optional-locks -C "$repo" status --porcelain -z -uall --no-renames |
    while IFS= read -r -d '' rec; do
      for entry in "$@"; do
        case "${rec:3}" in "$entry"|"$entry/"*) printf '%s\n' "${rec:3}"; break ;; esac
      done
    done
}

# check_clean — .agents.json stays out: repo-settings writes it and /migrate recovery commits any remainder.
# docs/ entries of an external docs repo are looked up there and reported as docs/<file>, as in the allowlist.
check_clean() {
  local entry path has_docs=0 root_out docs_out=""
  local root_entries=() docs_paths=()
  resolve_external_docs_repo && has_docs=1
  for entry in "${ALLOWLIST[@]}"; do
    case "$entry" in
      .agents.json) ;;
      docs/*)
        if [ "$has_docs" -eq 1 ]; then docs_paths+=("$DOCS_PREFIX${entry#docs/}"); else root_entries+=("$entry"); fi ;;
      *) root_entries+=("$entry") ;;
    esac
  done
  [ "${#root_entries[@]}" -gt 0 ] || return 0
  root_out=$(uncommitted_paths "$TARGET_CHECKOUT_ROOT" "${root_entries[@]}") || return 1
  if [ "${#docs_paths[@]}" -gt 0 ]; then
    docs_out=$(uncommitted_paths "$DOCS_REPO_DIR" "${docs_paths[@]}") || return 1
  fi
  [ -n "$root_out$docs_out" ] || return 0
  [ -z "$root_out" ] || printf '%s\n' "$root_out"
  if [ -n "$docs_out" ]; then
    while IFS= read -r path; do printf 'docs/%s\n' "${path#"$DOCS_PREFIX"}"; done <<<"$docs_out"
  fi
  return 3
}

if [ "$CHECK_CLEAN" -eq 1 ]; then
  check_clean
  exit $?
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would stage:"
  for p in "${ALLOWLIST[@]}"; do
    if [ -e "$TARGET_CHECKOUT_ROOT/$p" ]; then echo "  - $p"; fi
  done
  echo "[dry-run] would commit: $COMMIT_MSG_SUBJECT"
  if [ "$NO_PUSH" -eq 0 ]; then
    echo "[dry-run] would push: origin $(git -C "$TARGET_CHECKOUT_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo '<branch>')"
  fi
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
  if [ -e "$TARGET_CHECKOUT_ROOT/$entry" ]; then
    case "$entry" in
      docs/*)
        if [ "$HAS_EXTERNAL_DOCS" -eq 1 ]; then
          continue   # handled separately below
        fi
        ;;
    esac
    git -C "$TARGET_CHECKOUT_ROOT" -c core.autocrlf=false add -- "$entry"
  fi
done

# restore_unrelated_staging — EXIT trap. A failed restore keeps the patch, the only copy of that
# staging, and exits non-zero even after a successful commit so the caller cannot miss it.
restore_unrelated_staging() {
  local rc=$?
  trap - EXIT
  if git -C "$TARGET_CHECKOUT_ROOT" apply --cached --whitespace=nowarn "$UNRELATED_PATCH"; then
    rm -f "$UNRELATED_PATCH"
  else
    echo "commit-migration-artifacts: could not restore the staging of files outside the allowlist; it is kept in $UNRELATED_PATCH (re-apply with: git apply --cached <that file>)" >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}

# Hold files staged outside the allowlist (the user's own work, or CRLF normalisation) out of the
# commit: unstage them here, and the trap gives them back after the commit on every exit path.
unrelated_paths=()
while IFS= read -r -d '' f; do
  in_allowlist=0
  for entry in "${ALLOWLIST[@]}"; do
    case "$f" in "$entry"|"${entry}/"*) in_allowlist=1; break ;; esac
  done
  [ "$in_allowlist" -eq 1 ] || unrelated_paths+=("$f")
done < <(git -C "$TARGET_CHECKOUT_ROOT" diff --cached --no-renames --name-only -z 2>/dev/null)

if [ "${#unrelated_paths[@]}" -gt 0 ]; then
  UNRELATED_PATCH=$(mktemp "$(git -C "$TARGET_CHECKOUT_ROOT" rev-parse --absolute-git-dir)/migrate-unrelated-staging.XXXXXX")
  # The flags pin the patch format against user diff config that git apply could not read back.
  git --literal-pathspecs -C "$TARGET_CHECKOUT_ROOT" diff --cached --binary --no-renames --no-ext-diff --no-textconv --no-color --unified=3 --src-prefix=a/ --dst-prefix=b/ -- "${unrelated_paths[@]}" >"$UNRELATED_PATCH" || { rm -f "$UNRELATED_PATCH"; exit 1; }
  trap restore_unrelated_staging EXIT
  git --literal-pathspecs -C "$TARGET_CHECKOUT_ROOT" reset -q -- "${unrelated_paths[@]}"
fi

# Ensure staged .sh files carry the executable bit in the git index, so the
# pre-commit hook (which requires 100755 on .sh files) does not reject the
# commit on platforms where core.filemode=false (e.g. Windows).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.sh)
      mode=$(git -C "$TARGET_CHECKOUT_ROOT" ls-files -s -- "$f" 2>/dev/null | awk '{print $1}')
      if [ "$mode" = "100644" ]; then
        git -C "$TARGET_CHECKOUT_ROOT" update-index --chmod=+x -- "$f" >/dev/null 2>&1 || true
      fi
      ;;
  esac
done < <(git -C "$TARGET_CHECKOUT_ROOT" diff --cached --name-only 2>/dev/null | tr -d '\r')

push_branch() {
  local branch
  branch=$(git -C "$TARGET_CHECKOUT_ROOT" rev-parse --abbrev-ref HEAD)
  git -C "$TARGET_CHECKOUT_ROOT" push origin "$branch"
}

# unpushed_allowlist_commits — allowlist commits ahead of origin/<current branch>, the push target
# (else of every origin ref): a run whose push failed after its commit. Empty when there is no origin remote.
unpushed_allowlist_commits() {
  git -C "$TARGET_CHECKOUT_ROOT" remote get-url origin >/dev/null 2>&1 || return 0
  local range=(HEAD --not --remotes=origin)
  local branch target
  branch=$(git -C "$TARGET_CHECKOUT_ROOT" symbolic-ref --short -q HEAD 2>/dev/null) || branch=""
  target="refs/remotes/origin/$branch"
  if [ -n "$branch" ] && git -C "$TARGET_CHECKOUT_ROOT" rev-parse --verify -q "$target" >/dev/null 2>&1; then
    range=("$target..HEAD")
  fi
  git -C "$TARGET_CHECKOUT_ROOT" rev-list "${range[@]}" -- "${ALLOWLIST[@]}" 2>/dev/null || true
}

if git -C "$TARGET_CHECKOUT_ROOT" diff --cached --quiet; then
  echo "commit-migration-artifacts: nothing to commit (allowlist already tracked / unchanged) — skipping"
  if [ "$NO_PUSH" -eq 0 ] && [ -n "$(unpushed_allowlist_commits)" ]; then
    echo "commit-migration-artifacts: an earlier migration commit is not on origin yet — pushing it"
    push_branch
  fi
  exit 0
fi

staged_list=$(git -C "$TARGET_CHECKOUT_ROOT" diff --cached --name-only | tr -d '\r' | sed 's/^/- /')

state_file="$TARGET_CHECKOUT_ROOT/.migration-state.json"
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

body_buf="$BODY_LEAD

$staged_list"
if [ -n "$issue_range_line" ]; then
  body_buf="$body_buf

$issue_range_line"
fi

git -C "$TARGET_CHECKOUT_ROOT" commit -m "$COMMIT_MSG_SUBJECT" -m "$body_buf"

# If docs/ is a symlink to an external git repo, commit docs/ entries there separately.
if [ "$HAS_EXTERNAL_DOCS" -eq 1 ]; then
  DOCS_STAGED=0
  for entry in "${ALLOWLIST[@]}"; do
    case "$entry" in
      docs/*)
        local_path="$TARGET_CHECKOUT_ROOT/$entry"
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
  push_branch
fi

#!/usr/bin/env bash
# orchestrate.sh — main driver for the /migrate-repo workflow.
#
# Migrates a repo from docs/history.md + docs/todo.md to GitHub Issues
# with canary gates (1 → confirm → 2 → confirm → full).
#
# Steps:
#   1. Label sync + copy .github/ ISSUE_TEMPLATE / labels.yml
#   2. History canary 1 → confirm → canary 2 → confirm → full
#   3. Ordering gate (history must be complete before todo migrates) + todo canary
#   4. Create Projects v2 board + backfill Content Date
#   5. Backfill commit comments + clean up state
#
# Usage:
#   bin/github-issues/migration/orchestrate.sh <repo_dir> [--dry-run] [--from-step N]
set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

REPO_DIR="${1:?usage: orchestrate.sh <repo_dir> [--dry-run] [--from-step N] [--history-files <list>]}"
DRY_RUN=0
FROM_STEP=1
HISTORY_FILES=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --from-step)     FROM_STEP="${2:?--from-step requires N}"; shift 2 ;;
    --history-files) HISTORY_FILES="${2:?--history-files requires comma-separated list}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$REPO_DIR" && pwd)"

echo "=== /migrate-repo orchestrator ==="
echo "Repo:      $REPO_DIR"
echo "From-step: $FROM_STEP"
[ "$DRY_RUN" -eq 1 ] && echo "Mode:      DRY RUN"
echo ""

confirm() {
  local prompt="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would confirm: $prompt"
    return 0
  fi
  local reply
  read -rp "$prompt [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) echo "Aborted by user."; exit 1 ;;
  esac
}

# Initialize state file in non-dry-run mode.
if [ "$DRY_RUN" -eq 0 ]; then
  state_init "$REPO_DIR"
  state_load "$REPO_DIR"
  # Add .migration-state.json to .gitignore if not already present.
  GITIGNORE="$REPO_DIR/.gitignore"
  if [ -f "$GITIGNORE" ]; then
    if ! grep -qxF ".migration-state.json" "$GITIGNORE"; then
      printf '\n.migration-state.json\n' >> "$GITIGNORE"
    fi
  else
    printf '.migration-state.json\n' > "$GITIGNORE"
  fi
fi

# Pre-flight: warn if target repo already has issues (early-number invariant).
# Runs before Step 1 in both dry-run and live modes.
if [ "$FROM_STEP" -le 1 ]; then
  _existing=$(cd "$REPO_DIR" && gh issue list --state all --limit 1 --json number \
    --jq '.[0].number // empty' 2>/dev/null || echo "")
  if [ -n "$_existing" ]; then
    echo "WARNING: Target repo already has issues (latest seen: #${_existing})."
    echo "         Migration issues will NOT get early issue numbers — they will"
    echo "         land at #${_existing}+1 onwards. The chronological"
    echo "         'early numbers = history' invariant cannot be preserved post-hoc."
    if [ "$DRY_RUN" -eq 0 ]; then
      confirm "issue numbers will not start from #1 — proceed anyway"
    else
      echo "[dry-run] proceeding despite existing issues"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Step 1 — Label sync + .github/ templates
# -----------------------------------------------------------------------------
if [ "$FROM_STEP" -le 1 ]; then
  echo "--- Step 1: label sync + .github/ templates ---"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would copy $AGENTS_CONFIG_DIR/.github/labels.yml → $REPO_DIR/.github/labels.yml"
    echo "[dry-run] would copy $AGENTS_CONFIG_DIR/.github/ISSUE_TEMPLATE → $REPO_DIR/.github/ISSUE_TEMPLATE"
    echo "[dry-run] would run: bash $AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh"
  else
    mkdir -p "$REPO_DIR/.github"
    if [ -f "$AGENTS_CONFIG_DIR/.github/labels.yml" ]; then
      cp -n "$AGENTS_CONFIG_DIR/.github/labels.yml" "$REPO_DIR/.github/labels.yml" || true
    fi
    if [ -d "$AGENTS_CONFIG_DIR/.github/ISSUE_TEMPLATE" ]; then
      mkdir -p "$REPO_DIR/.github/ISSUE_TEMPLATE"
      # cp -n per file (POSIX: cp -rn behaves differently across platforms).
      for f in "$AGENTS_CONFIG_DIR/.github/ISSUE_TEMPLATE"/*; do
        [ -e "$f" ] || continue
        cp -n "$f" "$REPO_DIR/.github/ISSUE_TEMPLATE/" || true
      done
    fi
    (cd "$REPO_DIR" && bash "$AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh" \
      "$REPO_DIR/.github/labels.yml") || {
        echo "WARNING: sync-labels.sh failed (continuing)" >&2
      }
    state_set_step 1
  fi
  echo ""
fi

# -----------------------------------------------------------------------------
# Step 2 — History canary 1 → 2 → full
# -----------------------------------------------------------------------------
if [ "$FROM_STEP" -le 2 ]; then
  echo "--- Step 2: history migration (canary 1 → 2 → full) ---"
  HIST_FILE="$REPO_DIR/docs/history.md"
  HIST_DIR="$REPO_DIR/docs/history"
  if [ ! -f "$HIST_FILE" ] && [ ! -d "$HIST_DIR" ]; then
    echo "  no docs/history.md or docs/history/ — skipping"
  else
    # Build --history-files passthrough for migrate-history.sh invocations.
    HIST_FILES_FLAGS=()
    [ -n "${HISTORY_FILES:-}" ] && HIST_FILES_FLAGS=(--history-files "$HISTORY_FILES")

    if [ "$DRY_RUN" -eq 1 ]; then
      bash "$SCRIPT_DIR/migrate-history.sh" "$REPO_DIR" --dry-run \
        "${HIST_FILES_FLAGS[@]+${HIST_FILES_FLAGS[@]}}"
    else
      # Idempotency: if history is already fully migrated, skip canary.
      total_hist=$(awk '/^### /{n++} END{print n+0}' "$HIST_FILE" 2>/dev/null || echo 0)
      if [ -d "$HIST_DIR" ]; then
        for f in "$HIST_DIR"/*.md; do
          [ -e "$f" ] || continue
          case "$(basename "$f")" in index.md) continue ;; esac
          c=$(awk '/^### /{n++} END{print n+0}' "$f" 2>/dev/null || echo 0)
          total_hist=$((total_hist + c))
        done
      fi
      already=$(state_count_migrated history)
      if [ "$total_hist" -gt 0 ] && [ "$already" -ge "$total_hist" ]; then
        echo "  history already fully migrated ($already/$total_hist) — skipping"
      else
        bash "$SCRIPT_DIR/migrate-history.sh" "$REPO_DIR" --canary 1 \
          "${HIST_FILES_FLAGS[@]+${HIST_FILES_FLAGS[@]}}"
        confirm "history canary 1 OK? proceed to canary 2"
        bash "$SCRIPT_DIR/migrate-history.sh" "$REPO_DIR" --canary 2 \
          "${HIST_FILES_FLAGS[@]+${HIST_FILES_FLAGS[@]}}"
        confirm "history canary 2 OK? proceed to full run"
        bash "$SCRIPT_DIR/migrate-history.sh" "$REPO_DIR" \
          "${HIST_FILES_FLAGS[@]+${HIST_FILES_FLAGS[@]}}"
      fi
      state_set_step 2
    fi
  fi
  echo ""
fi

# -----------------------------------------------------------------------------
# Step 3 — Ordering gate then todo canary
# -----------------------------------------------------------------------------
if [ "$FROM_STEP" -le 3 ]; then
  echo "--- Step 3: todo migration (canary 1 → 2 → full) ---"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] Step 3 ordering gate: SKIPPED (dry-run mode)"
    bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR" --dry-run
  else
    # Ordering gate — history must be complete.
    HIST_FILE="$REPO_DIR/docs/history.md"
    HIST_DIR="$REPO_DIR/docs/history"
    hist_total=0
    if [ -f "$HIST_FILE" ]; then
      hist_total=$(awk '/^### /{n++} END{print n+0}' "$HIST_FILE" 2>/dev/null || echo 0)
    fi
    if [ -d "$HIST_DIR" ]; then
      for f in "$HIST_DIR"/*.md; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in index.md) continue ;; esac
        c=$(awk '/^### /{n++} END{print n+0}' "$f" 2>/dev/null || echo 0)
        hist_total=$((hist_total + c))
      done
    fi
    hist_done=$(state_count_migrated history)
    if [ "$hist_total" -gt 0 ] && [ "$hist_done" -lt "$hist_total" ]; then
      echo "ERROR: Step 3 ordering gate: history is incomplete ($hist_done/$hist_total)" >&2
      echo "       Run --from-step 2 first." >&2
      exit 1
    fi
    echo "Step 3 ordering gate: PASSED ($hist_done/$hist_total history entries migrated)"

    TODO_FILE="$REPO_DIR/docs/todo.md"
    if [ ! -f "$TODO_FILE" ]; then
      echo "  no docs/todo.md — skipping"
    else
      todo_total=$(awk '/^## /{n++} END{print n+0}' "$TODO_FILE" 2>/dev/null || echo 0)
      todo_done=$(state_count_migrated todo)
      if [ "$todo_total" -gt 0 ] && [ "$todo_done" -ge "$todo_total" ]; then
        echo "  todo already fully migrated ($todo_done/$todo_total) — running full to rewrite todo.md if needed"
        bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR"
      else
        bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR" --canary 1
        confirm "todo canary 1 OK? proceed to canary 2"
        bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR" --canary 2
        confirm "todo canary 2 OK? proceed to full run"
        bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR"
      fi
    fi
    state_set_step 3
  fi
  echo ""
fi

# -----------------------------------------------------------------------------
# Step 4 — Create Projects v2 + backfill Content Date
# -----------------------------------------------------------------------------
if [ "$FROM_STEP" -le 4 ]; then
  echo "--- Step 4: Projects v2 + Content Date backfill ---"
  if [ "$DRY_RUN" -eq 1 ]; then
    bash "$SCRIPT_DIR/create-project.sh" "$REPO_DIR" --dry-run
    echo "[dry-run] would backfill Content Date for migrated history issues"
  else
    bash "$SCRIPT_DIR/create-project.sh" "$REPO_DIR"
    state_load "$REPO_DIR"
    proj_num=$(jq -r '.project.number // empty' "$STATE_FILE")
    proj_id=$(jq -r '.project.node_id // empty' "$STATE_FILE")
    field_id=$(state_get_project_field_id "Content Date")
    if [ -z "$proj_num" ] || [ -z "$proj_id" ] || [ -z "$field_id" ]; then
      echo "ERROR: project ids missing from state — Step 4 cannot proceed" >&2
      exit 1
    fi
    MIGRATE_PROJECT_NUM="$proj_num" \
    MIGRATE_PROJECT_ID="$proj_id" \
    MIGRATE_FIELD_ID="$field_id" \
      bash "$SCRIPT_DIR/backfill-content-date.sh" "$REPO_DIR"
    state_set_step 4
  fi
  echo ""
fi

# -----------------------------------------------------------------------------
# Step 5 — Backfill commit comments + cleanup
# -----------------------------------------------------------------------------
if [ "$FROM_STEP" -le 5 ]; then
  echo "--- Step 5: backfill commit comments + cleanup ---"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would run: REPO_DIR=$REPO_DIR bash $AGENTS_CONFIG_DIR/bin/github-issues/backfill-commit-comments.sh"
    echo "[dry-run] would clean up .migration-state.json on success"
  else
    REPO_DIR="$REPO_DIR" bash "$AGENTS_CONFIG_DIR/bin/github-issues/backfill-commit-comments.sh"
    state_set_step 5
    state_cleanup "$REPO_DIR"
    echo "  state file removed (migration complete)"
  fi
  echo ""
fi

echo "=== /migrate-repo orchestrator complete ==="

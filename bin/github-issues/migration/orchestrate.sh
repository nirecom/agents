#!/usr/bin/env bash
# orchestrate.sh — main driver for the /migrate-repo workflow.
#
# Migrates a repo from docs/history.md + docs/todo.md to GitHub Issues
# with canary gates (1 → confirm → 2 → confirm → full).
#
# Steps:
#   1. Label sync + copy .github/ ISSUE_TEMPLATE / labels.yml
#   2. History migration — one canary stage per invocation (--stage canary-1|canary-2|full)
#   3. Ordering gate (history complete) + todo migration — one canary stage per invocation
#   4. Create Projects v2 board + backfill Content Date
#   5. Backfill commit comments + clean up state
#
# Usage:
#   bin/github-issues/migration/orchestrate.sh <repo_dir> [--dry-run] [--from-step N] [--stage canary-1|canary-2|full]
set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

REPO_DIR="${1:?usage: orchestrate.sh <repo_dir> [--dry-run] [--from-step N] [--stage canary-1|canary-2|full] [--history-files <list>]}"
DRY_RUN=0
FROM_STEP=1
HISTORY_FILES=""
STAGE=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --from-step)     FROM_STEP="${2:?--from-step requires N}"; shift 2 ;;
    --history-files) HISTORY_FILES="${2:?--history-files requires comma-separated list}"; shift 2 ;;
    --stage)         STAGE="${2:?--stage requires canary-1|canary-2|full}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$STAGE" in
  ""|canary-1|canary-2|full) ;;
  *) echo "ERROR: --stage must be canary-1|canary-2|full (got: $STAGE)" >&2; exit 1 ;;
esac

REPO_DIR="$(cd "$REPO_DIR" && pwd)"

echo "=== /migrate-repo orchestrator ==="
echo "Repo:      $REPO_DIR"
echo "From-step: $FROM_STEP"
[ "$DRY_RUN" -eq 1 ] && echo "Mode:      DRY RUN"
echo ""

history_entries_total() {
  # HIST_FILE and HIST_DIR must be in scope.
  local count=0
  if [ -f "$HIST_FILE" ]; then
    count=$((count + $(awk '/^### /{n++} END{print n+0}' "$HIST_FILE" 2>/dev/null || echo 0)))
  fi
  if [ -d "$HIST_DIR" ]; then
    while IFS= read -r f; do
      [ "$(basename "$f")" = "index.md" ] && continue
      count=$((count + $(awk '/^### /{n++} END{print n+0}' "$f" 2>/dev/null || echo 0)))
    done < <(find "$HIST_DIR" -name "*.md" -type f)
  fi
  echo "$count"
}

todo_entries_total() {
  # TODO_FILE must be in scope.
  # Counts only non-empty sections — a section is non-empty if it has at least
  # one non-blank line beyond the ## header itself.
  if [ -f "$TODO_FILE" ]; then
    awk '
      /^## / {
        if (n > 0 && has_content) non_empty++
        n++; has_content=0; next
      }
      n > 0 && /[^[:space:]]/ && !/^## / { has_content=1 }
      END { if (n > 0 && has_content) non_empty++; print non_empty+0 }
    ' "$TODO_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

_print_next_stage() {
  local kind="$1" done_stage="$2" next_stage="$3" step="$4"
  echo ""
  echo "=== $kind $done_stage complete ==="
  echo "Inspect the issues created above on GitHub:"
  local url
  url="$(cd "$REPO_DIR" && gh repo view --json url --jq '.url + "/issues"' 2>/dev/null || true)"
  if [ -n "$url" ]; then
    echo "  $url"
  else
    echo "  (could not resolve repo URL — open GitHub manually)"
  fi
  if [ "$next_stage" = "done" ]; then
    local next_step=$((step + 1))
    echo "$kind migration complete."
    if [ "$next_step" -le 5 ]; then
      echo "Next: continue with Step $next_step:"
      echo "  bash $0 $REPO_DIR --from-step $next_step"
    fi
  else
    echo "Next command (run ONLY after inspecting the issues above):"
    echo "  bash $0 $REPO_DIR --from-step $step --stage $next_stage"
  fi
  echo ""
}

# Pre-flight: check existing issues + require explicit ack in live mode.
# Runs on EVERY invocation BEFORE state mutation. No stdin read — cannot be
# bypassed by `yes y |` piping (Incident #2 / #415). Live mode requires
# MIGRATE_ACK_EXISTING_ISSUES=1 env var. The /migrate-repo skill sets this
# after the user acknowledges via AskUserQuestion (#679).
# #834 Option γ: Layer P (presence + format) + Layer C (snapshot comparison)
# additionally require MIGRATE_ACK_UP_TO_ISSUE_N + MIGRATE_ACK_SELF_COUNT_AT_ACK
# from a fresh dry-run snapshot to defeat the TOCTOU window.
_existing_n=$(cd "$REPO_DIR" && gh issue list --state all --limit 1 \
  --search "sort:created-desc" --json number --jq '.[0].number // 0' 2>/dev/null)
_existing_rc=$?
if [ "$_existing_rc" -ne 0 ]; then
  echo "ERROR: pre-flight check failed: 'gh issue list' exited rc=$_existing_rc." >&2
  echo "       Cannot confirm whether existing issues are present." >&2
  echo "       Likely cause: not authenticated ('gh auth login'), network error, or wrong repo." >&2
  echo "       Aborting to prevent accidental loss of the early-number invariant." >&2
  exit 1
fi

# Initialize state file in non-dry-run mode — must run BEFORE Layer C so state_count_migrated is available.
if [ "$DRY_RUN" -eq 0 ]; then
  state_init "$REPO_DIR"
  state_load "$REPO_DIR"
  GITIGNORE="$REPO_DIR/.gitignore"
  if [ -f "$GITIGNORE" ]; then
    if ! grep -qxF ".migration-state.json" "$GITIGNORE"; then
      printf '\n.migration-state.json\n' >> "$GITIGNORE"
    fi
  else
    printf '.migration-state.json\n' > "$GITIGNORE"
  fi
fi

# Dry-run sentinel emission (unconditional — even when _existing_n=0).
if [ "$DRY_RUN" -eq 1 ]; then
  _self_at_dry_run=0
  _sf="$REPO_DIR/.migration-state.json"
  if [ -f "$_sf" ]; then
    STATE_FILE="$_sf"
    _hist_n=$(state_count_migrated history 2>/dev/null || echo 0)
    _todo_n=$(state_count_migrated todo 2>/dev/null || echo 0)
    _self_at_dry_run=$((_hist_n + _todo_n))
  fi
  echo "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=${_existing_n}"
  echo "MIGRATE_DRY_RUN_SELF_COUNT=${_self_at_dry_run}"
fi

if [ "$_existing_n" -gt 0 ]; then
  echo "WARNING: Target repo already has issues (latest seen: #${_existing_n})."
  echo "         Migration issues will NOT get early issue numbers — they will"
  echo "         land at #${_existing_n}+1 onwards. The chronological"
  echo "         'early numbers = history' invariant cannot be preserved post-hoc."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] proceeding despite existing issues"
  elif [ "${MIGRATE_ACK_EXISTING_ISSUES:-0}" != "1" ]; then
    echo "" >&2
    echo "ERROR: live mode requires explicit acknowledgement of the existing-issues" >&2
    echo "       invariant loss. Re-run with MIGRATE_ACK_EXISTING_ISSUES=1 prefix:" >&2
    echo "         MIGRATE_ACK_EXISTING_ISSUES=1 bash $0 $REPO_DIR [...]" >&2
    echo "       The /migrate-repo skill sets this automatically after the user" >&2
    echo "       acknowledges via AskUserQuestion. Direct shell callers must set" >&2
    echo "       it themselves. This gate is tty-bypass-resistant (no stdin)." >&2
    exit 1
  else
    # --- Layer P (presence + format check) — EVERY live invocation ---
    _ack_up_to="${MIGRATE_ACK_UP_TO_ISSUE_N:-}"
    _ack_self_at_ack="${MIGRATE_ACK_SELF_COUNT_AT_ACK:-}"

    if [ -z "$_ack_up_to" ]; then
      echo "" >&2
      echo "ERROR: MIGRATE_ACK_UP_TO_ISSUE_N required when MIGRATE_ACK_EXISTING_ISSUES=1 (#834 Option γ Layer P)." >&2
      echo "       Re-run dry-run via preview-and-capture.sh and re-export both env vars:" >&2
      echo "         eval \"\$(bash \"\$AGENTS_CONFIG_DIR/skills/migrate-repo/scripts/preview-and-capture.sh\" \"$REPO_DIR\")\"" >&2
      exit 1
    fi
    if [ -z "$_ack_self_at_ack" ]; then
      echo "" >&2
      echo "ERROR: MIGRATE_ACK_SELF_COUNT_AT_ACK required when MIGRATE_ACK_EXISTING_ISSUES=1 (#834 Option γ Layer P)." >&2
      echo "       Re-run dry-run via preview-and-capture.sh to refresh both env vars." >&2
      exit 1
    fi
    if ! printf '%s' "$_ack_up_to" | grep -Eq '^(0|[1-9][0-9]*)$'; then
      echo "" >&2
      echo "ERROR: MIGRATE_ACK_UP_TO_ISSUE_N must be a non-negative integer (got: '${_ack_up_to}')." >&2
      exit 1
    fi
    if ! printf '%s' "$_ack_self_at_ack" | grep -Eq '^(0|[1-9][0-9]*)$'; then
      echo "" >&2
      echo "ERROR: MIGRATE_ACK_SELF_COUNT_AT_ACK must be a non-negative integer (got: '${_ack_self_at_ack}')." >&2
      exit 1
    fi

    # --- Layer C (snapshot comparison with self-count adjustment) — EVERY live invocation ---
    _self_now=$(( $(state_count_migrated history) + $(state_count_migrated todo) ))
    _self_delta=$((_self_now - _ack_self_at_ack))
    if [ "$_self_delta" -lt 0 ]; then
      echo "" >&2
      echo "ERROR: self-count regression detected (self_now=${_self_now} < ack=${_ack_self_at_ack}) — state file modified out of band." >&2
      echo "       Re-run dry-run via preview-and-capture.sh to refresh the snapshot." >&2
      exit 1
    fi
    _expected_max=$((_ack_up_to + _self_delta))

    if [ "$_existing_n" -gt "$_expected_max" ]; then
      echo "" >&2
      echo "ERROR: TOCTOU: target repo state moved since dry-run acknowledgement (#834 Option γ Layer C)." >&2
      echo "       Acked up to #${_ack_up_to}, +${_self_delta} self issues created since, expected max #${_expected_max}." >&2
      echo "       Current highest is #${_existing_n} — issues from external actor detected." >&2
      echo "       Re-run dry-run via preview-and-capture.sh to refresh the snapshot:" >&2
      echo "         eval \"\$(bash \"\$AGENTS_CONFIG_DIR/skills/migrate-repo/scripts/preview-and-capture.sh\" \"$REPO_DIR\")\"" >&2
      exit 1
    fi

    echo "         MIGRATE_ACK_EXISTING_ISSUES=1 + UP_TO=#${_ack_up_to} + SELF_AT_ACK=${_ack_self_at_ack} (delta=${_self_delta}, expected_max=#${_expected_max}) acknowledged — proceeding."
  fi
fi

# -----------------------------------------------------------------------------
# Step 1 — Label sync + .github/ templates
# -----------------------------------------------------------------------------
if [ "$FROM_STEP" -le 1 ]; then
  echo "--- Step 1: label sync + .github/ templates ---"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would run: bash $AGENTS_CONFIG_DIR/bin/github-issues/bootstrap-labels.sh $REPO_DIR"
    echo "[dry-run] would copy $AGENTS_CONFIG_DIR/.github/ISSUE_TEMPLATE → $REPO_DIR/.github/ISSUE_TEMPLATE"
  else
    mkdir -p "$REPO_DIR/.github"
    bash "$AGENTS_CONFIG_DIR/bin/github-issues/bootstrap-labels.sh" "$REPO_DIR" || {
        echo "WARNING: bootstrap-labels.sh failed (continuing)" >&2
      }
    if [ -d "$AGENTS_CONFIG_DIR/.github/ISSUE_TEMPLATE" ]; then
      mkdir -p "$REPO_DIR/.github/ISSUE_TEMPLATE"
      # cp -n per file (POSIX: cp -rn behaves differently across platforms).
      for f in "$AGENTS_CONFIG_DIR/.github/ISSUE_TEMPLATE"/*; do
        [ -e "$f" ] || continue
        cp -n "$f" "$REPO_DIR/.github/ISSUE_TEMPLATE/" || true
      done
    fi
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
      if [ -z "$STAGE" ]; then
        echo "ERROR: Step 2 (history migration) requires --stage." >&2
        echo "       Start with: bash $0 $REPO_DIR --from-step 2 --stage canary-1" >&2
        exit 1
      fi

      already=$(state_count_migrated history)
      total_hist=$(history_entries_total)
      if [ "$total_hist" -gt 0 ] && [ "$already" -ge "$total_hist" ]; then
        echo "  history already fully migrated ($already/$total_hist) — skipping --stage $STAGE"
        if [ "$STAGE" = "full" ]; then
          state_set_advanced history full
          state_set_step 2
        fi
        exit 0
      fi

      case "$STAGE" in
        canary-1)
          bash "$SCRIPT_DIR/migrate-history.sh" "$REPO_DIR" --canary 1 \
            "${HIST_FILES_FLAGS[@]+${HIST_FILES_FLAGS[@]}}"
          _print_next_stage history canary-1 canary-2 2
          exit 0
          ;;
        canary-2)
          state_set_advanced history canary_1
          bash "$SCRIPT_DIR/migrate-history.sh" "$REPO_DIR" --canary 2 \
            "${HIST_FILES_FLAGS[@]+${HIST_FILES_FLAGS[@]}}"
          _print_next_stage history canary-2 full 2
          exit 0
          ;;
        full)
          state_set_advanced history canary_2
          bash "$SCRIPT_DIR/migrate-history.sh" "$REPO_DIR" \
            "${HIST_FILES_FLAGS[@]+${HIST_FILES_FLAGS[@]}}"
          state_set_advanced history full
          state_set_step 2
          _print_next_stage history full done 2
          exit 0
          ;;
      esac
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
      if [ -z "$STAGE" ]; then
        echo "ERROR: Step 3 (todo migration) requires --stage." >&2
        echo "       Start with: bash $0 $REPO_DIR --from-step 3 --stage canary-1" >&2
        exit 1
      fi

      todo_total=$(todo_entries_total)
      todo_done=$(state_count_migrated todo)
      if [ "$todo_total" -gt 0 ] && [ "$todo_done" -ge "$todo_total" ]; then
        if [ "$STAGE" = "full" ]; then
          echo "  todo already fully migrated ($todo_done/$todo_total) — running todo.md thin-index rewrite"
          bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR"
          state_set_advanced todo full
          state_set_step 3
        else
          echo "  todo already fully migrated ($todo_done/$todo_total) — skipping --stage $STAGE"
        fi
        exit 0
      fi

      case "$STAGE" in
        canary-1)
          bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR" --canary 1
          _print_next_stage todo canary-1 canary-2 3
          exit 0
          ;;
        canary-2)
          state_set_advanced todo canary_1
          bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR" --canary 2
          _print_next_stage todo canary-2 full 3
          exit 0
          ;;
        full)
          state_set_advanced todo canary_2
          bash "$SCRIPT_DIR/migrate-todo.sh" "$REPO_DIR"
          state_set_advanced todo full
          state_set_step 3
          _print_next_stage todo full done 3
          exit 0
          ;;
      esac
    fi
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
    proj_num=$(jq_text '.project.number // empty' "$STATE_FILE")
    proj_id=$(jq_text '.project.node_id // empty' "$STATE_FILE")
    field_id=$(state_get_project_field_id "Content Date")
    if [ -z "$proj_num" ] || [ -z "$proj_id" ] || [ -z "$field_id" ]; then
      echo "ERROR: project ids missing from state — Step 4 cannot proceed" >&2
      exit 1
    fi
    if ! MIGRATE_PROJECT_NUM="$proj_num" \
         MIGRATE_PROJECT_ID="$proj_id" \
         MIGRATE_FIELD_ID="$field_id" \
           bash "$SCRIPT_DIR/backfill-content-date.sh" "$REPO_DIR"; then
      echo "ERROR: backfill-content-date.sh failed — re-run with --from-step 4 after fixing" >&2
      exit 1
    fi
    state_set_step 4
  fi
  echo ""
fi

# -----------------------------------------------------------------------------
# Step 5 — Backfill commit comments
# -----------------------------------------------------------------------------
if [ "$FROM_STEP" -le 5 ]; then
  echo "--- Step 5: backfill commit comments ---"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would run: REPO_DIR=$REPO_DIR bash $AGENTS_CONFIG_DIR/bin/github-issues/backfill-commit-comments.sh"
  else
    if ! REPO_DIR="$REPO_DIR" bash "$AGENTS_CONFIG_DIR/bin/github-issues/backfill-commit-comments.sh"; then
      echo "ERROR: backfill-commit-comments.sh failed — re-run with --from-step 5 after fixing" >&2
      exit 1
    fi
    state_set_step 5
  fi
  echo ""
fi

# -----------------------------------------------------------------------
# Step 6 — Commit + push migration artifacts (Step 1/3 side effects)
# -----------------------------------------------------------------------
if [ "$FROM_STEP" -le 6 ]; then
  echo "--- Step 6: commit + push migration artifacts ---"
  if [ "$DRY_RUN" -eq 1 ]; then
    bash "$SCRIPT_DIR/commit-migration-artifacts.sh" "$REPO_DIR" --dry-run
    echo "[dry-run] would clean up .migration-state.json on success"
  else
    echo "<<WORKFLOW_USER_VERIFIED: migration cleanup commit (Step 1/3 artifacts) approved as part of /migrate-repo run>>"
    echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: migrate-repo artifact commit>>"
    ENFORCE_WORKTREE=off "$SCRIPT_DIR/commit-migration-artifacts.sh" "$REPO_DIR"
    echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: migrate-repo artifact commit complete>>"
    state_set_step 6
    state_cleanup "$REPO_DIR"
    echo "  state file removed (migration complete)"
  fi
  echo ""
fi

echo "=== /migrate-repo orchestrator complete ==="

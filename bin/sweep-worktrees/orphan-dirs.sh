#!/bin/bash
#
# bin/sweep-worktrees/orphan-dirs.sh — sourced by bin/sweep-worktrees.sh. Two
# passes reclaim filesystem state git's worktree registry no longer knows about:
# sweep_orphan_dirs (unregistered depth-2 dirs under WORKTREE_BASE_DIR; removal
# delegated to hooks/cleanup-orphan-dir.js and its 4-AND safety gate) and
# sweep_stale_backups (.worktree-backup/* older than MIN_AGE_HOURS * 7). Must be
# `source`d, not executed: it reads caller-scope variables ($MAIN_ROOT,
# $WORKTREE_BASE_DIR, $APPLY, $DRY_RUN, $MIN_AGE_HOURS, $AGENTS_CONFIG_DIR) and
# mutates the orphan_dirs_* counters.

sweep_orphan_dirs() {
  # ── Pre-pass guard: snapshot the registry to a temp file ──────────────────
  # Not `local`: the EXIT trap below must still see it after this returns.
  registered_norm_file=$(mktemp)
  # Function-form trap: defers expansion of $registered_norm_file to cleanup time
  # and quotes safely even if mktemp ever returns a path containing spaces or
  # shell metacharacters.
  cleanup_registered_files() {
    rm -f -- "$registered_norm_file" "${registered_norm_file}.raw"
  }
  trap cleanup_registered_files EXIT
  local skip_orphan_dir_scan=0
  if ! git -C "$MAIN_ROOT" worktree list --porcelain > "${registered_norm_file}.raw" 2>/dev/null; then
    printf 'WARNING: git worktree list --porcelain failed; skipping orphan-dir scan pass\n' >&2
    skip_orphan_dir_scan=1
  else
    awk '/^worktree /{print substr($0,10)}' "${registered_norm_file}.raw" \
      | while IFS= read -r r; do norm_path "$r"; printf '\n'; done > "$registered_norm_file"
  fi

  # ── Scan pass ─────────────────────────────────────────────────────────────
  # Reuses hooks/cleanup-orphan-dir.js for the actual removal (4-AND safety gate).
  if [[ "$skip_orphan_dir_scan" == "1" || ! -d "$WORKTREE_BASE_DIR" ]]; then
    return 0
  fi

  local current_repo_name wt_base_norm cand_dir cand_name cand_norm
  local notes_file recorded main_norm_fs rec_norm_fs node_out node_rc
  current_repo_name="$(basename "$MAIN_ROOT")"
  wt_base_norm="$(norm_path "$WORKTREE_BASE_DIR")"

  while IFS= read -r -d '' cand_dir; do
    cand_name="$(basename "$cand_dir")"
    # Cross-repo guard: only sweep dirs whose final segment matches this repo.
    [[ "$cand_name" == "$current_repo_name" ]] || continue
    cand_norm="$(norm_path "$cand_dir")"

    # Gate (4): skip if registered (already handled by main loop).
    if grep -Fxq -- "$cand_norm" "$registered_norm_file"; then
      orphan_dirs_skipped_registered=$((orphan_dirs_skipped_registered + 1))
      continue
    fi
    # Gate (1): containment under WORKTREE_BASE_DIR.
    case "$cand_norm" in
      "$wt_base_norm"/*) ;;
      *) continue ;;
    esac
    # Gate (2): no .git present (file, dir, or dangling symlink).
    if [[ -e "$cand_dir/.git" || -L "$cand_dir/.git" ]]; then
      orphan_dirs_skipped_has_git=$((orphan_dirs_skipped_has_git + 1))
      continue
    fi
    # Gate (3): mtime check (older than --min-age-hours).
    if is_fresh "$cand_dir"; then
      orphan_dirs_skipped_young=$((orphan_dirs_skipped_young + 1))
      continue
    fi
    # Gate (5): cross-repo ownership proof — WORKTREE_NOTES.md must carry a
    # `Main repo:` line matching the current MAIN_ROOT (forward-slash form).
    # Basename match alone is not unique ownership (two unrelated repos can
    # share `agents`/`dotfiles` basenames under different parents), so legacy
    # notes lacking the field and missing notes files are SKIPPED, never fall
    # through to basename match. Gate (4) "empty-or-notes-only" was removed on
    # purpose: a partial `git worktree remove` can leave a full checkout with
    # no .git, and that directory has proven ownership via Gate (5), so it is
    # safe to delete via cleanup-orphan-dir.js --force-if-not-registered.
    notes_file="$cand_dir/WORKTREE_NOTES.md"
    if [[ ! -f "$notes_file" ]]; then
      orphan_dirs_skipped_repo_mismatch=$((orphan_dirs_skipped_repo_mismatch + 1))
      continue
    fi
    recorded="$( { grep -m1 -E '^Main repo:[[:space:]]*' "$notes_file" 2>/dev/null || true; } | sed -E 's/^Main repo:[[:space:]]*//' | tr -d '\r')"
    if [[ -z "$recorded" ]]; then
      orphan_dirs_skipped_repo_mismatch=$((orphan_dirs_skipped_repo_mismatch + 1))
      continue
    fi
    main_norm_fs="$(norm_path "$MAIN_ROOT")"
    rec_norm_fs="$(norm_path "$recorded")"
    if [[ "$rec_norm_fs" != "$main_norm_fs" ]]; then
      orphan_dirs_skipped_repo_mismatch=$((orphan_dirs_skipped_repo_mismatch + 1))
      continue
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      printf 'would remove orphan dir: %s\n' "$cand_dir" >&2
    else
      # Release the CodeGraph index lock (Windows file lock) before removal.
      if command -v node >/dev/null 2>&1; then
        node "$AGENTS_CONFIG_DIR/bin/codegraph-lifecycle.js" stop --path "$cand_dir" || true
      fi

      node_out="$(WORKTREE_BASE_DIR="$WORKTREE_BASE_DIR" \
        node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" \
        --force-if-not-registered "$cand_dir" 2>&1)"
      node_rc=$?
      if [[ "$node_rc" -eq 0 ]]; then
        orphan_dirs_removed=$((orphan_dirs_removed + 1))
      else
        orphan_dirs_skipped_failed=$((orphan_dirs_skipped_failed + 1))
        printf 'WARNING: cleanup-orphan-dir failed for %s: %s\n' "$cand_dir" "$node_out" >&2
      fi
    fi
  done < <(find "$WORKTREE_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
}

# Remove stale <main-root>/.worktree-backup/* directories.
sweep_stale_backups() {
  local backup_base="$MAIN_ROOT/.worktree-backup"
  [[ -d "$backup_base" ]] || return 0

  local backup_threshold backup_threshold_mins real_base backup_dir real_backup
  backup_threshold=$((MIN_AGE_HOURS * 7))
  backup_threshold_mins=$((backup_threshold * 60))
  real_base="$(norm_path "$backup_base")"
  while IFS= read -r -d '' backup_dir; do
    real_backup="$(norm_path "$backup_dir")"
    # Reject paths containing ".."
    case "$real_backup" in
      *..*)
        printf 'WARN: path traversal rejected: %s\n' "$backup_dir" >&2
        continue
        ;;
    esac
    # Must be strictly under real_base.
    case "$real_backup" in
      "$real_base"/*) ;;
      *)
        printf 'WARN: unsafe path skipped: %s\n' "$backup_dir" >&2
        continue
        ;;
    esac
    if [[ "$APPLY" == "1" ]]; then
      rm -rf -- "$backup_dir"
    else
      printf 'DRY-RUN: would remove stale backup: %s\n' "$backup_dir"
    fi
  done < <(find "$backup_base" -maxdepth 1 -mindepth 1 -type d \
    -not -mmin "-$backup_threshold_mins" -print0 2>/dev/null)
}

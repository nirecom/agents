#!/bin/bash
#
# bin/sweep-worktrees/orphan-dirs.sh — sourced by bin/sweep-worktrees.sh. Two
# passes reclaim filesystem state git's worktree registry no longer knows about:
# sweep_orphan_dirs (unregistered depth-2 dirs under one scanned base; removal
# delegated to hooks/cleanup-orphan-dir.js --repo <owner> and its safety gates) and
# sweep_stale_backups (.worktree-backup/* older than MIN_AGE_HOURS * 7). Must be
# `source`d, not executed: it reads caller-scope variables ($TARGET_MAIN_ROOT,
# $WORKTREE_BASE_DIR, $APPLY, $DRY_RUN, $MIN_AGE_HOURS, the scan set) and
# mutates the orphan_dirs_* counters.
_ORPHAN_DIRS_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# _orphan_owner <cand_dir> <owners...> — print the one scanned repo proven to own the leaf (#1610):
# a gitlink leftover's reverse-looked-up main checkout, else the notes `Main repo:`; either must be
# a scanned owner of this base with the leaf's basename. Prints nothing when no owner is proven.
_orphan_owner() {
  local cand="$1" name claimed owner
  shift
  name="$(basename "$cand")"
  if [[ -f "$cand/.git" ]]; then
    claimed="$(node "$_ORPHAN_DIRS_SCRIPT_CHECKOUT_ROOT/bin/sweep-worktrees/leaf-owner.js" "$cand" 2>/dev/null || true)"
    claimed="${claimed%$'\r'}"
    for owner in "$@"; do
      if [[ -n "$claimed" && "$(norm_path "$claimed")" == "$(norm_path "$owner")" && "$(basename "$owner")" == "$name" ]]; then
        printf '%s' "$owner"
        return 0
      fi
    done
  fi
  [[ -f "$cand/WORKTREE_NOTES.md" ]] || return 0
  claimed="$( { grep -m1 -E '^Main repo:[[:space:]]*' "$cand/WORKTREE_NOTES.md" 2>/dev/null || true; } | sed -E 's/^Main repo:[[:space:]]*//' | tr -d '\r')"
  [[ -n "$claimed" ]] || return 0
  for owner in "$@"; do
    if [[ "$(norm_path "$claimed")" == "$(norm_path "$owner")" && "$(basename "$owner")" == "$name" ]]; then
      printf '%s' "$owner"
      return 0
    fi
  done
}

# sweep_orphan_dirs <base_norm> — one scanned base ($WORKTREE_BASE_DIR) and its scan-set owners.
sweep_orphan_dirs() {
  local base_key="$1"
  local -a owners=()
  local owner
  while IFS= read -r owner; do
    if [[ -n "$owner" ]]; then owners+=("$owner"); fi
  done < <(scan_set_owners "$base_key")
  [[ ${#owners[@]} -gt 0 && -d "$WORKTREE_BASE_DIR" ]] || return 0

  # ── Pre-pass guard: snapshot every owner's registry to a temp file ────────
  # Not `local`: the EXIT trap below must still see it after this returns.
  registered_norm_file=$(mktemp)
  cleanup_registered_files() {
    rm -f -- "$registered_norm_file" "${registered_norm_file}.raw"
  }
  trap cleanup_registered_files EXIT
  : > "${registered_norm_file}.raw"
  for owner in "${owners[@]}"; do
    if ! git -C "$owner" worktree list --porcelain >> "${registered_norm_file}.raw" 2>/dev/null; then
      printf 'WARNING: git worktree list --porcelain failed for %s; skipping orphan-dir scan of %s\n' \
        "$owner" "$WORKTREE_BASE_DIR" >&2
      cleanup_registered_files
      return 0
    fi
  done
  awk '/^worktree /{print substr($0,10)}' "${registered_norm_file}.raw" \
    | while IFS= read -r r; do norm_path "$r"; printf '\n'; done > "$registered_norm_file"

  local wt_base_norm cand_dir cand_name cand_norm node_out node_rc owner_of name_hit
  local -a main_root_args
  wt_base_norm="$(norm_path "$WORKTREE_BASE_DIR")"

  while IFS= read -r -d '' cand_dir; do
    cand_name="$(basename "$cand_dir")"
    # Cross-repo guard: only leaves named after a scanned owner of this base.
    name_hit=0
    for owner in "${owners[@]}"; do
      if [[ "$(basename "$owner")" == "$cand_name" ]]; then name_hit=1; fi
    done
    [[ "$name_hit" == "1" ]] || continue
    cand_norm="$(norm_path "$cand_dir")"

    # Gate (4): skip if registered, or inside a registered worktree (a native <base>/<name>).
    if grep -Fxq -- "$cand_norm" "$registered_norm_file" \
        || grep -Fxq -- "$(dirname "$cand_norm")" "$registered_norm_file"; then
      orphan_dirs_skipped_registered=$((orphan_dirs_skipped_registered + 1))
      continue
    fi
    # Gate (1): containment under the scanned base.
    case "$cand_norm" in
      "$wt_base_norm"/*) ;;
      *) continue ;;
    esac
    # Gate (2): no .git directory or symlink. A gitlink file (a WE-11 leftover, #2875) goes to the
    # CLI with --expect-main-root, which removes it only once its ownership is proven.
    if [[ -L "$cand_dir/.git" || -d "$cand_dir/.git" ]]; then
      orphan_dirs_skipped_has_git=$((orphan_dirs_skipped_has_git + 1))
      continue
    fi
    # Gate (3): mtime check (older than --min-age-hours).
    if is_fresh "$cand_dir"; then
      orphan_dirs_skipped_young=$((orphan_dirs_skipped_young + 1))
      continue
    fi
    # Gate (5): ownership proof (_orphan_owner). Basename alone is never proof: two unrelated repos
    # can share a name, so a leaf with no proven owner is kept and reported.
    owner_of="$(_orphan_owner "$cand_dir" "${owners[@]}")"
    if [[ -z "$owner_of" ]]; then
      printf 'unowned leftover: %s\n' "$cand_dir" >&2
      orphan_dirs_skipped_repo_mismatch=$((orphan_dirs_skipped_repo_mismatch + 1))
      continue
    fi
    main_root_args=(--repo "$owner_of")
    if [[ -e "$cand_dir/.git" ]]; then
      main_root_args+=(--expect-main-root "$owner_of")
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      printf 'would remove orphan dir: %s\n' "$cand_dir" >&2
    else
      # Release the CodeGraph index lock (Windows file lock) before removal.
      if command -v node >/dev/null 2>&1; then
        node "$_ORPHAN_DIRS_SCRIPT_CHECKOUT_ROOT/bin/codegraph-lifecycle.js" stop --path "$cand_dir" || true
      fi

      node_rc=0
      node_out="$(node "$_ORPHAN_DIRS_SCRIPT_CHECKOUT_ROOT/hooks/cleanup-orphan-dir.js" \
        --force-if-not-registered "${main_root_args[@]}" "$cand_dir" 2>&1)" || node_rc=$?
      if [[ "$node_rc" -eq 0 ]]; then
        orphan_dirs_removed=$((orphan_dirs_removed + 1))
      else
        orphan_dirs_skipped_failed=$((orphan_dirs_skipped_failed + 1))
        printf 'WARNING: cleanup-orphan-dir failed for %s: %s\n' "$cand_dir" "$node_out" >&2
      fi
    fi
  done < <(find "$WORKTREE_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
  cleanup_registered_files
}

# Remove stale <target-main-root>/.worktree-backup/* directories.
sweep_stale_backups() {
  local backup_base="$TARGET_MAIN_ROOT/.worktree-backup"
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

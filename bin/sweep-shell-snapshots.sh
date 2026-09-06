#!/bin/bash
#
# bin/sweep-shell-snapshots.sh — delete Claude Code shell snapshots whose
# `export PATH='...'` line was corrupted by stray login-shell stdout (#2160).
# Usage: sweep-shell-snapshots.sh [--dry-run|--apply] [--min-age-minutes N]
# Deletes by default; --dry-run previews. Exit 1 on an argument error, else 0.

# A snapshot is a candidate when its FIRST PATH element repeats a startup
# progress line from bin/lib/session-sync-markers.sh (reason=known-marker) or
# names a directory that does not exist (reason=missing-dir). Only the first
# element: a healthy PATH may carry a stale directory further down, and deleting
# on that would destroy an uncorrupted snapshot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Corruption markers: SSOT shared with profile-snippet.sh, which prints them.
# shellcheck source=lib/session-sync-markers.sh
source "$SCRIPT_DIR/lib/session-sync-markers.sh"

# Write-mode semantics: the apply-by-default contract of the /sweep family.
# Guarded with an inline fallback so the script still runs from a partial copy
# carrying only itself and the marker lib.
if [[ -f "$SCRIPT_DIR/lib/sweep-write-mode.sh" ]]; then
  # shellcheck source=lib/sweep-write-mode.sh
  source "$SCRIPT_DIR/lib/sweep-write-mode.sh"
else
  sweep_write_mode_init() { APPLY=1; DRY_RUN=0; }
  sweep_write_mode_dry_run() { APPLY=0; DRY_RUN=1; }
  sweep_write_mode_apply() { APPLY=1; DRY_RUN=0; }
  sweep_write_mode_usage_lines() {
    printf '  --dry-run             Classify and report only; write nothing.\n'
    printf '  --apply               Explicit apply (default; kept for compatibility).\n'
  }
fi

# ─── Defaults ──────────────────────────────────────────────────────────────

sweep_write_mode_init
MIN_AGE_MINUTES=1440

# ─── Validators ────────────────────────────────────────────────────────────

validate_min_age_minutes() {
  case "$1" in
    ''|*[!0-9]*)
      printf 'ERROR: --min-age-minutes must be a non-negative integer (got: %s)\n' "$1" >&2
      exit 1
      ;;
    0?*)
      # `$(( ))` reads a leading-zero numeral as octal, so 08 is an arithmetic
      # error and 010 silently means 8; reject instead of guessing the intent.
      printf 'ERROR: --min-age-minutes must not have a leading zero (bash reads it as octal) (got: %s)\n' "$1" >&2
      exit 1
      ;;
    ????????????????*)
      # >15 digits: 64-bit signed arithmetic could wrap a huge holdback into a
      # small or negative one, defeating the guard the operator asked for.
      printf 'ERROR: --min-age-minutes must be at most 15 digits (got: %s)\n' "$1" >&2
      exit 1
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: sweep-shell-snapshots.sh [options]

Options:
EOF
  sweep_write_mode_usage_lines
  cat <<'EOF'
  --min-age-minutes N   Hold back snapshots younger than N minutes (default 1440).
  -h, --help            Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) sweep_write_mode_apply ;;
    --dry-run) sweep_write_mode_dry_run ;;
    --min-age-minutes)
      shift
      MIN_AGE_MINUTES="${1:?--min-age-minutes requires a value}"
      validate_min_age_minutes "$MIN_AGE_MINUTES"
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'ERROR: unknown flag: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

SNAPSHOTS_DIR="$HOME/.claude/shell-snapshots"

if [[ ! -d "$SNAPSHOTS_DIR" ]]; then
  printf 'shell-snapshots dir not found: %s\n' "$SNAPSHOTS_DIR"
  exit 0
fi

# A symlinked snapshots dir would aim the glob — and the default-apply `rm` —
# at files outside ~/.claude entirely, so refuse rather than delete off-scope.
# Containment must hold for the whole path, not just the final component: a
# symlinked ancestor (~/.claude, or $HOME itself) redirects the physical
# location the same way a symlinked SNAPSHOTS_DIR does. Comparing resolved
# physical paths (rather than walking ancestors with `dirname`, checking each
# for -L) catches that in one step, has no unbounded-loop edge case on a
# drive-letter or UNC HOME, and does not misfire on a host where a physical
# indirection above HOME is normal and containment is still intact (e.g.
# macOS's /var -> /System/Volumes/Data/var).
resolved_home="$(cd -P -- "$HOME" 2>/dev/null && pwd -P)" || resolved_home=""

snapshots_dir_is_physically_expected() {
  local resolved
  resolved="$(cd -P -- "$SNAPSHOTS_DIR" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$resolved_home" && "$resolved" == "$resolved_home/.claude/shell-snapshots" ]]
}

if [[ -L "$SNAPSHOTS_DIR" ]] || ! snapshots_dir_is_physically_expected; then
  printf 'ERROR: refusing to sweep: shell-snapshots dir does not resolve to the expected physical location under HOME: %s\n' "$SNAPSHOTS_DIR" >&2
  exit 1
fi

# Bind this process's CWD to the verified physical directory so each delete
# below can address its file by bare name instead of by re-walking
# "$SNAPSHOTS_DIR" — a relative name resolves against the kernel's cwd
# inode, which stays fixed to the directory just verified even if the
# SNAPSHOTS_DIR path string is later replaced with a symlink. That collapses
# the whole per-file check-then-act window (once per loop iteration) into a
# single race at this one `cd`, which the guard above already minimizes.
if ! cd -P -- "$SNAPSHOTS_DIR" 2>/dev/null; then
  printf 'ERROR: refusing to sweep: could not enter shell-snapshots dir: %s\n' "$SNAPSHOTS_DIR" >&2
  exit 1
fi

# `cd` succeeding proves nothing about *where* it landed: a symlink swap
# between the check above and this `cd` would make `cd -P` itself follow the
# attacker's link and land the whole rest of the run somewhere else. Re-check
# the physical destination against the same expected path, using pwd -P
# directly rather than re-invoking snapshots_dir_is_physically_expected
# (which re-resolves "$SNAPSHOTS_DIR" — the very path string a second swap
# could have already redirected — instead of trusting the cwd already bound).
if [[ "$(pwd -P)" != "$resolved_home/.claude/shell-snapshots" ]]; then
  printf 'ERROR: refusing to sweep: entered directory does not match the expected physical location: %s\n' "$SNAPSHOTS_DIR" >&2
  exit 1
fi

# ─── Counters + helpers ────────────────────────────────────────────────────

scanned=0
candidates=0
removed=0
skipped_young=0

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

now_epoch="$(date +%s)"

# ─── Scan ──────────────────────────────────────────────────────────────────
#
# Exactly `$SNAPSHOTS_DIR/*.sh`, never a recursive walk: a non-.sh sibling, a
# file one level up and a nested subdir/*.sh stay out of scope even when they
# carry the same corruption. nullglob keeps an empty directory out of the loop.

shopt -s nullglob

for f in "$SNAPSHOTS_DIR"/*.sh; do
  scanned=$(( scanned + 1 ))
  # A directory can match the glob and a binary blob defeats a line read; neither
  # may abort the run, which would leave real candidates silently in place.
  [[ -f "$f" ]] || continue

  # Real snapshots open with a preamble, so the PATH assignment is not line 1.
  line1="$(grep -m1 "^export PATH='" "$f" 2>/dev/null || true)"
  [[ -n "$line1" ]] || continue

  # Age from stat epochs, never a `find` age flag: on Windows Git Bash `find`
  # can resolve to C:\Windows\System32\find.exe, which rejects it, and the guard
  # would then fail closed against a live session's own snapshot.
  mtime="$(file_mtime "$f")"
  # Unparsable/unavailable mtime (stat failed both forms) is treated as "now"
  # (age 0), not epoch 0 ("infinitely old") — a fail-open toward deletion
  # would delete a file whose real age is unknown.
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$now_epoch"
  if [[ $(( (now_epoch - mtime) / 60 )) -lt "$MIN_AGE_MINUTES" ]]; then
    skipped_young=$(( skipped_young + 1 ))
    continue
  fi

  val="${line1#export PATH=\'}"
  val="${val%\'}"
  # A drive-letter first element (C:/Users/...) has its own colon before the
  # real separator; splitting on the first colon in the whole string yields
  # just "C", not the path, so a Windows-style leading element misparses as
  # missing-dir. Skip the drive-letter colon before finding the separator.
  if [[ "$val" =~ ^[A-Za-z]: ]]; then
    rest="${val:2}"
    first_elem="${val:0:2}${rest%%:*}"
  else
    first_elem="${val%%:*}"
  fi

  known=0
  missing=0
  case "$val" in
    "$AGENTS_SESSION_SYNC_FETCH_MARKER"*|"$AGENTS_SYMLINK_REPAIR_MARKER"*) known=1 ;;
  esac
  # No -n guard: an empty first element is itself a corrupted PATH line.
  if [[ ! -d "$first_elem" ]]; then missing=1; fi

  if [[ "$known" == "0" ]] && [[ "$missing" == "0" ]]; then
    continue
  fi

  reason="missing-dir"
  if [[ "$known" == "1" ]]; then reason="known-marker"; fi
  candidates=$(( candidates + 1 ))

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: candidate snapshot=%s reason=%s\n' "$f" "$reason"
    continue
  fi

  if [[ "$APPLY" == "1" ]]; then
    # Re-check as a diagnostic, but correctness no longer depends on it: the
    # delete below addresses the file by bare name relative to the cwd bound
    # above, so it stays inside the verified physical directory even if
    # SNAPSHOTS_DIR (the path string) is swapped to a symlink after this point.
    if [[ -L "$SNAPSHOTS_DIR" ]] || ! snapshots_dir_is_physically_expected; then
      printf 'ERROR: refusing to remove %s: shell-snapshots dir no longer resolves to its expected physical location\n' "$f" >&2
    elif rm -f -- "${f##*/}" 2>/dev/null; then
      removed=$(( removed + 1 ))
    else
      printf 'ERROR: could not remove %s\n' "$f" >&2
    fi
  fi
done

# ─── Summary ───────────────────────────────────────────────────────────────
#
# One line, counts only: snapshot content is whatever stdout leaked into a login
# shell, so it is never echoed back to the operator's terminal.

kept=$(( scanned - candidates ))
printf 'sweep-shell-snapshots: scanned=%d candidates=%d removed=%d kept=%d skipped_young=%d\n' \
  "$scanned" "$candidates" "$removed" "$kept" "$skipped_young"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '  (dry-run; nothing was written — omit --dry-run to apply)\n'
fi

exit 0

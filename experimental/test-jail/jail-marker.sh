#!/usr/bin/env bash
# jail-marker.sh — EXPERIMENTAL (#2585). Sourced by run-list.sh and compare-runs.sh: the only
# place that deletes an output directory. A directory is deleted only when it is empty or holds
# the .test-jail-dir marker this file wrote when it made the directory, with the expected kind
# (run | compare). Nothing here adds a marker to an existing non-empty directory.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "jail-marker.sh: source-only (run-list.sh and compare-runs.sh source it); nothing was done" >&2
  exit 2
fi

JAIL_MARKER_NAME=".test-jail-dir"
JAIL_MARKER_TOOL="tool=experimental/test-jail"

# jail_marker_check <dir> <kind> — 0 when <dir> holds this tool's marker of that kind.
jail_marker_check() {
  local marker="$1/$JAIL_MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  grep -qxF "$JAIL_MARKER_TOOL" "$marker" && grep -qxF "kind=$2" "$marker"
}

# jail_marker_precheck <dir> <kind> — 0 when <dir> may be replaced: absent, empty, or marked.
jail_marker_precheck() {
  local dir="$1" kind="$2" real home_real=""
  if [[ -z "$dir" ]]; then
    echo "ABORT: the output path is empty" >&2
    return 2
  fi
  [[ -e "$dir" || -L "$dir" ]] || return 0
  # Never a deletion target, marker or not: the filesystem root, HOME, a git checkout.
  if [[ -d "$dir" ]]; then
    real="$(cd "$dir" 2>/dev/null && pwd -P)"
    [[ -z "${HOME:-}" ]] || home_real="$(cd "$HOME" 2>/dev/null && pwd -P)"
    if [[ -z "$real" || "$real" == / || "$real" == "$home_real" || -e "$dir/.git" ]]; then
      echo "ABORT: $dir is the filesystem root, HOME or a git checkout. Choose a new output path." >&2
      return 2
    fi
    [[ -n "$(ls -A "$dir" 2>/dev/null)" ]] || return 0
    jail_marker_check "$dir" "$kind" && return 0
  fi
  echo "ABORT: $dir exists and was not made by test-jail (no $JAIL_MARKER_NAME marker of kind=$kind). Choose a new output path, or delete the directory yourself." >&2
  return 2
}

_jail_marker_write() {
  printf '%s\n' "$JAIL_MARKER_TOOL" "kind=$2" "creator=$3" "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "format=1" \
    > "$1/$JAIL_MARKER_NAME"
}

# jail_marker_prepare <dir> <kind> <creator> — <dir> becomes a fresh, marked, empty directory.
jail_marker_prepare() {
  jail_marker_precheck "$1" "$2" || return 2
  rm -rf "$1" || return 2
  mkdir -p "$1" || return 2
  _jail_marker_write "$1" "$2" "$3" || return 2
}

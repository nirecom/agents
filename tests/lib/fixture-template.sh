#!/usr/bin/env bash
# tests/lib/fixture-template.sh — sourced.
# Tests: tests/lib/fixture-template.sh
# Tags: scope:common, shared-lib
# Build a git repo once (the template), then clone it per case with a whole-directory copy.
# The template is read-only: a case writes only into its copy.
#   fixture_template_git_repo <dest> [branch] [--no-commit]
#       Initial commit with a README by default; --no-commit leaves the repo unborn
#       (no HEAD, empty working tree). Config is set here, once, never on a copy.
#   fixture_template_copy <template> <dest>
#       cp -a of the whole directory (working tree included); fails when <dest> exists.

fixture_template_git_repo() {
  local dest="${1:-}" branch="main" commit=1 arg
  if [[ -z "$dest" ]]; then
    echo "fixture_template_git_repo: destination directory required" >&2
    return 1
  fi
  shift
  for arg in "$@"; do
    case "$arg" in
      --no-commit) commit=0 ;;
      *) branch="$arg" ;;
    esac
  done
  mkdir -p "$dest" || return 1
  git init -q -b "$branch" "$dest" || return 1
  git -C "$dest" config user.email "test@example.com" || return 1
  git -C "$dest" config user.name "Test" || return 1
  git -C "$dest" config core.hooksPath /dev/null || return 1
  git -C "$dest" config commit.gpgsign false || return 1
  git -C "$dest" config core.autocrlf false || return 1
  if [[ "$commit" -eq 1 ]]; then
    printf '%s\n' "# fixture" >"$dest/README.md" || return 1
    git -C "$dest" add README.md || return 1
    git -C "$dest" commit -q -m "initial" || return 1
  fi
  return 0
}

fixture_template_copy() {
  local template="${1:-}" dest="${2:-}"
  if [[ -z "$template" || -z "$dest" ]]; then
    echo "fixture_template_copy: template and destination required" >&2
    return 1
  fi
  if [[ ! -d "$template" ]]; then
    echo "fixture_template_copy: template is not a directory: $template" >&2
    return 1
  fi
  if [[ -e "$dest" ]]; then
    echo "fixture_template_copy: destination already exists: $dest" >&2
    return 1
  fi
  cp -a "$template" "$dest"
}

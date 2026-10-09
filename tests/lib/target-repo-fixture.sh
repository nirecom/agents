#!/usr/bin/env bash
# tests/lib/target-repo-fixture.sh — sourced.
# target_repo_fixture_create <base_dir> builds, under an existing <base_dir>, a git repository
# that is NOT the agents repository (its main worktree) plus one linked worktree, and sets the
# shell variables TARGET_MAIN_ROOT and TARGET_CHECKOUT_ROOT (never exported: a child receives
# them only as an argument or a one-command prefix). Paths are forward-slash, usable from bash
# and node alike. Git hooks are disabled in the fixture repository.

target_repo_fixture_create() {
  local base="${1:-}" main linked
  if [[ -z "$base" || ! -d "$base" ]]; then
    echo "target_repo_fixture_create: an existing base directory is required" >&2
    return 1
  fi
  if command -v cygpath >/dev/null 2>&1; then base="$(cygpath -m "$base")"; fi
  base="${base%/}"
  main="$base/target-main"
  linked="$base/target-linked"
  if [[ -e "$main" || -e "$linked" ]]; then
    echo "target_repo_fixture_create: $base already holds a target fixture" >&2
    return 1
  fi
  git init -q "$main" || return 1
  git -C "$main" config core.hooksPath /dev/null || return 1
  git -C "$main" config user.name "Target Fixture" || return 1
  git -C "$main" config user.email "target-fixture@example.invalid" || return 1
  git -C "$main" config commit.gpgsign false || return 1
  printf 'target repository fixture\n' >"$main/README.md" || return 1
  git -C "$main" add README.md || return 1
  git -C "$main" commit -q -m "initial commit" || return 1
  git -C "$main" worktree add -q -b target-fixture-linked "$linked" || return 1
  # shellcheck disable=SC2034  # read by the sourcing test
  TARGET_MAIN_ROOT="$main"
  # shellcheck disable=SC2034  # read by the sourcing test
  TARGET_CHECKOUT_ROOT="$linked"
}

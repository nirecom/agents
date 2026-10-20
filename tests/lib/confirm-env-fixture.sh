# shellcheck shell=bash
# tests/lib/confirm-env-fixture.sh — a per-test global .env for the plan-stage CONFIRM flags.
# Tests: tests/lib/confirm-env-fixture.sh
# Tags: test-infrastructure, shared-lib, confirm-gate, fixture, scope:common
# CONFIRM_INTENT/OUTLINE/DETAIL are read from $AGENTS_MAIN_ROOT/.env only (#2726/#2729), so a test
# writes a .env in its own temp dir and points AGENTS_MAIN_ROOT there (JS twin: confirm-env-fixture.js).

# _confirm_env_write <file> KEY=VAL... — one KEY=VAL line per argument.
_confirm_env_write() {
  local file="$1" kv
  shift
  : >"$file"
  for kv in "$@"; do printf '%s\n' "$kv" >>"$file"; done
}

# confirm_env_root <dir> [KEY=VAL ...] — write <dir>/.env, export AGENTS_MAIN_ROOT=<dir>, unset the
# exported plan-stage keys so a leftover export cannot mask the file.
confirm_env_root() {
  local dir="${1:?confirm_env_root: dir required}"
  shift
  mkdir -p "$dir"
  _confirm_env_write "$dir/.env" "$@"
  unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
  if command -v cygpath >/dev/null 2>&1; then dir="$(cygpath -m "$dir")"; fi
  export AGENTS_MAIN_ROOT="$dir"
}

# confirm_env_set <dir> [KEY=VAL ...] — rewrite <dir>/.env in place (AGENTS_MAIN_ROOT unchanged).
confirm_env_set() {
  local dir="${1:?confirm_env_set: dir required}"
  shift
  _confirm_env_write "$dir/.env" "$@"
}

# confirm_env_local <dir> [KEY=VAL ...] — write <dir>/.env.local (the per-machine overlay).
confirm_env_local() {
  local dir="${1:?confirm_env_local: dir required}"
  shift
  _confirm_env_write "$dir/.env.local" "$@"
}

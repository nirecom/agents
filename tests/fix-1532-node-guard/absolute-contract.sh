# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, absolute-contract, scope:issue-specific, pwsh-not-required, TL2

# A: absolute expected values, not a comparison against a twin.

# Why this file exists (review-tests C1): the B group derives its stripped twin
# from the SAME post-change file it is judging. If the envelope insertion also
# damaged the body -- the concrete named risk is get-config-var's internal
# `node -e` block, whose JavaScript now lives inside a bash here-document region
# -- both sides break identically and every B row still passes. A twin comparison
# can only ever prove "the envelope changed nothing"; it cannot prove the script
# still does its job. These rows state what the job IS, in literal values.

# Small on purpose: the contract of each target is owned by its own feature test.
# What is pinned here is the handful of behaviours that would go silently wrong if
# the envelope corrupted the body, and get-config-var's node path is pinned first
# because it is the one C1 named.

echo "=== A: absolute behaviour contract for $GUARD_TARGET ==="

A_TMP="$TESTTMP/absolute-contract"
A_CFG="$A_TMP/cfg"
A_SID="fix1532abs"
mkdir -p "$A_TMP" "$A_CFG"

# The fixture config dir is a real AGENTS_CONFIG_DIR: bin/ and hooks/ point at the
# tree under test, and .env holds keys that exist nowhere else, so the expected
# values below are properties of the code and not of the developer's own .env.
a_setup_config() {
  ln -s "$REPO_ROOT/hooks" "$A_CFG/hooks" 2>/dev/null || cp -R "$REPO_ROOT/hooks" "$A_CFG/hooks" || return 1
  ln -s "$REPO_ROOT/bin" "$A_CFG/bin" 2>/dev/null || cp -R "$REPO_ROOT/bin" "$A_CFG/bin" || return 1
  printf 'FIX1532_ABS_KEY=abs-value-1532\nFIX1532_ABS_OFF=off\nFIX1532_ABS_ON=on\n' > "$A_CFG/.env" || return 1
  return 0
}

# a_run — one invocation, two absolute assertions (exit code and stdout). The
# byte-exact channel comparison stays the B group's job; what is added here is the
# expected VALUE, which no twin comparison can supply.
a_run() { # <row> <want-rc> <want-stdout> <cmd> [args...]
  local row="$1" want_rc="$2" want_out="$3"; shift 3
  local rc got
  "$@" > "$A_TMP/out" 2> "$A_TMP/err"
  rc=$?
  got="$(cat "$A_TMP/out")"
  check "A[$row]: exit code" "$want_rc" "$rc"
  check "A[$row]: stdout" "$want_out" "$got"
}

a_get_config_var() {
  local t
  t="$(target_path get-config-var)"
  export AGENTS_CONFIG_DIR="$A_CFG"
  # The row C1 asked for: a value only .env knows can be produced ONLY by the
  # internal `node -e` block running and load-env.js being reachable. If the
  # envelope swallowed that block, this row reports an empty string.
  a_run "get-config-var/value" 0 "abs-value-1532" bash "$t" FIX1532_ABS_KEY
  a_run "get-config-var/usage" 64 "" bash "$t"
  a_run "get-config-var/is-off-off" 0 "" bash "$t" --is-off FIX1532_ABS_OFF
  a_run "get-config-var/is-off-on" 1 "" bash "$t" --is-off FIX1532_ABS_ON
  a_run "get-config-var/is-off-unset" 2 "" bash "$t" --is-off FIX1532_ABS_ABSENT
  unset AGENTS_CONFIG_DIR
}

a_confirm_off() {
  local t
  t="$(target_path confirm-off)"
  export AGENTS_CONFIG_DIR="$A_CFG"
  a_run "confirm-off/off" 0 "OFF" bash "$t" FIX1532_ABS_OFF
  a_run "confirm-off/on" 1 "ON" bash "$t" FIX1532_ABS_ON
  a_run "confirm-off/default-on" 1 "ON" bash "$t" FIX1532_ABS_ABSENT on
  unset AGENTS_CONFIG_DIR
}

# The positive path, which the B cases cannot reach: they only ever ask about a
# session that does not exist. CLAUDE_CODE_SESSION_ID is priority 2 of the
# resolution chain, so the answer is decided before any filesystem scan runs.
a_resolve_session_id() {
  local t
  t="$(target_path resolve-session-id)"
  export CLAUDE_CODE_SESSION_ID="$A_SID"
  a_run "resolve-session-id/resolved" 0 "$A_SID" bash "$t"
  unset CLAUDE_CODE_SESSION_ID
}

# Same idea one level up: a state file whose `cwd` is this linked worktree makes
# resolveSessionWorktreePath return a path, so the row asserts that exact path
# rather than only the NOSTATE branch. The state file lives in the fixture's
# CLAUDE_WORKFLOW_DIR, so the developer's real workflow store is never touched.
a_resolve_worktree_path() {
  local t wt
  t="$(target_path resolve-worktree-path)"
  if command -v cygpath >/dev/null 2>&1; then wt="$(cygpath -m "$REPO_ROOT")"; else wt="$REPO_ROOT"; fi
  printf '{"session_id":"%s","cwd":"%s"}' "$A_SID" "$wt" > "$CLAUDE_WORKFLOW_DIR/$A_SID.json"
  export SESSION_ID="$A_SID"
  a_run "resolve-worktree-path/resolved" 0 "$wt" bash "$t"
  export SESSION_ID="${A_SID}nostate"
  a_run "resolve-worktree-path/nostate" 0 "NOSTATE" bash "$t"
  unset SESSION_ID
}

# A throwaway repo rather than this checkout: the answer must depend on the remote
# URL under test, not on whichever remote the developer's fork happens to carry.
a_is_github_dotcom_remote() {
  local t repo
  t="$(target_path is-github-dotcom-remote)"
  repo="$A_TMP/gh-repo"
  a_run "is-github-dotcom-remote/url-github" 0 "" bash "$t" --url https://github.com/owner/repo.git
  a_run "is-github-dotcom-remote/url-other" 1 "" bash "$t" --url git@example.com:owner/repo.git
  mkdir -p "$repo"
  git -C "$repo" init -q >/dev/null 2>&1
  git -C "$repo" config core.hooksPath /dev/null >/dev/null 2>&1
  git -C "$repo" remote add origin https://github.com/owner/repo.git >/dev/null 2>&1
  if [ -d "$repo/.git" ]; then
    a_run "is-github-dotcom-remote/repo-dir" 0 "" bash "$t" "$repo"
  else
    fail "A[is-github-dotcom-remote/repo-dir]: could not create the fixture git repo, so the directory form is unproven"
  fi
}

a_main() {
  if ! a_setup_config; then
    fail "A[$GUARD_TARGET]: the fixture AGENTS_CONFIG_DIR could not be built (no symlink, no copy), so no absolute value can be asserted"
    return 0
  fi
  case "$GUARD_TARGET" in
    get-config-var)           a_get_config_var ;;
    confirm-off)              a_confirm_off ;;
    resolve-session-id)       a_resolve_session_id ;;
    resolve-worktree-path)    a_resolve_worktree_path ;;
    is-github-dotcom-remote)  a_is_github_dotcom_remote ;;
  esac
}

a_main

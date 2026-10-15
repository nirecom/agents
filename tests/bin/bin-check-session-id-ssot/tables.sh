#!/usr/bin/env bash
# Tests: bin/check-session-id-ssot.sh
# Tags: TL2, scope:common, pwsh-not-required, session-id, ssot, static-guard, table-driven
# Part file of tests/bin/bin-check-session-id-ssot.sh (sourced; uses its GUARD, RUN_TIMEOUT,
# TMPDIR_BASE, FIXTURE, make_fixture, add_file, expect_rc, GUARD_RC, GUARD_OUT and pass/fail).
# Issue #2638: the guard judges with the path tables of the tree it scans
# (bin/check-session-id-ssot/path-tables.txt under cwd), not with the ones next to itself;
# a tree without one falls back with a notice, a present but broken one is exit 2.
# TL3 gap: the guard firing from the real pre-commit hook of a linked worktree.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: hook-registration.

TBL_REL="bin/check-session-id-ssot/path-tables.txt"
# The retired relay name, assembled at run time so this file never spells it.
TBL_RETIRED="CLAUDE_""SESSION_ID"
TBL_ENV_READ="const sid = process.env.CLAUDE_CODE_SESSION_ID;"
TBL_RESOLVER="hooks/lib/resolve-workflow-session-id.js"
TBL_PURGE="hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
TBL_SHARED="bin/lib/run-tests-baseline-exec.sh"
TBL_ERR=""

# tbl_repo <name> — a fresh fixture repo that stages bytes as written (the CRLF table needs them).
tbl_repo() {
  make_fixture "tbl-$1"
  git -C "$FIXTURE" config core.autocrlf false
}

# tbl_write_table <allowlist> <tombstone-exempt> <isolation-files> — space-separated paths per section.
tbl_write_table() {
  local a e i
  a="$(printf '%s\n' $1)"; e="$(printf '%s\n' $2)"; i="$(printf '%s\n' $3)"
  add_file "$TBL_REL" "[ALLOWLIST]" "$a" "" "[TOMBSTONE_EXEMPT]" "$e" "" "[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]" "$i"
}

# tbl_run [args...] — the guard with cwd = the fixture, the whole fixture staged first.
# stdout in GUARD_OUT, stderr (\ folded to /) in TBL_ERR, exit code in GUARD_RC.
tbl_run() {
  git -C "$FIXTURE" add -A 2>/dev/null
  GUARD_OUT="$(cd "$FIXTURE" && env -u "$TBL_RETIRED" -u CLAUDE_CODE_SESSION_ID \
    bash "$RUN_TIMEOUT" 60 bash "$GUARD" "$@" 2>"$TMPDIR_BASE/tbl-stderr.txt" </dev/null)"
  GUARD_RC=$?
  TBL_ERR="$(tr '\\' '/' < "$TMPDIR_BASE/tbl-stderr.txt")"
}

# tbl_expect <label> <yes|no> <text> <needle> — <text> contains <needle> (any letter case), or not.
tbl_expect() {
  local got=no text="${3,,}" needle="${4,,}"
  if [[ "$text" == *"$needle"* ]]; then got=yes; fi
  if [[ "$got" == "$2" ]]; then
    pass "$1"
  else
    fail "$1: want=$2 got=$got (out: $(printf '%s\n' "$GUARD_OUT" "$TBL_ERR" | head -3 | tr '\n' ' '))"
  fi
}

# Rows: <label> | <section> | <path the judged table lists> | <path the tree carries> | <exit>.
# "add" rows list a path the guard's own table lacks; "remove" rows drop one it has. Every row
# runs in the whole-tree form and in the --staged pre-commit form.
while IFS='|' read -r TBL_LABEL TBL_SEC TBL_LISTED TBL_CARRIED TBL_WANT; do
  [[ -z "$TBL_LABEL" ]] && continue
  TBL_LABEL="${TBL_LABEL//[[:space:]]/}"; TBL_SEC="${TBL_SEC//[[:space:]]/}"
  TBL_LISTED="${TBL_LISTED//[[:space:]]/}"; TBL_CARRIED="${TBL_CARRIED//[[:space:]]/}"
  TBL_WANT="${TBL_WANT//[[:space:]]/}"
  tbl_repo "$TBL_LABEL"
  case "$TBL_SEC" in
    ALLOWLIST)
      tbl_write_table "$TBL_LISTED" "" ""
      add_file "$TBL_CARRIED" "$TBL_ENV_READ" ;;
    TOMBSTONE_EXEMPT)
      tbl_write_table "" "$TBL_LISTED" ""
      add_file "$TBL_CARRIED" "// strips $TBL_RETIRED from old state files" ;;
    TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS)
      tbl_write_table "" "" "$TBL_LISTED"
      add_file "$TBL_CARRIED" "    unset $TBL_RETIRED CLAUDE_CODE_SESSION_ID" ;;
    *)
      fail "tables/$TBL_LABEL: fixture: unknown section $TBL_SEC"
      continue ;;
  esac
  for TBL_FORM in whole-tree --staged; do
    if [[ "$TBL_FORM" == "--staged" ]]; then tbl_run --staged; else tbl_run; fi
    expect_rc "tables/$TBL_LABEL ($TBL_FORM): the judged tree's table decides" "$TBL_WANT"
    if [[ "$TBL_WANT" == "0" ]]; then
      tbl_expect "tables/$TBL_LABEL ($TBL_FORM): no fallback notice while the judged tree carries its table" \
        no "$TBL_ERR" "$TBL_REL"
      continue
    fi
    tbl_expect "tables/$TBL_LABEL ($TBL_FORM): the report names the file" yes "$GUARD_OUT" "$TBL_CARRIED"
    [[ "$TBL_SEC" == "ALLOWLIST" ]] && continue
    tbl_expect "tables/$TBL_LABEL ($TBL_FORM): the report says the name is retired" yes "$GUARD_OUT" "retired"
  done
done <<'TABLE'
allow-add        | ALLOWLIST                               | hooks/new-resolver.js                                           | hooks/new-resolver.js                                           | 0
allow-remove     | ALLOWLIST                               | hooks/workflow-state/session-id.js                              | hooks/lib/resolve-workflow-session-id.js                        | 1
exempt-add       | TOMBSTONE_EXEMPT                        | lib/new-purge.js                                                | lib/new-purge.js                                                | 0
exempt-remove    | TOMBSTONE_EXEMPT                        | lib/new-purge.js                                                | hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js | 1
isolation-add    | TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS | bin/lib/new-exec.sh                                             | bin/lib/new-exec.sh                                             | 0
isolation-remove | TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS | bin/lib/new-exec.sh                                             | bin/lib/run-tests-baseline-exec.sh                              | 1
TABLE

# An empty section is a valid table: the list is empty, the run is not a usage error.
tbl_repo empty-clean
tbl_write_table "" "" ""
add_file "hooks/plain.js" "const x = process.env.HOME;"
tbl_run
expect_rc "tables/empty-section: three empty sections over a clean tree pass" 0
tbl_repo empty-isolation
tbl_write_table "$TBL_RESOLVER" "$TBL_PURGE" ""
add_file "$TBL_SHARED" "    unset $TBL_RETIRED CLAUDE_CODE_SESSION_ID"
tbl_run
expect_rc "tables/empty-section: an empty isolation section lists nothing, so the unset line is flagged" 1

# The format tolerates CRLF, comment lines, blank lines and surrounding whitespace.
tbl_repo format
mkdir -p "$FIXTURE/${TBL_REL%/*}"
printf '%s\r\n' "# path tables" "" "[ALLOWLIST]" "# the resolver" "  hooks/new-resolver.js  " "" \
  "[TOMBSTONE_EXEMPT]" "[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]" > "$FIXTURE/$TBL_REL"
add_file "hooks/new-resolver.js" "$TBL_ENV_READ"
tbl_run
expect_rc "tables/format: CRLF, comments, blank lines and padded entries still allowlist the path" 0

# tbl_write_shape <shape> — the fixture's table in one shape; non-zero for an unknown shape.
tbl_write_shape() {
  local f="$FIXTURE/$TBL_REL" A="[ALLOWLIST]" E="[TOMBSTONE_EXEMPT]" I="[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]"
  rm -rf "$f"
  mkdir -p "${f%/*}"
  case "$1" in
    valid) printf '%s\n' "$A" "$TBL_RESOLVER" "$E" "$I" > "$f" ;;
    unknown-section) printf '%s\n' "$A" "$E" "$I" "[NO_SUCH_SECTION]" "hooks/x.js" > "$f" ;;
    entry-before-section) printf '%s\n' "$TBL_RESOLVER" "$A" "$E" "$I" > "$f" ;;
    no-allowlist) printf '%s\n' "$E" "$I" > "$f" ;;
    no-tombstone-exempt) printf '%s\n' "$A" "$I" > "$f" ;;
    no-isolation-files) printf '%s\n' "$A" "$E" > "$f" ;;
    path-is-a-directory) mkdir "$f" ;;
    *) return 1 ;;
  esac
}

# Rows: <shape> | <expected exit>, each over the same clean tree. "valid" is the control.
tbl_repo broken
add_file "hooks/plain.js" "const x = process.env.HOME;"
while IFS='|' read -r TBL_SHAPE TBL_WANT; do
  [[ -z "$TBL_SHAPE" ]] && continue
  TBL_SHAPE="${TBL_SHAPE//[[:space:]]/}"; TBL_WANT="${TBL_WANT//[[:space:]]/}"
  if ! tbl_write_shape "$TBL_SHAPE"; then
    fail "tables/broken/$TBL_SHAPE: fixture: the shape did not apply"
    continue
  fi
  tbl_run
  expect_rc "tables/broken/$TBL_SHAPE" "$TBL_WANT"
done <<'TABLE'
valid                | 0
unknown-section      | 2
entry-before-section | 2
no-allowlist         | 2
no-tombstone-exempt  | 2
no-isolation-files   | 2
path-is-a-directory  | 2
TABLE

# A tree without the data file is judged with the guard's own tables, and says so on stderr.
tbl_repo fallback-pass
add_file "hooks/workflow-state/session-id.js" "$TBL_ENV_READ"
tbl_run
expect_rc "tables/fallback: a really allowlisted resolver still passes without a table" 0
tbl_expect "tables/fallback: stderr names the data file the judged tree lacks" yes "$TBL_ERR" "$TBL_REL"
tbl_expect "tables/fallback: the notice does not read as a tombstone report" no "$TBL_ERR" "retired"
tbl_repo fallback-block
add_file "hooks/other.js" "$TBL_ENV_READ"
tbl_run
expect_rc "tables/fallback: an unlisted file is still flagged without a table" 1
tbl_expect "tables/fallback: the blocking run carries the notice too" yes "$TBL_ERR" "$TBL_REL"
true

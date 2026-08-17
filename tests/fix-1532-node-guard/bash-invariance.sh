# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, invariance, stripped-twin, scope:issue-specific, pwsh-not-required, TL2

# B: the acceptance condition #1532 must not violate. Roughly 65 sanctioned
# `bash bin/<name>` call sites exist across hooks and skills; every one of them has
# to see the same stdout bytes, the same stderr bytes and the same exit code after
# the envelope as before it.

# The comparison is against a STRIPPED TWIN rather than a recorded golden file: a
# golden file freezes today's behaviour of the body too, so an unrelated body change
# would fail here for the wrong reason and get "fixed" by editing the golden. The
# twin is the same body with only the envelope mechanically removed, so the only
# difference the rows can ever see is the envelope itself.

# ACCEPTED LIMIT (review round 2 C1; round 3 C3 restates it, accepted on the same
# grounds). The twin is derived from the live file, so a body broken and stripped
# identically compares equal: this section proves the envelope is inert, not that the
# body is correct. Body correctness is absolute-contract.sh's job, which pins each
# target's stdout and exit code against independent expected values (including
# get-config-var's inner `node -e` route). Not adopted: diffing `git show
# HEAD:bin/<name>` becomes a tautology one run after this PR merges; freezing stderr
# bytes there is not portable, since they carry absolute paths and locale-dependent
# text. Reproducible stderr bytes ARE pinned where they exist -- node-diagnostic.sh
# N8 compares two runs of the same misinvocation (round 3, C7).

# Both copies live in ONE fixture directory so $0/BASH_SOURCE-derived SCRIPT_DIR
# resolves identically for them, and $T/hooks points at the real hooks/ tree so the
# comparison exercises real load-env.js and real workflow-state rather than stubs.

echo "=== B: bash-side byte invariance for $GUARD_TARGET ==="

B_TMP="$TESTTMP/bash-invariance"
mkdir -p "$B_TMP/bin"
LIVE="$B_TMP/bin/$GUARD_TARGET"
TWIN="$B_TMP/bin/$GUARD_TARGET.stripped"

# strip_envelope — drop the head block (its opening line through the here-document
# delimiter) and the tail block (its marker line through EOF), keeping line 1.
strip_envelope() { # <src> <dst>
  awk -v first="$ENVELOPE_FIRST_LINE" -v delim="$ENVELOPE_DELIMITER" -v tailp="$ENVELOPE_TAIL_PREFIX" '
    NR == 1 { print; next }
    state == 3 { next }
    state == 0 && $0 == first { state = 1; next }
    state == 1 { if ($0 == delim) { state = 2 } next }
    index($0, tailp) == 1 { state = 3; next }
    { print }
  ' "$1" > "$2"
}

# The self-check that keeps this harness honest. If the markers were not found the
# twin is a byte copy of the original, every row below passes trivially, and the
# suite reports green while comparing a file with itself.
b_setup() {
  local live_lines twin_lines removed
  cp "$(target_path "$GUARD_TARGET")" "$LIVE" || return 1
  strip_envelope "$LIVE" "$TWIN" || return 1
  chmod +x "$LIVE" "$TWIN" 2>/dev/null || true
  live_lines="$(wc -l < "$LIVE" | tr -d ' ')"
  twin_lines="$(wc -l < "$TWIN" | tr -d ' ')"
  removed=$((live_lines - twin_lines))
  if [ "$removed" -ne "$ENVELOPE_LINES" ]; then
    fail "B0[$GUARD_TARGET]: stripping the envelope removes exactly $ENVELOPE_LINES lines -- it removed $removed, so the guard is not inserted yet (or its literals moved) and every comparison below would be a file against itself"
    return 1
  fi
  pass "B0[$GUARD_TARGET]: stripping the envelope removes exactly $ENVELOPE_LINES lines"
  # Real hooks/, so load-env.js and workflow-state resolve to the production code.
  # A degraded stand-in would make the comparison meaningless, so a failure to
  # provide either form is a failure, never a skip.
  if ln -s "$REPO_ROOT/hooks" "$B_TMP/hooks" 2>/dev/null; then
    pass "B0b[$GUARD_TARGET]: the fixture's hooks/ is a symlink to the real tree"
  elif cp -R "$REPO_ROOT/hooks" "$B_TMP/hooks" 2>/dev/null; then
    pass "B0b[$GUARD_TARGET]: the fixture's hooks/ is a copy of the real tree (symlink unavailable)"
  else
    fail "B0b[$GUARD_TARGET]: the fixture has no hooks/ tree -- neither symlink nor copy succeeded, so the comparison would run degraded"
    return 1
  fi
  return 0
}

# compare_case — run both twins under the same shell, same environment, same
# arguments, and compare all three observable channels bytewise. $( ) is avoided
# for the payloads: it strips trailing newlines, and several of these targets emit
# with printf '%s' and no trailing newline at all.
compare_case() { # <label> <shell> set|unset [args...]
  local label="$1" shl="$2" acd="$3"; shift 3
  local rc1 rc2 tag="B[$GUARD_TARGET] $label ($shl, AGENTS_CONFIG_DIR=$acd)"
  if [ "$acd" = "set" ]; then
    ( export AGENTS_CONFIG_DIR="$REPO_ROOT"
      run_with_timeout 60 "$shl" "$LIVE" "$@" ) >"$B_TMP/o1" 2>"$B_TMP/e1"
    rc1=$?
    ( export AGENTS_CONFIG_DIR="$REPO_ROOT"
      run_with_timeout 60 "$shl" "$TWIN" "$@" ) >"$B_TMP/o2" 2>"$B_TMP/e2"
    rc2=$?
  else
    ( unset AGENTS_CONFIG_DIR
      run_with_timeout 60 "$shl" "$LIVE" "$@" ) >"$B_TMP/o1" 2>"$B_TMP/e1"
    rc1=$?
    ( unset AGENTS_CONFIG_DIR
      run_with_timeout 60 "$shl" "$TWIN" "$@" ) >"$B_TMP/o2" 2>"$B_TMP/e2"
    rc2=$?
  fi
  check "$tag: exit code matches the stripped twin" "$rc2" "$rc1"
  if cmp -s "$B_TMP/o1" "$B_TMP/o2"; then
    pass "$tag: stdout matches the stripped twin byte for byte"
  else
    fail "$tag: stdout differs from the stripped twin -- the envelope changed observable output"
  fi
  if cmp -s "$B_TMP/e1" "$B_TMP/e2"; then
    pass "$tag: stderr matches the stripped twin byte for byte"
  else
    fail "$tag: stderr differs from the stripped twin -- the envelope changed observable output"
  fi
}

# both_env — the same case under AGENTS_CONFIG_DIR set and unset. The two are
# genuinely different code paths in these targets (explicit config dir vs the
# SCRIPT_DIR fallback), so running only one would leave half the resolution logic
# unexercised.
both_env() { # <label> [args...]
  local label="$1"; shift
  compare_case "$label" bash set "$@"
  compare_case "$label" bash unset "$@"
}

b_cases_get_config_var() {
  both_env "L1 value of a defined key" PLAN_LANG
  both_env "L2 absent key with a default" GETCFG_ABSENT_VAR fallbackvalue
  both_env "L3 absent key with no default" GETCFG_ABSENT_VAR
  both_env "L4 usage error (no arguments)"
  unset GETCFG_T
  both_env "L5 --is-off, key unset, default off" --is-off GETCFG_T off
  export GETCFG_T=on
  both_env "L6 --is-off, key set to on in the environment" --is-off GETCFG_T
  unset GETCFG_T
  both_env "L7 --is-off, unrecognized default (stderr warning path)" --is-off GETCFG_T maybe
}

b_cases_confirm_off() {
  export CONFIRM_T=on
  both_env "L1 key set to on" CONFIRM_T
  export CONFIRM_T=off
  both_env "L2 key set to off" CONFIRM_T
  unset CONFIRM_T
  both_env "L3 usage error (no arguments)"
  # The ERROR path: AGENTS_CONFIG_DIR unset is the only way confirm-off reaches it.
  compare_case "L4 AGENTS_CONFIG_DIR unset (ERROR path)" bash unset CONFIRM_T on
}

# No subshell wrappers around any of these: pass/fail increment shell variables,
# and a subshell would drop the counts while still printing the rows.
b_cases_resolve_session_id() {
  both_env "L1 no session id in the environment"
  export SESSION_ID=fix-1532-absent-session
  export CLAUDE_SESSION_ID=fix-1532-absent-session
  both_env "L2 a session id that has no state file"
  unset SESSION_ID CLAUDE_SESSION_ID
}

b_cases_resolve_worktree_path() {
  both_env "L1 no session id in the environment"
  export SESSION_ID=fix-1532-absent-session
  both_env "L2 an unresolvable session id via SESSION_ID (NOSTATE path)"
  unset SESSION_ID
  export CLAUDE_SESSION_ID=fix-1532-absent-session
  both_env "L3 an unresolvable session id via CLAUDE_SESSION_ID (NOSTATE path)"
  unset CLAUDE_SESSION_ID
}

b_cases_is_github_dotcom_remote() {
  both_env "L1 --url on a github.com https remote" --url https://github.com/owner/repo.git
  both_env "L2 --url on a non-github scp-like remote" --url git@example.com:owner/repo.git
  both_env "L3 --url with no value (usage, exit 2)" --url
  both_env "L4 a directory that is not a git repo" "$B_TMP/no-such-directory"
}

# B-POSIX — one case through `sh`. #1532's fix must not have made these scripts
# bash-only at the shebang level: the guard's first line is read by a POSIX shell
# as a no-op command plus a quoted here-document, and any POSIX shell must reach
# the body exactly as it did before. Twin-vs-twin, so a target whose BODY is
# bash-only still compares cleanly — what is pinned is that the ENVELOPE adds no
# new POSIX incompatibility.
b_posix_case() {
  case "$GUARD_TARGET" in
    get-config-var)           compare_case "P1 POSIX sh" sh set PLAN_LANG ;;
    confirm-off)              compare_case "P1 POSIX sh" sh set CONFIRM_T ;;
    resolve-session-id)       compare_case "P1 POSIX sh" sh set ;;
    resolve-worktree-path)    compare_case "P1 POSIX sh" sh set ;;
    is-github-dotcom-remote)  compare_case "P1 POSIX sh" sh set --url https://github.com/owner/repo.git ;;
  esac
}

b_main() {
  b_setup || return 0
  case "$GUARD_TARGET" in
    get-config-var)           b_cases_get_config_var ;;
    confirm-off)              b_cases_confirm_off ;;
    resolve-session-id)       b_cases_resolve_session_id ;;
    resolve-worktree-path)    b_cases_resolve_worktree_path ;;
    is-github-dotcom-remote)  b_cases_is_github_dotcom_remote ;;
  esac
  b_posix_case
}

b_main

# ---- D: the shebang route (review round 5, C1) ------------------------------
# Every row above names the interpreter (`bash <path>` / `sh <path>`), and that form
# never reads line 1. The five commands are ALSO installed on PATH and invoked
# directly by name, where line 1 is the only thing that picks an interpreter -- so a
# `#!/usr/bin/env bash` broken by the envelope insertion would leave this entire
# suite green while every direct-executable and PATH caller died. These rows start
# the file with NO interpreter named and require all three observable channels to be
# byte-identical to the `bash <path>` run of the same arguments.
echo "=== D: shebang (direct-executable) route for $GUARD_TARGET ==="

D_TMP="$TESTTMP/direct-invocation"
mkdir -p "$D_TMP"
D_TARGET="$(target_path "$GUARD_TARGET")"

# The execute bit is a PRECONDITION, never a skip -- the same rule require_node
# states for node. A checkout that lost it cannot answer the question this group
# asks, and a "skipped" row would report the shebang as healthy on a tree where
# nothing can be started that way. G5 already pins mode 100755 in the git index, so
# a miss here means the WORKING TREE disagrees with the index.
d_precondition() {
  if [ -x "$D_TARGET" ]; then
    pass "D0[$GUARD_TARGET]: bin/$GUARD_TARGET is executable in the working tree, so the shebang route is reachable"
    return 0
  fi
  fail "D0[$GUARD_TARGET]: bin/$GUARD_TARGET is NOT executable in this working tree ($D_TARGET) -- the shebang route cannot be exercised at all; git records 100755 (G5), so restore it with chmod +x or fix core.fileMode. This is a missing precondition, not a passing suite"
  return 1
}

# d_compare — identical argv and identical environment, two ways in. `class` states
# what the reference run is expected to BE (a zero or a non-zero exit), so a pair of
# runs that both failed for an unrelated reason cannot masquerade as agreement.
d_compare() { # <label> zero|nonzero [args...]
  local label="$1" class="$2"; shift 2
  local rc_d rc_b tag="D[$GUARD_TARGET] $label"
  ( export AGENTS_CONFIG_DIR="$REPO_ROOT"
    run_with_timeout 60 "$D_TARGET" "$@" ) >"$D_TMP/d.out" 2>"$D_TMP/d.err"
  rc_d=$?
  ( export AGENTS_CONFIG_DIR="$REPO_ROOT"
    run_with_timeout 60 bash "$D_TARGET" "$@" ) >"$D_TMP/b.out" 2>"$D_TMP/b.err"
  rc_b=$?
  if [ "$class" = "zero" ]; then
    check "$tag: the reference \`bash <path>\` run really is a success path" "0" "$rc_b"
  elif [ "$rc_b" -ne 0 ]; then
    pass "$tag: the reference \`bash <path>\` run really is an error path (exit $rc_b)"
  else
    fail "$tag: the reference \`bash <path>\` run was expected to be an error path but exited 0 -- the row is comparing two success runs and proves less than it claims"
  fi
  check "$tag: the direct (shebang) run exits with the same code as \`bash <path>\`" "$rc_b" "$rc_d"
  if cmp -s "$D_TMP/d.out" "$D_TMP/b.out"; then
    pass "$tag: stdout is byte-identical between the shebang route and \`bash <path>\`"
  else
    fail "$tag: stdout differs between the shebang route and \`bash <path>\` -- line 1 is selecting a different interpreter or is no longer a valid shebang"
  fi
  if cmp -s "$D_TMP/d.err" "$D_TMP/b.err"; then
    pass "$tag: stderr is byte-identical between the shebang route and \`bash <path>\`"
  else
    fail "$tag: stderr differs between the shebang route and \`bash <path>\` -- line 1 is selecting a different interpreter or is no longer a valid shebang"
  fi
}

# One success path and one error path per target. resolve-worktree-path is the one
# exception and says so: its documented contract exits 0 for every input, so its
# second row is the degraded-input branch (NOSTATE) rather than a non-zero exit.
d_cases() {
  case "$GUARD_TARGET" in
    get-config-var)
      d_compare "S1 value of a defined key" zero PLAN_LANG
      d_compare "E1 usage error (no arguments)" nonzero ;;
    confirm-off)
      d_compare "S1 unset key with an off default" zero FIX1532_DIRECT_KEY off
      d_compare "E1 usage error (no arguments)" nonzero ;;
    resolve-session-id)
      export CLAUDE_CODE_SESSION_ID=fix1532direct
      d_compare "S1 a session id present in the environment" zero
      unset CLAUDE_CODE_SESSION_ID
      d_compare "E1 no session id anywhere (unresolvable)" nonzero ;;
    resolve-worktree-path)
      export SESSION_ID=fix1532direct
      d_compare "S1 a session id with no state file (NOSTATE branch)" zero
      unset SESSION_ID
      d_compare "S2 no session id at all (empty-stdout branch)" zero ;;
    is-github-dotcom-remote)
      d_compare "S1 --url on a github.com https remote" zero --url https://github.com/owner/repo.git
      d_compare "E1 --url with no value (usage, exit 2)" nonzero --url ;;
  esac
}

# ---- D9: negative control for the whole D group -----------------------------
# Every D row asserts "the two routes agree". An assertion that can only ever see
# agreement is not an assertion: if this harness were in fact starting bash BOTH
# times -- because `timeout` resolved the file through a shell, or because the host
# ignores shebangs and falls back to /bin/sh -- all of the rows above would be green
# on a tree whose line 1 was garbage. Give a COPY a shebang that names a different
# real interpreter and require the two routes to stop agreeing.
d9_negative_control() {
  local copy="$D_TMP/bin/$GUARD_TARGET" rc_d rc_b same=1
  mkdir -p "$D_TMP/bin"
  { printf '#!/usr/bin/env cat\n'; sed -n '2,$p' "$D_TARGET"; } > "$copy" || {
    fail "D9[$GUARD_TARGET]: could not build the broken-shebang copy, so the D rows above have no negative control"
    return 0
  }
  chmod +x "$copy" 2>/dev/null || true
  if [ ! -x "$copy" ]; then
    fail "D9[$GUARD_TARGET]: the broken-shebang copy is not executable, so the D rows above have no negative control"
    return 0
  fi
  run_with_timeout 60 "$copy" >"$D_TMP/n.dout" 2>"$D_TMP/n.derr"
  rc_d=$?
  run_with_timeout 60 bash "$copy" >"$D_TMP/n.bout" 2>"$D_TMP/n.berr"
  rc_b=$?
  [ "$rc_d" = "$rc_b" ] || same=0
  cmp -s "$D_TMP/n.dout" "$D_TMP/n.bout" || same=0
  cmp -s "$D_TMP/n.derr" "$D_TMP/n.berr" || same=0
  if [ "$same" -eq 0 ]; then
    pass "D9[$GUARD_TARGET]: a copy whose line 1 names a different interpreter stops matching \`bash <path>\` -- the D rows above really do go through the shebang"
  else
    fail "D9[$GUARD_TARGET]: a copy whose line 1 names a different interpreter still matches \`bash <path>\` byte for byte -- this host is not honouring the shebang, so every D row above is vacuous"
  fi
}

d_main() {
  d_precondition || return 0
  d_cases
  d9_negative_control
}

d_main

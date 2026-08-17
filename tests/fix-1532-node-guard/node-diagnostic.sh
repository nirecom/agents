# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, node-misinvocation, diagnostics, scope:issue-specific, pwsh-not-required, TL2

# N1-N6: what happens when the ONE target this dispatcher owns is started with
# `node` instead of `bash` — the mistake #1532 is about. Before the guard, node
# parsed the bash body as JavaScript and died with a SyntaxError: exit 1, empty
# stdout, a stack trace on stderr. A caller doing VAL=$(node .../get-config-var X)
# then saw an empty string and an exit code indistinguishable from "variable unset".

# Every assertion runs on TWO stderr routes, and that is the point of this file
# rather than an accident of thoroughness:
#   route F — `2> <regular file>`
#   route P — `2>&1 > <stdout file> | cat > <stderr file>` (stderr on a pipe)
# On this Windows host both routes are synchronous and N5 is always green. It is a
# REGRESSION PIN, not dead weight: if the guard is ever changed back to
# process.stderr.write + process.exit(), a platform with asynchronous pipe stderr
# drops or truncates the pipe route while the file route still looks perfect.
# Do not delete N5 on the grounds that it "always passes here".

echo "=== N: node misinvocation diagnostic for $GUARD_TARGET ==="

N_TMP="$TESTTMP/node-diagnostic"
mkdir -p "$N_TMP"
N_TARGET="$(target_path "$GUARD_TARGET")"

# The path the diagnostic prints is process.argv[1], which for a main module is the
# RESOLVED entry-point path — not the string this shell passed. On Windows those differ
# twice over: the MSYS layer rewrites /c/... into C:/... on the way into a native node.exe,
# and node then normalises that to C:\...  A path built here with `pwd` would never equal
# it. Ask node to resolve the same argument the same way, so the assertion below stays an
# EXACT match on every platform instead of being relaxed to a substring the first time it
# meets one (a substring match is exactly what the test review rejected).
N_ARGV1=""
N_WANT_DIAG=""
n_resolve_argv1() {
  N_ARGV1="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$N_TARGET" 2>/dev/null)"
  case "$N_ARGV1" in
    *"$GUARD_TARGET")
      pass "N0[$GUARD_TARGET]: the path node receives for the target resolves ($N_ARGV1)" ;;
    *)
      fail "N0[$GUARD_TARGET]: could not determine the path node receives for the target -- got [$N_ARGV1], so the exact-match diagnostic assertions below have no expected value"
      return 1 ;;
  esac
  N_WANT_DIAG="$(expected_diagnostic "$N_ARGV1")"
}

# The reference stderr, captured from the no-argument case. Every later case is
# compared against it: the guard runs before the body has looked at anything, so
# the diagnostic must not vary with what was passed (review-tests C3).
N_REF_ERR=""

# route_file / route_pipe both leave stdout in $1.out, stderr in $1.err and echo
# the target's exit status. The pipe route reads ${PIPESTATUS[0]} so the status
# belongs to node and not to `cat`.
route_file() { # <prefix> [args...]
  local p="$1"; shift
  run_with_timeout 30 node "$N_TARGET" "$@" >"$p.out" 2>"$p.err"
  echo $?
}

# The redirection order is load-bearing and easy to get wrong. The pipe is built
# first (stdout -> pipe), THEN `2>&1` aims stderr at that pipe, THEN `>"$p.out"`
# moves stdout to a regular file. Result: stderr is genuinely on a pipe -- which is
# the whole reason this route exists -- while stdout is really captured.
# An earlier version wrote `2>&1 >/dev/null`, which threw stdout away and left N2
# asserting that a file this function had just truncated was empty: a green row no
# matter what the target printed (review round 3, C6).
route_pipe() { # <prefix> [args...]
  local p="$1"; shift
  run_with_timeout 30 node "$N_TARGET" "$@" 2>&1 >"$p.out" | cat > "$p.err"
  echo "${PIPESTATUS[0]}"
}

# One route's worth of assertions. `label` names the route so a half-broken
# diagnostic says which half.
assert_route() { # <label> <prefix> <rc>
  local label="$1" p="$2" rc="$3" lines bytes diag=""
  check "N1[$GUARD_TARGET/$label]: node exits $GUARD_EXIT_CODE (not the SyntaxError's 1)" \
    "$GUARD_EXIT_CODE" "$rc"
  bytes="$(wc -c < "$p.out" | tr -d ' ')"
  check "N2[$GUARD_TARGET/$label]: stdout is empty, so a \$( ) caller cannot capture a value" \
    "0" "$bytes"
  lines="$(wc -l < "$p.err" | tr -d ' ')"
  check "N3a[$GUARD_TARGET/$label]: stderr is exactly one line (no stack trace)" "1" "$lines"

  # N3b/N3c read THE diagnostic line, not "somewhere in stderr". A node
  # SyntaxError dump already contains the file path and echoes the shebang, so a
  # whole-stderr grep would report both as green while the guard is still absent.
  [ "$lines" = "1" ] && diag="$(cat "$p.err")"
  if [ -z "$diag" ]; then
    fail "N3b[$GUARD_TARGET/$label]: stderr is not a single-line diagnostic ($lines lines) -- the guard envelope is not inserted yet, so there is no line to judge"
    fail "N3c[$GUARD_TARGET/$label]: stderr is not a single-line diagnostic ($lines lines) -- the guard envelope is not inserted yet, so there is no line to judge"
  else
    # Exact match, not a substring: the wording is a user-facing contract, and a
    # partial match cannot distinguish the sentence from a stack trace that
    # happens to mention the path (review-tests C3).
    check "N3b[$GUARD_TARGET/$label]: the diagnostic is exactly the envelope's sentence" \
      "$N_WANT_DIAG" "$diag"
    case "$diag" in
      *"bash $N_ARGV1"*)
        pass "N3c[$GUARD_TARGET/$label]: the diagnostic spells out the corrected command line" ;;
      *)
        fail "N3c[$GUARD_TARGET/$label]: the diagnostic does not spell out \`bash $N_ARGV1\` -- got [$diag]" ;;
    esac
  fi
  if grep -qF -- "SyntaxError" "$p.err"; then
    fail "N3d[$GUARD_TARGET/$label]: stderr still carries a SyntaxError -- the guard envelope is not inserted, so node parsed the bash body as JavaScript"
  else
    pass "N3d[$GUARD_TARGET/$label]: stderr carries no SyntaxError"
  fi
}

n_run_pair() { # <case-label> [args...]
  local case_label="$1"; shift
  local pf="$N_TMP/f-$case_label" pp="$N_TMP/p-$case_label" rcf rcp
  rcf="$(route_file "$pf" "$@")"
  rcp="$(route_pipe "$pp" "$@")"
  assert_route "$case_label/file" "$pf" "$rcf"
  assert_route "$case_label/pipe" "$pp" "$rcp"
  # N5 — the same bytes on both routes.
  if cmp -s "$pf.err" "$pp.err"; then
    pass "N5[$GUARD_TARGET/$case_label]: the regular-file and pipe stderr are byte-identical (regression pin for the fs.writeSync design)"
  else
    fail "N5[$GUARD_TARGET/$case_label]: the regular-file and pipe stderr differ -- an asynchronous stderr write is losing the diagnostic on the pipe route"
  fi
  # N4 — argument independence, measured against the no-argument reference.
  if [ -z "$N_REF_ERR" ]; then
    N_REF_ERR="$pf.err"
  elif cmp -s "$pf.err" "$N_REF_ERR"; then
    pass "N4[$GUARD_TARGET/$case_label]: stderr is byte-identical to the no-argument case"
  else
    fail "N4[$GUARD_TARGET/$case_label]: stderr differs from the no-argument case -- the guard is reading argv beyond argv[1], so a caller's arguments can steer the diagnostic"
  fi
}

# N4-secret — the guard must not echo what it was handed. A misinvoked command
# line can carry a token or a password in $2, and a diagnostic that quoted its
# arguments would copy it into whatever log captured stderr.
n_secret_case() {
  local sentinel="SEKRIT-DO-NOT-ECHO-$$-$RANDOM" hits
  n_run_pair secret "$sentinel"
  hits="$(cat "$N_TMP/f-secret.out" "$N_TMP/f-secret.err" "$N_TMP/p-secret.err" 2>/dev/null | grep -cF -- "$sentinel" || true)"
  check "N4s[$GUARD_TARGET]: the argument sentinel appears nowhere in stdout or stderr" "0" "$hits"
}

n_main() {
  local longarg
  require_node "N1-N6[$GUARD_TARGET]" || return 0
  n_resolve_argv1 || return 0
  # The no-argument case first: it is the reference every other case is compared to.
  n_run_pair noargs
  # An argument must not change any of it, across the shapes that would break a
  # naive implementation: a positional value, an empty string, a very long value,
  # and one made only of shell/regex metacharacters.
  n_run_pair witharg SOME_ARG
  n_run_pair emptyarg ""
  # "very long" is the whole point of this row, and its length is produced by `seq`,
  # whose output depends on the coreutils build and on the locale. Assert the length
  # rather than trust it: a `seq` that emitted nothing would turn this into a second,
  # silently redundant empty-argument case.
  longarg="$(printf 'a%.0s' $(seq 1 4000))"
  check "N5len[$GUARD_TARGET]: the long-argument case is exactly 4000 characters" "4000" "${#longarg}"
  n_run_pair longarg "$longarg"
  n_run_pair metaarg '$(echo pwned) `id` ;|&<>*?"'"'"'\'
  n_secret_case
  n6_early_close
  n7_no_side_effects
  n8_idempotent
}

# ---- N6: the reader hangs up before the diagnostic is written ---------------
# `head -c 0` closes the pipe immediately, so the write fails with EPIPE. The
# contract is "the diagnostic is best-effort, the exit code is not": give up on
# the message, still exit 70, and never hang. The earlier design
# (catch -> process.stderr.write -> process.exit(70)) exits 1 here, so this row is
# the direct pin for the current one.
n6_early_close() {
  local rc
  run_with_timeout 30 bash -c 'node "$1" 2>&1 >/dev/null | head -c 0; exit ${PIPESTATUS[0]}' _ "$N_TARGET"
  rc=$?
  check "N6[$GUARD_TARGET]: an early-closed stderr pipe still exits $GUARD_EXIT_CODE without hanging" \
    "$GUARD_EXIT_CODE" "$rc"
}

# ---- the OTHER write-error branch lives in eagain-retry.sh ------------------
# N6 covers the give-up branch (EPIPE). The `err.code === "EAGAIN"` retry branch was
# recorded here as a TL3 gap on the grounds that a real non-blocking fd 2 is a race and is
# unreachable on Windows. That framing was wrong about the ONLY way to reach the branch:
# the E group in eagain-retry.sh forces it deterministically and portably by replacing
# fs.writeSync through a `node --require` preload. No gap remains (review round 6, C3).

# ---- N7: a metacharacter payload must not DO anything (review round 3, C1) ---
# n_run_pair metaarg proves the diagnostic does not CHANGE under metacharacters --
# a statement about the message, not the machine. These rows assert the other half,
# that nothing happened, via payloads whose only observable effect would be a marker
# file in a temp directory.
n7_no_side_effects() {
  local dir="$N_TMP/side-effects"
  rm -rf "$dir"; mkdir -p "$dir/node" "$dir/bash"
  # Detection control: if `touch` cannot create a file here at all (read-only
  # TMPDIR, hostile umask), "no marker exists" is true for a reason unrelated to
  # the guard and the rows below would be green while proving nothing.
  touch "$dir/control" 2>/dev/null
  if [ -f "$dir/control" ]; then
    pass "N7ctl[$GUARD_TARGET]: the marker directory can hold a marker file, so an absent marker is evidence"
  else
    fail "N7ctl[$GUARD_TARGET]: a marker file cannot be created in $dir -- the N7 rows below cannot distinguish 'nothing ran' from 'nothing could run'"
    return 0
  fi
  rm -f "$dir/control"
  n7_route node "$dir/node" || return 0
  n7_route bash "$dir/bash"
}

# n7_route — every payload through one interpreter, then count markers.
# Harness hygiene: each payload is a single-quoted literal with only the temp
# directory spliced in from a double-quoted variable, and reaches the target as ONE
# argv element. Nothing here evals a payload or concatenates one into a `bash -c`
# string, so a marker that appears was created by the code under test.
n7_route() { # <interpreter> <marker-dir>
  local interp="$1" mdir="$2" payload found
  if [ "$interp" = "node" ]; then
    require_node "N7[$GUARD_TARGET]" || return 1
  fi
  for payload in \
    '; touch '"$mdir"'/semicolon' \
    '$(touch '"$mdir"'/cmdsub)' \
    '`touch '"$mdir"'/backtick`' \
    '&& touch '"$mdir"'/andand' \
    '| touch '"$mdir"'/pipefile' \
    '> '"$mdir"'/redirect' \
    '; rm -rf '"$mdir"'; touch '"$mdir"'/rmthenmark'
  do
    run_with_timeout 30 "$interp" "$N_TARGET" "$payload" </dev/null >/dev/null 2>&1
  done
  # `find` rather than a per-name test: a payload that landed under a name this
  # loop did not predict is still a side effect and must still be reported.
  found="$(find "$mdir" -mindepth 1 2>/dev/null | tr '\n' ' ')"
  check "N7[$GUARD_TARGET/$interp]: a metacharacter payload creates no file in the marker directory" "" "${found% }"
  # The last payload tries to delete the directory itself, so its survival is part
  # of the contract -- an absent directory would make the count above vacuous.
  if [ -d "$mdir" ]; then
    pass "N7d[$GUARD_TARGET/$interp]: the marker directory itself still exists (the rm payload did not run either)"
  else
    fail "N7d[$GUARD_TARGET/$interp]: the marker directory was deleted -- an \`rm -rf\` payload was executed"
  fi
  return 0
}

# ---- N8: the same misinvocation twice is the same event (review round 3, C7) -
# A guard that memoised, appended to a log, rewrote its own file or degraded on a
# second run would still pass every single-shot row above.
n8_idempotent() {
  local a="$N_TMP/idem-a" b="$N_TMP/idem-b" before="$N_TMP/idem-before" rc1 rc2
  require_node "N8[$GUARD_TARGET]" || return 0
  cp "$N_TARGET" "$before" || { fail "N8[$GUARD_TARGET]: could not snapshot $N_TARGET before the run"; return 0; }
  rc1="$(route_file "$a" IDEMPOTENCE_PROBE)"
  rc2="$(route_file "$b" IDEMPOTENCE_PROBE)"
  check "N8rc[$GUARD_TARGET]: the second misinvocation exits with the same code as the first" "$rc1" "$rc2"
  if cmp -s "$a.err" "$b.err"; then
    pass "N8err[$GUARD_TARGET]: the two runs' stderr is byte-identical"
  else
    fail "N8err[$GUARD_TARGET]: the two runs' stderr differs -- the diagnostic is not a pure function of the invocation"
  fi
  if cmp -s "$a.out" "$b.out"; then
    pass "N8out[$GUARD_TARGET]: the two runs' stdout is byte-identical"
  else
    fail "N8out[$GUARD_TARGET]: the two runs' stdout differs -- the guard is emitting something that varies between runs"
  fi
  if cmp -s "$before" "$N_TARGET"; then
    pass "N8file[$GUARD_TARGET]: bin/$GUARD_TARGET is byte-identical before and after being misinvoked"
  else
    fail "N8file[$GUARD_TARGET]: bin/$GUARD_TARGET changed on disk after a node misinvocation -- the guard is writing to its own file"
  fi
}

n_main

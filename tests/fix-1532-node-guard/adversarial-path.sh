# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, node-misinvocation, diagnostics, adversarial-path, scope:issue-specific, pwsh-not-required, TL2

# X1-X8: the same node misinvocation node-diagnostic.sh describes, but from a
# directory whose NAME is hostile. N3 only ever sees the repository's own benign
# path, so it cannot tell a diagnostic that reproduces its input faithfully from one
# that mangles, truncates or re-interprets it (review round 5, C2). Split out of
# node-diagnostic.sh rather than appended to it because that file already sits at
# the >300-line WARN threshold in skills/_shared/test-design.md.

# WHY THE RELATIVE FORM IS THE PRIMARY ROUTE. The guard reads process.argv[1], and
# what lands there is decided by the shell/argv transport, not by the guard. On Git
# Bash the MSYS layer rewrites POSIX paths on the way into a native node.exe and
# treats `;` as a Windows path-list separator, so `node /tmp/has;semi/x` arrives
# mangled and node dies with MODULE_NOT_FOUND before a single guard byte runs -- an
# environment artefact that says nothing about the guard.

# Invoking as `cd <dir> && node ./<name>` keeps the argument relative, which no
# transport rewrites, and node still resolves it to the full adversarial path. X5
# additionally runs the absolute form wherever the transport can be PROVEN faithful.

echo "=== X: node misinvocation from an adversarial path for $GUARD_TARGET ==="

X_TMP="$TESTTMP/adversarial-path"
mkdir -p "$X_TMP"
X_ABS_RAN=0

# The directory names under test. A quoted here-document, so every character below
# reaches `read` exactly as written.
x_case_dirs() {
  cat <<'X_DIRS'
space|has space
dollar|has$dollar
semicolon|has;semi
ampersand|has&amp
quote|has'quote
combo|s p$a;c&e'q
X_DIRS
}

# Did the filesystem keep the name it was given? A platform that silently rewrites
# or splits the character under test leaves a directory that is not the one the row
# claims to be testing, and every assertion below would describe a benign path.
x_name_exists() { # <name>
  find "$X_TMP" -mindepth 1 -maxdepth 1 2>/dev/null | grep -qxF -- "$X_TMP/$1"
}

# X5 — the absolute form, run only where the transport is proven faithful. The probe
# asks node itself what it received; if that is not the path the relative form
# already established, the disagreement is the shell's, so the row is recorded as a
# platform fact instead of being reported as a guard failure or quietly dropped.
x_abs_route() { # <label> <dir> <expected-argv1>
  local label="$1" dir="$2" want="$3" probe rc bytes
  probe="$(node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "$dir/$GUARD_TARGET" 2>/dev/null)"
  if [ "$probe" != "$want" ]; then
    skip "X5[$GUARD_TARGET/$label]: the ABSOLUTE-path form is not exercisable on this host -- the shell/argv transport handed node [$probe] instead of [$want], so node never reaches the guard. The X1-X4 rows above carry the assertion for this path."
    return 0
  fi
  run_with_timeout 30 node "$dir/$GUARD_TARGET" >"$X_TMP/a.out" 2>"$X_TMP/a.err"
  rc=$?
  bytes="$(wc -c < "$X_TMP/a.out" | tr -d ' ')"
  check "X5rc[$GUARD_TARGET/$label]: the absolute-path form also exits $GUARD_EXIT_CODE" "$GUARD_EXIT_CODE" "$rc"
  check "X5out[$GUARD_TARGET/$label]: the absolute-path form also writes 0 bytes to stdout" "0" "$bytes"
  X_ABS_RAN=$((X_ABS_RAN + 1))
}

# ---- X4v/X4q: the path is emitted VERBATIM and UNQUOTED ---------------------
# PIN OF CURRENT BEHAVIOUR, NOT AN ENDORSEMENT. The guard concatenates
# process.argv[1] into the remediation text with no shell quoting whatsoever, so for
# a path holding a space or a metacharacter the printed `bash <path> [args...]` is
# NOT a copy-pasteable command line. Shell-quoting it is a recorded, accepted
# follow-up, deliberately OUT OF SCOPE for this PR, so nothing here asserts that the
# emitted text is runnable.

# WHY THE FOLLOW-UP MATTERS, in the framing review round 6 gave it: the unquoted path is
# not merely cosmetic. A checkout under a directory whose name contains `$(...)` or
# backticks produces a remediation line that PERFORMS SUBSTITUTION the moment a user pastes
# it into a shell -- the guard prints a command it invites the reader to run, and that
# command executes whatever the directory name spelled. The X-group directory fixtures
# above already build exactly such names, so the input is not hypothetical. Closing it is a
# source change in the five frozen bin/ scripts and is out of scope here; this note exists
# so the future fixer reads the risk, not just the pin.

# What IS asserted is today's contract: the exact bytes of the path appear, with no
# quotes, no backslash escapes and no $'...' wrapper around them. A FUTURE FIXER
# MUST UPDATE THESE TWO ROWS DELIBERATELY -- when the quoting follow-up lands they
# go red on purpose and the new expectation replaces them. Do not pre-emptively
# rewrite them into the aspirational form; that would be red today.
x_verbatim_rows() { # <label> <argv1> <diag>
  local label="$1" argv1="$2" diag="$3"
  case "$diag" in
    *"bash $argv1 [args...]"*)
      pass "X4v[$GUARD_TARGET/$label]: the remediation carries the path verbatim (pinned: argv[1] is NOT shell-quoted -- known follow-up)" ;;
    *)
      fail "X4v[$GUARD_TARGET/$label]: the remediation no longer carries \`bash $argv1 [args...]\` verbatim -- got [$diag]; if argv[1] is now shell-quoted, update this pin deliberately rather than deleting it" ;;
  esac
  case "$diag" in
    *"bash '"* | *'bash "'* | *"bash \$'"*)
      fail "X4q[$GUARD_TARGET/$label]: the remediation now wraps the path in shell quoting -- the pinned behaviour for this PR is unquoted; update X4v/X4q together when the quoting follow-up lands" ;;
    *)
      pass "X4q[$GUARD_TARGET/$label]: the remediation adds no shell quoting around the path (pinned current behaviour)" ;;
  esac
}

# One adversarial directory, end to end.
x_one() { # <label> <dirname>
  local label="$1" dname="$2" dir="$X_TMP/$2" argv1 rc bytes lines diag want
  cp "$(target_path "$GUARD_TARGET")" "$dir/$GUARD_TARGET" 2>/dev/null || {
    fail "X0[$GUARD_TARGET/$label]: could not copy the target into <$dname>, so this path is untested"
    return 0
  }
  argv1="$( cd "$dir" && node -e 'process.stdout.write(require("path").resolve(process.argv[1]))' "./$GUARD_TARGET" 2>/dev/null )"
  case "$argv1" in
    *"$GUARD_TARGET")
      pass "X0[$GUARD_TARGET/$label]: node resolves the relative entry point under <$dname> ($argv1)" ;;
    *)
      fail "X0[$GUARD_TARGET/$label]: node did not resolve the entry point under <$dname> -- got [$argv1], so the exact-match rows below have no expected value"
      return 0 ;;
  esac
  ( cd "$dir" && run_with_timeout 30 node "./$GUARD_TARGET" ) >"$X_TMP/x.out" 2>"$X_TMP/x.err"
  rc=$?
  check "X1[$GUARD_TARGET/$label]: node exits $GUARD_EXIT_CODE from a path holding <$dname>" "$GUARD_EXIT_CODE" "$rc"
  bytes="$(wc -c < "$X_TMP/x.out" | tr -d ' ')"
  check "X2[$GUARD_TARGET/$label]: stdout is still 0 bytes from a path holding <$dname>" "0" "$bytes"
  lines="$(wc -l < "$X_TMP/x.err" | tr -d ' ')"
  check "X3[$GUARD_TARGET/$label]: stderr is still exactly one line (no stack trace)" "1" "$lines"
  if [ "$lines" != "1" ]; then
    fail "X4[$GUARD_TARGET/$label]: stderr is not a single-line diagnostic ($lines lines), so there is no line to judge"
    x_abs_route "$label" "$dir" "$argv1"
    return 0
  fi
  diag="$(cat "$X_TMP/x.err")"
  want="$(expected_diagnostic "$argv1")"
  check "X4[$GUARD_TARGET/$label]: the diagnostic is exactly the envelope's sentence for this path" "$want" "$diag"
  x_verbatim_rows "$label" "$argv1" "$diag"
  if grep -qF -- "SyntaxError" "$X_TMP/x.err"; then
    fail "X4s[$GUARD_TARGET/$label]: stderr carries a SyntaxError -- node parsed the bash body as JavaScript under this path"
  else
    pass "X4s[$GUARD_TARGET/$label]: stderr carries no SyntaxError under this path"
  fi
  x_abs_route "$label" "$dir" "$argv1"
}

# X6 — the backslash variant, where the platform allows one in a name. Windows uses
# `\` as the path separator, so `mkdir "a\b"` there creates a nested `a/b` and no
# directory named `a\b` ever exists. That is a platform fact detected at run time,
# not an assertion being softened: on POSIX the row runs for real.
x_backslash_case() {
  local dname='back\slash'
  mkdir -p "$X_TMP/$dname" 2>/dev/null
  if x_name_exists "$dname"; then
    x_one backslash "$dname"
  else
    skip "X6[$GUARD_TARGET]: a literal backslash cannot appear in a directory name on this platform (it is the path separator, and mkdir created a nested directory instead) -- the backslash variant is not applicable here"
  fi
}

x_main() {
  local label dname ran=0
  require_node "X1-X8[$GUARD_TARGET]" || return 0
  while IFS='|' read -r label dname; do
    [ -n "$label" ] || continue
    if ! mkdir -p "$X_TMP/$dname" 2>/dev/null || ! x_name_exists "$dname"; then
      fail "X0[$GUARD_TARGET/$label]: the directory name <$dname> could not be created verbatim on this filesystem -- the row would be testing a different path than it claims"
      continue
    fi
    x_one "$label" "$dname"
    ran=$((ran + 1))
  done <<EOF
$(x_case_dirs)
EOF
  # Non-vacuity of the loop itself: a here-document that delivered nothing would
  # print no rows at all and the group would still report green.
  if [ "$ran" -ge 5 ]; then
    pass "X7[$GUARD_TARGET]: $ran adversarial directory names were exercised"
  else
    fail "X7[$GUARD_TARGET]: only $ran adversarial directory names were exercised (expected at least 5) -- the case table is not reaching the loop"
  fi
  x_backslash_case
  # Same for X5: every absolute-form row being skipped would leave that route
  # unproven while looking tidy. The space/$/& names transport faithfully on every
  # host this suite runs on, so at least one must have run.
  if [ "$X_ABS_RAN" -ge 1 ]; then
    pass "X8[$GUARD_TARGET]: the absolute-path form was genuinely exercised on $X_ABS_RAN of the adversarial paths"
  else
    fail "X8[$GUARD_TARGET]: every absolute-path row was recorded as not exercisable -- the X5 route is proving nothing on this host"
  fi
}

x_main

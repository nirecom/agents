# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, node-misinvocation, invariance, scope:issue-specific, pwsh-not-required, TL2

# Shared setup for the #1532 node-misinvocation guard suite: target list, envelope
# literals, counters, helpers, and fixture isolation. Sourced first by dispatch.sh.

# TL3 gap (what this suite does NOT catch):
# - Whether a diagnostic written with fs.writeSync survives on a platform whose
#   stderr pipe is asynchronous (macOS/Linux). Every route here runs on the host
#   that executes the suite, and this host's pipes are synchronous.
# - Whether ~/.local/bin shims (installed copies, not the bin/ originals) carry
#   the same envelope after an installer run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: installer.

# Also deliberately NOT covered (review round 2, C4): repo paths containing spaces,
# shell metacharacters or newlines. No test group under rules/, skills/ or hooks/
# carries that coverage either, and such a checkout is not a supported layout today;
# widening it here alone would be a lone special case rather than a repo-wide rule.
# Round 3, C4 is the same finding again and is deferred on the same grounds.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The five targets are hardcoded on purpose. bin/ holds ~96 bash-shebang scripts and
# the same misinvocation is possible in every one of them, but the accepted tradeoff
# recorded for #1532 scoped the envelope to five high-traffic entry points. A
# `find bin/` sweep here would silently widen that scope and turn 91 out-of-scope
# scripts red, which is a decision for a plan, not for a glob.
TARGETS="get-config-var confirm-off resolve-session-id resolve-worktree-path is-github-dotcom-remote"

# ---- envelope literals (SSOT for every shape assertion below) ---------------
# These must match the bytes inserted into bin/ exactly. G1 compares the five
# files against each other; these constants are what tie that comparison to an
# intended shape rather than to "whatever the five happen to agree on".
ENVELOPE_FIRST_LINE='":" //; : <<'\''AGENTS_NODE_GUARD'\'''
ENVELOPE_DELIMITER='AGENTS_NODE_GUARD'
ENVELOPE_TAIL_PREFIX='# End of the #1532 node-misinvocation guard envelope'
HEAD_LINES=12
TAIL_LINES=2
ENVELOPE_LINES=14
GUARD_EXIT_CODE=70

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}

# Portable timeout (macOS has no `timeout`) — rules/test/macos-timeout.md.
run_with_timeout() { # <seconds> <cmd> [args...]
  bash "$REPO_ROOT/bin/run-with-timeout.sh" "$@"
}

HAVE_NODE=0
command -v node >/dev/null 2>&1 && HAVE_NODE=1

# node absence is a MISSING PRECONDITION here, never a skip (review-tests C7): the
# whole subject of #1532 is what `node bin/<script>` does, so a run without node
# has not weakened the suite, it has failed to run it. `skip` would let a CI image
# that lost node report a green suite that checked nothing.
require_node() { # <row-id-prefix>
  [ "$HAVE_NODE" -eq 1 ] && return 0
  fail "$1: PRECONDITION -- node is not on PATH, and this suite exists to describe what node does with a bash script; install node or fix PATH"
  return 1
}

target_path() { printf '%s' "$REPO_ROOT/bin/$1"; }

# The one place the guard's diagnostic wording lives on the test side. Built from
# the envelope's confirmed literal so an exact-match assertion is possible: a
# substring match cannot tell the intended sentence from a node stack trace that
# merely happens to contain the path and the word bash (review-tests C3).
expected_diagnostic() { # <script-path>
  printf '%s: this is a bash script, not a Node program. Re-run it as: bash %s [args...]' "$1" "$1"
}

# Has the envelope actually been inserted into <file>? Used to give the whole
# suite one honest diagnostic instead of a dozen mysterious ones while the
# production change is still pending, and to pick the body range for G3.
envelope_present() { # <file>
  local f="$1" n
  [ -f "$f" ] || return 1
  [ "$(sed -n '2p' "$f")" = "$ENVELOPE_FIRST_LINE" ] || return 1
  n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -gt "$ENVELOPE_LINES" ] || return 1
  sed -n "$((n - TAIL_LINES + 1))p" "$f" | grep -qF -- "$ENVELOPE_TAIL_PREFIX"
}

# The script body: everything the bash interpreter actually runs apart from the
# shebang, with the envelope removed when it is there.
body_text() { # <file>
  local f="$1" n
  if envelope_present "$f"; then
    n="$(wc -l < "$f" | tr -d ' ')"
    sed -n "$((HEAD_LINES + 2)),$((n - TAIL_LINES))p" "$f"
  else
    sed -n '2,$p' "$f"
  fi
}

# ---- fixture isolation (rules/test/fixture-isolation.md) --------------------
# CLAUDE_WORKFLOW_DIR and WORKFLOW_PLANS_DIR are pinned as a PAIR: pinning only
# the first is the known contamination bug, where hooks read the fixture but the
# supervisor emitter still appends to the developer's real ~/.workflow-plans.
# resolve-session-id / resolve-worktree-path both reach workflow state, so the
# inherited session ids go too — otherwise a test run mutates the live session.
TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/fix-1532-node-guard.XXXXXX")" || {
  echo "FATAL: mktemp -d failed" >&2
  exit 2
}
trap 'cd / 2>/dev/null; rm -rf "$TESTTMP"' EXIT
export CLAUDE_WORKFLOW_DIR="$TESTTMP/workflow"
export WORKFLOW_PLANS_DIR="$TESTTMP/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_ID

# Everything else the targets branch on, unset explicitly rather than assumed
# absent (review-tests C2). CLAUDE_ENV_FILE is priority 3 of resolveSessionId and
# CLAUDE_TRANSCRIPT_BASE_DIR feeds the transcript scan, so a developer shell that
# exports either turns "there is no session" into a claim about their machine.
# The GETCFG_/CONFIRM_ names are the keys the B cases assert as absent.
unset CLAUDE_ENV_FILE CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR
unset GETCFG_ABSENT_VAR GETCFG_T CONFIRM_T
unset FIX1532_ABS_KEY FIX1532_ABS_OFF FIX1532_ABS_ON FIX1532_ABS_ABSENT
unset FIX1532_DIRECT_KEY

cd "$TESTTMP" || exit 2

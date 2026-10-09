#!/usr/bin/env bash
# tests/skills/fix-quality-gates-not-found.sh
# Tests: skills/review-code-security/scripts/run-quality-gates.sh, skills/review-code-security/SKILL.md
# Tags: security-gate, quality-gates, review-code-security, false-green, ssot, drift-guard, scope:common, pwsh-not-required, TL2
# run-quality-gates.sh must report a gate it cannot run instead of skipping it silently. Parts:
#   gate-invocation G1-G4: full-path invocation, `## <name>: NOT FOUND` on stdout, advisory exits.
#   root-independence G5: no AGENTS_MAIN_ROOT value (unset, empty, relative, not a directory,
#     absent, or an existing absolute tree with a full gate set) changes which gates run.
#   merge-base-report G6, base-state-propagation G10/G11: the base every gate is scoped by.
#   gate-summary G7-G9: absent vs not executable, the totals line, the SKILL.md obligation.
# TL3 gap: real ~/.local/bin shims, real gate output, the skill acting on the report (G9).

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER_REL="skills/review-code-security/scripts/run-quality-gates.sh"
RUNNER="$SCRIPT_CHECKOUT_ROOT/$RUNNER_REL"
SKILL_REL="skills/review-code-security/SKILL.md"
SKILL_MD="$SCRIPT_CHECKOUT_ROOT/$SKILL_REL"
PARTS_DIR="$SCRIPT_CHECKOUT_ROOT/tests/skills/fix-quality-gates-not-found"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}
skip_case() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }
if [ ! -f "$RUNNER" ]; then
  echo "FAIL: $RUNNER_REL does not exist"
  echo ""
  echo "Total: 0 passed, 1 failed, 0 skipped"
  exit 1
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/quality-gates-not-found.XXXXXX")" || TMPROOT=""
if [ -z "$TMPROOT" ] || [ ! -d "$TMPROOT" ]; then
  echo "FAIL: could not create the test's temp root"
  echo ""
  echo "Total: 0 passed, 1 failed, 0 skipped"
  exit 1
fi
readonly TMPROOT
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT
# Both pinned before anything runs: the merge-base helper reads the workflow state store,
# and the developer's live one must never be what a fixture run answers from.
mkdir -p "$TMPROOT/workflow-state" "$TMPROOT/workflow-plans"
export WORKFLOW_STATE_DIR="$TMPROOT/workflow-state" WORKFLOW_PLANS_DIR="$TMPROOT/workflow-plans"

# ---- derivation: which gates does the runner invoke? ------------------------
#
# The set is "files directly under bin/" intersected with "names on the runner's `_run_gate`
# lines", computed on a comment-stripped copy. Word boundaries exclude `-` and `.` so a name
# never matches inside a longer sibling name; a gate the parse misses is simply not asserted
# about. Only `_run_gate` lines are searched because the runner also calls bin/ helpers that
# are not gates (merge-base resolution): a whole-file search would count them in GATE_COUNT.
STRIPPED="$TMPROOT/runner.stripped"
sed 's/^[[:space:]]*#.*//' "$RUNNER" > "$STRIPPED"
GATELINES="$TMPROOT/runner.gatelines"
grep -E '^[[:space:]]*_run_gate[[:space:]]' "$STRIPPED" > "$GATELINES" || true

bin_basenames() { find "$SCRIPT_CHECKOUT_ROOT/bin" -maxdepth 1 -type f 2>/dev/null | sed 's#.*/##' | sort; }

derive_gates() {
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if grep -qE "(^|[^A-Za-z0-9._-])${b}([^A-Za-z0-9._-]|\$)" "$GATELINES"; then
      printf '%s\n' "$b"
    fi
  done <<< "$(bin_basenames)"
}

# Every line that drives a gate. The `--base "$MERGE_BASE"` argument is what every gate
# invocation in this script carries and what nothing else in it carries, so counting these
# lines counts invocations without naming a single gate.
invocation_lines() { grep -nF -- '--base "$MERGE_BASE"' "$STRIPPED" || true; }

GATES="$(derive_gates)"
GATE_COUNT="$(printf '%s\n' "$GATES" | grep -c . || true)"
INVOCATIONS="$(invocation_lines)"
INVOCATION_COUNT="$(printf '%s\n' "$INVOCATIONS" | grep -c . || true)"

# ---- fixtures ---------------------------------------------------------------

# A stub prints a line no real gate prints, so "this gate ran" is provable rather than
# inferred, and exits with the code it is told to.
write_stub() { # <bin-dir> <name> <exit-code>
  write_stub_noexec "$1" "$2" "$3"
  chmod +x "$1/$2" 2>/dev/null || true
}

# The same stub with the execute bit deliberately CLEARED. `install/win/dotfileslink.ps1`
# writes shims that read `exec bash "<agents>/bin/<command>" "$@"`, which never depended on
# the bit, and `rules/coding.md` mandates `git update-index --chmod=+x` precisely because a
# checkout can arrive without it. A gate in this state exists and runs.
write_stub_noexec() { # <bin-dir> <name> <exit-code>
  cat > "$1/$2" <<STUB
#!/usr/bin/env bash
echo "## STUB $2: PERFORMED"
exit $3
STUB
  chmod -x "$1/$2" 2>/dev/null || true
}

# A git repository with no remote, so _resolve_merge_base settles in milliseconds:
# `git fetch origin main` fails (no such remote), `git merge-base main HEAD` answers.
make_repo() { # ; prints the repo path
  make_repo_on_branch main
}

# The same repository with NO branch named main, so both merge-base attempts miss and the
# HEAD~1 fallback is the only remaining answer.
make_repo_no_main() { make_repo_on_branch work; }

# TWO commits, always: with one, `HEAD~1` — the fallback base handed to every gate when
# merge-base misses — is unresolvable, and a stub that ignores --base cannot notice, so
# G6e/G6f could not assert the base is real.
#
# core.hooksPath is overridden repo-locally: a developer's GLOBAL setting reaches a throwaway
# repo too, the agents pre-commit hook would refuse the fixture's commits silently, and every
# run would quietly take the HEAD~1 path. The override makes the fixture host-independent.
make_repo_on_branch() { # <branch> ; prints the repo path
  local r
  r="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  git -C "$r" init -q -b "$1" >/dev/null 2>&1
  git -C "$r" config core.hooksPath "$r/.git/no-such-hooks" >/dev/null 2>&1
  : > "$r/seed.txt"
  git -C "$r" add seed.txt >/dev/null 2>&1
  git -C "$r" -c user.email=test@example.com -c user.name=test \
    commit -q -m seed >/dev/null 2>&1
  printf 'second\n' > "$r/second.txt"
  git -C "$r" add second.txt >/dev/null 2>&1
  git -C "$r" -c user.email=test@example.com -c user.name=test \
    commit -q -m second >/dev/null 2>&1
  printf '%s' "$r"
}

# PATH stripped down to the system directories that hold git, node, and the shell.
# ~/.local/bin is deliberately absent: under this PATH a bare-name invocation CANNOT
# resolve, which is what makes the pre-fix behaviour observable and what keeps the
# billed review-code-codex unreachable even if a fixture forgot to stub it. node's
# directory is included (not broad) because some fixtures install `#!/usr/bin/env node`
# bridge scripts that must remain executable under this restricted PATH.
system_path() {
  local git_dir node_dir=""
  git_dir="$(dirname "$(command -v git)")"
  if command -v node >/dev/null 2>&1; then
    node_dir="$(dirname "$(command -v node)")"
    if [ "$node_dir" = "$git_dir" ]; then
      node_dir=""
    fi
  fi
  if [ -n "$node_dir" ]; then
    printf '%s:%s:/usr/bin:/bin' "$git_dir" "$node_dir"
  else
    printf '%s:/usr/bin:/bin' "$git_dir"
  fi
}

# Runs a copy of the real script from inside a fake checkout: the runner finds its gates
# from its own path, so the copy is what makes the fixture's stubs the ones it reaches.
# Sets RQG_RC / RQG_OUT (stdout only — `command not found` goes to stderr, and the whole
# point is what reaches the REPORT).
run_runner() { # <fake-checkout> <repo> [VAR=VAL...]
  local cfg="$1" repo="$2"
  shift 2
  run_runner_cfg "inherit" "" "$cfg" "$repo" "$@"
}

# The same invocation with control over what $AGENTS_MAIN_ROOT holds when the script runs:
# `set` exports the given value, `unset` removes the variable, `inherit` leaves it alone.
#
# Trailing VAR=VAL arguments are added to the child environment. The merge-base rows need
# them: the anomaly thresholds are read from the environment, and injecting a small one is
# the only way to drive a fixture into SUSPECT without building a repository with a genuinely
# enormous diff in it.
run_runner_cfg() { # <set|unset|inherit> <agents-root-value> <fake-checkout> <repo> [VAR=VAL...]
  local mode="$1" value="$2" cfg="$3" repo="$4" copy
  shift 4
  copy="$cfg/$RUNNER_REL"
  mkdir -p "$(dirname "$copy")"
  cp "$RUNNER" "$copy"
  RQG_RC=0
  case "$mode" in
    unset)
      RQG_OUT="$(cd "$repo" && env -u AGENTS_MAIN_ROOT "PATH=$(system_path)" ${1+"$@"} \
        "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 120 bash "$copy" 2>/dev/null)" || RQG_RC=$? ;;
    set)
      RQG_OUT="$(cd "$repo" && env "AGENTS_MAIN_ROOT=$value" "PATH=$(system_path)" ${1+"$@"} \
        "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 120 bash "$copy" 2>/dev/null)" || RQG_RC=$? ;;
    *)
      RQG_OUT="$(cd "$repo" && env "PATH=$(system_path)" ${1+"$@"} \
        "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 120 bash "$copy" 2>/dev/null)" || RQG_RC=$? ;;
  esac
}

# Can this host actually run a script it just chmod'ed? On a filesystem that ignores the
# execute bit the "present" half of G3 would report absent and assert nothing, so the
# integration rows are skipped with a reason rather than reporting a false colour.
exec_bit_works() {
  local d
  d="$(mktemp -d "$TMPROOT/probe.XXXXXX")"
  write_stub "$d" "probe-gate" 0
  [ -x "$d/probe-gate" ] || return 1
  "$d/probe-gate" >/dev/null 2>&1 || return 1
  return 0
}

# The complement of exec_bit_works, and a strictly stronger condition: G7's "present but not
# executable" case only EXISTS on a host where clearing the bit is observable at all. Where
# `chmod -x` is a no-op the file stays -x and the row would be asserting the ordinary
# present-gate path under a misleading name.
no_exec_bit_observable() {
  local d
  d="$(mktemp -d "$TMPROOT/probe.XXXXXX")"
  write_stub_noexec "$d" "probe-noexec" 0
  [ -f "$d/probe-noexec" ] || return 1
  [ ! -x "$d/probe-noexec" ] || return 1
  return 0
}

# The same shape of probe for READ permission, and for the same reason: under Git Bash on
# Windows, on a mount with no POSIX permissions, and for root everywhere, `chmod a-r` is
# advisory and the file stays readable. The unreadable-gate rows would then be asserting the
# ordinary present-gate path under a misleading name, so they are skipped with a reason.
# Both halves are probed — the permission bit AND an actual read — because only the second
# one is what the runner will hit.
no_read_observable() {
  local d
  d="$(mktemp -d "$TMPROOT/probe.XXXXXX")"
  write_stub "$d" "probe-noread" 0
  chmod a-r "$d/probe-noread" 2>/dev/null || return 1
  [ ! -r "$d/probe-noread" ] || return 1
  cat "$d/probe-noread" >/dev/null 2>&1 && return 1
  return 0
}

# The merge-base resolver is NOT a gate — it is the helper the runner consults before any
# gate runs, so it is copied in REAL rather than stubbed. A stub would make every G6 row
# assert against the test's own idea of the answer instead of against the resolver, which is
# the one thing G6 exists to check. It lives under the checkout's bin/ like everything
# else the runner calls, so the fake checkout has to carry it.
#
# Its absence is itself a case (G6n), so this is a copy-if-present, not a hard requirement:
# a agents root built before the helper exists simply does not have it, which is exactly the
# input the degradation row wants.
install_merge_base_helper() { # <cfg-bin-dir>
  [ -f "$SCRIPT_CHECKOUT_ROOT/bin/resolve-merge-base.sh" ] || return 0
  cp "$SCRIPT_CHECKOUT_ROOT/bin/resolve-merge-base.sh" "$1/resolve-merge-base.sh"
  chmod +x "$1/resolve-merge-base.sh" 2>/dev/null || true
}

# A agents root with a stub for every derived gate, at the requested exec-bit setting.
make_full_cfg() { # <exec|noexec> ; prints the agents root
  local cfg g
  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  mkdir -p "$cfg/bin" "$cfg/rules"
  : > "$cfg/rules/core-principles.md"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if [ "$1" = "noexec" ]; then write_stub_noexec "$cfg/bin" "$g" 0
    else write_stub "$cfg/bin" "$g" 0; fi
  done <<< "$GATES"
  install_merge_base_helper "$cfg/bin"
  printf '%s' "$cfg"
}

# The gates are split by parse order, not by name, so the row keeps working when the gate
# list changes. review-code-codex is forced into the PRESENT half in every case: it is the
# billed one, and a stub standing in its place is the only acceptable outcome.
split_gates() { # sets PRESENT / ABSENT
  local g i=0
  PRESENT=""
  ABSENT=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if [ "$g" = "review-code-codex" ] || [ $((i % 2)) -eq 0 ]; then
      PRESENT="$PRESENT $g"
    else
      ABSENT="$ABSENT $g"
    fi
    i=$((i + 1))
  done <<< "$GATES"
  PRESENT="${PRESENT# }"
  ABSENT="${ABSENT# }"
}

# The last line of the runner's stdout — the only position a summary can occupy and still be
# the thing a reader's eye lands on after eight blocks of gate output.
last_line() { printf '%s\n' "$RQG_OUT" | grep -v '^[[:space:]]*$' | tail -1; }

# SKIPPED: running the runner with the developer's real ~/.local/bin on PATH.
# Because: review-code-codex would then resolve to the real, billed, network-calling gate.
#          Every row here reduces PATH to the system directories for exactly that reason.
# TL3 gap: whether the shims a real install writes agree with the full paths the runner now
#          uses — owned by tests/install/install-path-exposed-commands.sh and, ultimately, by a real
#          install on a real machine.

# ---- parts ------------------------------------------------------------------

# shellcheck source=./fix-quality-gates-not-found/gate-invocation.sh
. "$PARTS_DIR/gate-invocation.sh"
# shellcheck source=./fix-quality-gates-not-found/root-independence.sh
. "$PARTS_DIR/root-independence.sh"
# shellcheck source=./fix-quality-gates-not-found/merge-base-report.sh
. "$PARTS_DIR/merge-base-report.sh"
# shellcheck source=./fix-quality-gates-not-found/base-state-propagation.sh
. "$PARTS_DIR/base-state-propagation.sh"
# shellcheck source=./fix-quality-gates-not-found/gate-summary.sh
. "$PARTS_DIR/gate-summary.sh"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"

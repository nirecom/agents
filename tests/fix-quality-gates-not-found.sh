#!/usr/bin/env bash
# tests/fix-quality-gates-not-found.sh
# Tests: skills/review-code-security/scripts/run-quality-gates.sh, skills/review-code-security/SKILL.md
# Tags: security-gate, quality-gates, review-code-security, false-green, ssot, drift-guard, scope:common, pwsh-not-required, TL2
#
# THE INCIDENT. run-quality-gates.sh invoked eight lint gates by BARE NAME and swallowed each
# one's exit status with `|| true`. `|| true` cannot tell exit 127 (`command not found`) from
# a gate's own advisory non-zero exit, so a gate with no PATH shim was skipped FOREVER while
# the security review still read as eight-of-eight — roughly four of the eight actually ran
# in the session that found this. Nothing on stdout said a gate did not exist, and `command
# not found` goes to stderr, where the summary never looks.
#
# THE CONTRACT UNDER TEST, and where each half is pinned:
#   gate-invocation.sh  G1/G2 — PATH INDEPENDENCE: every gate is invoked by full path under
#                       $AGENTS_CONFIG_DIR/bin, so whether a shim was installed leaves the
#                       answer. G3 — EXPLICIT ABSENCE: a missing gate puts `## <name>: NOT
#                       FOUND` on STDOUT, in the `## <name>: <verdict>` family the gates
#                       themselves print. G4 — a gate's OWN non-zero exit stays advisory.
#   config-dir-guard.sh G5 — the fix's own new failure mode: the full paths are built from
#                       $AGENTS_CONFIG_DIR, which the script never validated, so an unset or
#                       unusable value turned the whole run into an empty stdout and exit 1
#                       that the SKILL's advisory contract reads as a pass.
#   merge-base-report.sh G6 — the base every gate is scoped by, and the fact that degrading
#                       to HEAD~1 has to be visible in the REPORT, not only on stderr.
#   gate-summary.sh     G7 — "absent" and "present but not marked executable" are different
#                       facts and only one of them is NOT FOUND. G8 — the NOT FOUND lines are
#                       totalled on the last line. G9 — and somebody is obliged to read it.
#
# DRIFT GUARD, NOT A SECOND LIST. The gate names are PARSED out of the script; a hardcoded
# copy would be a third transcription of the fact install/path-exposed-commands.txt exists to
# de-duplicate, and would go stale exactly as the shim lists did.
# tests/install-path-exposed-commands.sh T1 derives its input the same way and owns the
# complementary half (is each gate on the PATH-exposure list); this file owns the runner.
#
# OUT OF SCOPE (follow-up issue, user-confirmed): the installer side — making a missing
# path-exposed-commands.txt fatal, and validating the charset of its entries.
#
# ISOLATION. The integration rows run the real script with PATH reduced to the system
# directories, so ~/.local/bin is unreachable and NO real gate can be invoked by bare name.
# review-code-codex is billed and hits the network; it is stubbed in every fixture and is
# never reachable under either invocation form.
#
# TL3 gap (what this test does NOT catch):
# - the real ~/.local/bin population, and PATH ordering against a same-named binary
#   elsewhere: only a real install on a real machine proves the shims and the full paths meet.
# - the gates' real output — every gate here is a stub, so the marker format is pinned
#   against a fixture rather than against eight real programs.
# - the review-code-security skill reading the runner's stdout and summarising it, which is
#   where a NOT FOUND line has to actually change what a reviewer sees. G9 pins the written
#   obligation; only a real skill invocation proves the model honours it.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_REL="skills/review-code-security/scripts/run-quality-gates.sh"
RUNNER="$AGENTS_DIR/$RUNNER_REL"
SKILL_REL="skills/review-code-security/SKILL.md"
SKILL_MD="$AGENTS_DIR/$SKILL_REL"
PARTS_DIR="$AGENTS_DIR/tests/fix-quality-gates-not-found"

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

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

# ---- derivation: which gates does the runner invoke? ------------------------
#
# The set is the intersection of "files directly under bin/" with "names the runner
# mentions", computed on a comment-stripped copy. Word boundaries exclude `-` and `.` so a
# name can never match inside a longer sibling name. Conservative in the safe direction: a
# gate the parse misses simply is not asserted about, so a false accusation is impossible.
STRIPPED="$TMPROOT/runner.stripped"
sed 's/^[[:space:]]*#.*//' "$RUNNER" > "$STRIPPED"

bin_basenames() { find "$AGENTS_DIR/bin" -maxdepth 1 -type f 2>/dev/null | sed 's#.*/##' | sort; }

derive_gates() {
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if grep -qE "(^|[^A-Za-z0-9._-])${b}([^A-Za-z0-9._-]|\$)" "$STRIPPED"; then
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

# TWO commits, always. One is enough for `git merge-base main HEAD` to answer, but it makes
# `HEAD~1` — the fallback base the script hands every gate when merge-base misses — an
# unresolvable revision. A fixture that cannot resolve the fallback tests the fallback
# against nothing: the gates would be scoped by a broken range and the rows would still be
# green, because a stub that ignores --base cannot notice. The second commit is what lets
# G6e/G6f assert the base is real.
#
# core.hooksPath is set GLOBALLY on a developer machine that uses this repo's own hooks, and
# a global setting reaches every repository including a throwaway one under /tmp. The agents
# pre-commit hook then refuses the fixture's commits, `git commit` fails silently under the
# redirects below, and the fixture ends up with NO commits at all — merge-base misses, every
# run takes the HEAD~1 path, and the Pattern 4 control that is supposed to prove a normal
# resolution is quietly asserting the fallback. The repo-local override is what makes the
# fixture independent of whoever runs the suite.
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

# PATH stripped down to the system directories that hold git and the shell. ~/.local/bin is
# deliberately absent: under this PATH a bare-name invocation CANNOT resolve, which is what
# makes the pre-fix behaviour observable and what keeps the billed review-code-codex
# unreachable even if a fixture forgot to stub it.
system_path() {
  printf '%s:/usr/bin:/bin' "$(dirname "$(command -v git)")"
}

# Runs the real script against a fake config dir. Sets RQG_RC / RQG_OUT (stdout only —
# `command not found` goes to stderr, and the whole point is what reaches the REPORT).
run_runner() { # <config-dir> <repo>
  run_runner_cfg "set" "$1" "$2"
}

# The same invocation with control over HOW $AGENTS_CONFIG_DIR reaches the script: `set`
# exports the given value, `unset` removes the variable entirely. The script runs under
# `set -u`, so the two are genuinely different inputs and only one of them is reachable
# through run_runner.
run_runner_cfg() { # <set|unset> <config-dir> <repo>
  local mode="$1" cfg="$2" repo="$3"
  RQG_RC=0
  if [ "$mode" = "unset" ]; then
    RQG_OUT="$(cd "$repo" && env -u AGENTS_CONFIG_DIR "PATH=$(system_path)" \
      "$AGENTS_DIR/bin/run-with-timeout.sh" 120 bash "$RUNNER" 2>/dev/null)" || RQG_RC=$?
  else
    RQG_OUT="$(cd "$repo" && AGENTS_CONFIG_DIR="$cfg" PATH="$(system_path)" \
      "$AGENTS_DIR/bin/run-with-timeout.sh" 120 bash "$RUNNER" 2>/dev/null)" || RQG_RC=$?
  fi
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

# A config dir with a stub for every derived gate, at the requested exec-bit setting.
make_full_cfg() { # <exec|noexec> ; prints the config dir
  local cfg g
  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  mkdir -p "$cfg/bin" "$cfg/rules"
  : > "$cfg/rules/core-principles.md"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if [ "$1" = "noexec" ]; then write_stub_noexec "$cfg/bin" "$g" 0
    else write_stub "$cfg/bin" "$g" 0; fi
  done <<< "$GATES"
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
#          uses — owned by tests/install-path-exposed-commands.sh and, ultimately, by a real
#          install on a real machine.

# ---- parts ------------------------------------------------------------------

# shellcheck source=./fix-quality-gates-not-found/gate-invocation.sh
. "$PARTS_DIR/gate-invocation.sh"
# shellcheck source=./fix-quality-gates-not-found/config-dir-guard.sh
. "$PARTS_DIR/config-dir-guard.sh"
# shellcheck source=./fix-quality-gates-not-found/merge-base-report.sh
. "$PARTS_DIR/merge-base-report.sh"
# shellcheck source=./fix-quality-gates-not-found/gate-summary.sh
. "$PARTS_DIR/gate-summary.sh"

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"

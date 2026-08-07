# Part of tests/fix-quality-gates-not-found.sh (sourced, not standalone).
# Tests: skills/review-code-security/scripts/run-quality-gates.sh
# Tags: security-gate, quality-gates, review-code-security, false-green, config-dir, scope:common, pwsh-not-required, TL2
#
# G5 — the failure mode the FIX introduced, and the worst-shaped one in this file.
#
# Moving from bare names to `${AGENTS_CONFIG_DIR}/bin/<gate>` made the run depend on a
# variable the script never validated, under `set -u`. With the variable unset the very
# first gate line dies with `AGENTS_CONFIG_DIR: unbound variable` on STDERR: stdout is
# completely empty, the exit code is 1, and ZERO gates ran. SKILL.md RCS-2 instructs the
# consumer that a non-zero exit from this script is advisory — "a warning, not a blocker" —
# so a run in which nothing whatsoever happened is read as a lint result worth shrugging at.
# The pre-fix bare-name form had no such path: it always ran, it just ran nothing useful.
# This is strictly worse than the incident, and it is invisible in the report.
#
# FIVE SPELLINGS, ONE VERDICT. Unset, empty, relative, not-a-directory, and an absolute path
# that does not exist are five different inputs and one class: the script cannot build a
# trustworthy full path from any of them. The relative one is not merely tidiness — the runner is invoked with the CWD set
# to the repository UNDER REVIEW, so a relative $AGENTS_CONFIG_DIR resolves inside the
# reviewed tree and the "gates" executed would be code supplied by whatever is being
# reviewed. The fixture builds exactly that tree, so a row that passed by accident (because
# nothing was there to run) cannot be mistaken for the guard working.
#
# WHAT IS OWED: `## gates: NOT RUN — <reason>` on STDOUT, in the same `## <name>: <verdict>`
# family as everything else the script prints, and exit 0 so the advisory contract is not
# quietly reinterpreted as "this run was fine".

# A repo carrying a config-dir-shaped subtree at a RELATIVE path, so `AGENTS_CONFIG_DIR=rel`
# would resolve — and execute the reviewed tree's own scripts.
make_repo_with_relative_cfg() { # ; prints the repo path (subtree at ./rel)
  local r g
  r="$(make_repo)"
  mkdir -p "$r/rel/bin" "$r/rel/rules"
  : > "$r/rel/rules/core-principles.md"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    write_stub "$r/rel/bin" "$g" 0
  done <<< "$GATES"
  printf '%s' "$r"
}

g5_config_dir_must_be_usable() {
  local repo notdir absent

  # (a) unset. The regression as it actually fires.
  repo="$(make_repo)"
  run_runner_cfg unset "" "$repo"
  g5_row "unset" "$repo"

  # (b) empty string. `set -u` is satisfied, so this one gets FURTHER: every path becomes
  # `/bin/<gate>`, which on a POSIX host is a real directory holding real programs. Nothing
  # named review-* lives there, so today it degrades to eight NOT FOUND lines — a report
  # that looks like a diagnosis of the gates when the diagnosis is of the configuration.
  repo="$(make_repo)"
  run_runner_cfg set "" "$repo"
  g5_row "empty" "$repo"

  # (c) relative. The reviewed tree's own code, executed as a gate.
  repo="$(make_repo_with_relative_cfg)"
  run_runner_cfg set "rel" "$repo"
  g5_row "relative" "$repo"
  if grep -qF -- "## STUB " <<< "$RQG_OUT"; then
    fail "G5[relative]d: no gate is executed out of the reviewed tree -- ran: $RQG_OUT"
  else
    pass "G5[relative]d: no gate is executed out of the reviewed tree"
  fi

  # (d) a path that exists and is not a directory.
  repo="$(make_repo)"
  notdir="$(mktemp "$TMPROOT/notadir.XXXXXX")"
  printf 'not a directory\n' > "$notdir"
  run_runner_cfg set "$notdir" "$repo"
  g5_row "not-a-directory" "$repo"

  # (e) absolute, well-formed, and simply not there. A separate input from (d), and the two
  # separate implementations: a check written as `[ -e ]` accepts a config dir that is a
  # regular file, and one written as `[ -d ]` on the bin/ subdirectory alone would answer
  # this one by the wrong route. It is also the spelling a stale or renamed checkout
  # produces, which is the likeliest way this ever fires in practice.
  #
  # This is NOT the case the SKIPPED note at the foot of this file sets aside: there the
  # config dir exists and merely has no gates in it, which is honestly reported as gates
  # missing. Here nothing about the configuration was ever resolvable.
  repo="$(make_repo)"
  absent="$TMPROOT/cfg-that-was-never-created"
  if [ -e "$absent" ]; then
    fail "G5[absent-absolute]0: the fixture path must not exist -- found: $absent"
  else
    pass "G5[absent-absolute]0: the fixture path does not exist"
  fi
  run_runner_cfg set "$absent" "$repo"
  g5_row "absent-absolute" "$repo"
}

# The three properties every spelling owes, asserted identically so the five rows cannot
# drift apart (CPR-ORTH): the verdict is on stdout, the exit is 0, and stdout is not empty —
# the last one is what separates "reported" from "died before printing anything".
g5_row() { # <name> <repo>
  local name="$1"
  if grep -qE "^##[[:space:]]*gates:[[:space:]]*NOT RUN" <<< "$RQG_OUT"; then
    pass "G5[$name]a: an unusable AGENTS_CONFIG_DIR is reported on stdout as NOT RUN"
  else
    fail "G5[$name]a: an unusable AGENTS_CONFIG_DIR is reported on stdout as NOT RUN -- no '## gates: NOT RUN' line in: [$RQG_OUT]"
  fi
  check "G5[$name]b: the advisory contract holds — the runner still exits 0" "0" "$RQG_RC"
  check "G5[$name]c: stdout is not empty, so the consumer has something to read" \
    "nonempty" "$([ -n "$RQG_OUT" ] && echo nonempty || echo empty)"
}

# ---- G5e: Pattern 4 — a usable config dir is NOT reported as NOT RUN --------

# The guard must be reachable only by the four spellings above. A validation that rejected
# every value would satisfy G5a-G5c four times over and disable the entire runner, and no
# other row in this suite asserts the ABSENCE of the NOT RUN line.
g5_usable_config_dir_still_runs() {
  local cfg repo
  cfg="$(make_full_cfg exec)"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"
  if grep -qE "^##[[:space:]]*gates:[[:space:]]*NOT RUN" <<< "$RQG_OUT"; then
    fail "G5e: an absolute, existing config dir is not reported NOT RUN -- in: $RQG_OUT"
  else
    pass "G5e: an absolute, existing config dir is not reported NOT RUN"
  fi
  check "G5f: and its gates actually ran" "$GATE_COUNT" \
    "$(grep -cF -- "## STUB " <<< "$RQG_OUT" || true)"
}

# SKIPPED: an AGENTS_CONFIG_DIR that exists, is absolute, and holds no bin/ directory at all.
# Because: that is indistinguishable from "every gate is missing", which G3 already owns —
#          eight NOT FOUND lines and the G8 summary saying so is the correct report, not a
#          NOT RUN. Asserting it here would pin the same behaviour under a second name.
# TL3 gap: a config dir on a mount that disappears mid-run (a disconnected network share),
#          where the directory validates and the individual gates then vanish.

if exec_bit_works; then
  g5_config_dir_must_be_usable
  g5_usable_config_dir_still_runs
else
  skip_case "G5 config-dir rows (this host ignores the execute bit, so a stub gate cannot be run)"
fi

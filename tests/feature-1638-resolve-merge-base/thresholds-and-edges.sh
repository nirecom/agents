# Part of tests/feature-1638-resolve-merge-base.sh (sourced, not standalone).
# Tests: bin/resolve-merge-base.sh
# Tags: merge-base, anomaly-detection, thresholds, config, boundary, scope:issue-specific, pwsh-not-required, TL2
#
# T — WHERE THE THRESHOLDS COME FROM, and N/N+1 on both axes.
#
# R8/R9 prove each axis can fire, by injecting an absurd threshold through the environment.
# That leaves the two things a wrong threshold actually breaks untested:
#
#   THE RESOLUTION ORDER (T1-T4). The value is looked up process env → bin/get-config-var
#   (the repo's .env) → a built-in default. Three sources, so there are two ways to get it
#   wrong and both are silent: a built-in default that does not match the documented one turns
#   SUSPECT into a state nobody can predict, and a config file that beats the environment makes
#   the documented escape hatch inert. skills/_shared/test-design.md requires the value to be
#   PINNED EXPLICITLY in every branch, so each row asserts BOTH threshold_lines and
#   threshold_files even where only one of them is the subject — a row that checked only the
#   axis it changed would accept an implementation that reset the other one to zero.
#
#   THE COMPARISON ITSELF (T5-T7). "Over the threshold" is one operator, and `>` versus `>=`
#   is a one-character difference that no absurd-value row can see. The boundary is taken from
#   the helper's OWN reported count rather than re-derived here, so the rows pin the operator
#   instead of re-implementing the measurement; T5 pins the measurement separately against git.
#
#   AND THE INPUT (T8). `git diff --numstat` reports `-` for a binary file. Summing that column
#   naively yields a non-numeric total and an arithmetic error, or a silent 0; either way the
#   detector stops working on any change that touches an image or an archive. A binary file is
#   one FILE and zero LINES, and both halves are asserted in the same row because an
#   implementation that drops binaries entirely gets the line count right by accident.

BUILTIN_THRESHOLD_LINES=20000
BUILTIN_THRESHOLD_FILES=500

# A config dir the real bin/get-config-var can read: it resolves hooks/lib/load-env.js under
# $AGENTS_CONFIG_DIR and load-env.js reads $AGENTS_CONFIG_DIR/.env. The hooks tree is copied
# rather than stubbed so the row goes through the real loader — a hand-written stub would be a
# second implementation of the resolution order this row exists to check.
make_cfg_with_env() { # <env-file-body> ; prints the config dir
  local cfg
  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  cp -r "$AGENTS_DIR/hooks" "$cfg/hooks"
  printf '%s\n' "$1" > "$cfg/.env"
  printf '%s' "$cfg"
}

t1_builtin_defaults() {
  local repo cfg
  repo="$(repo_with_main)"
  # A config dir whose .env says NOTHING about the thresholds, rather than an unset
  # AGENTS_CONFIG_DIR: unset would let get-config-var fall back to the DEVELOPER'S real .env,
  # and a machine that happens to set MERGE_BASE_MAX_DIFF_LINES would fail this row for a
  # reason that is not about the code.
  cfg="$(make_cfg_with_env "# deliberately silent about the thresholds")"
  HELPER_ENV=("AGENTS_CONFIG_DIR=$cfg")
  run_helper "$repo" -
  check "T1-lines: with no override the line threshold is the documented default" \
    "$BUILTIN_THRESHOLD_LINES" "$(kv threshold_lines)"
  check "T1-files: and so is the file threshold" \
    "$BUILTIN_THRESHOLD_FILES" "$(kv threshold_files)"
  check "T1-state: a small diff under the defaults resolves normally" "RESOLVED" "$(kv state)"
}

t2_config_file_is_read() {
  local repo cfg
  repo="$(repo_with_main)"
  cfg="$(make_cfg_with_env "MERGE_BASE_MAX_DIFF_LINES=3
MERGE_BASE_MAX_DIFF_FILES=7")"
  HELPER_ENV=("AGENTS_CONFIG_DIR=$cfg")
  run_helper "$repo" -
  check "T2-lines: a value in the config .env reaches the detector" "3" "$(kv threshold_lines)"
  check "T2-files: on both axes" "7" "$(kv threshold_files)"
  # The value has to be USED, not merely reported: the fixture's diff is over 3 lines.
  check "T2-state: and the configured threshold is what the state is decided by" \
    "SUSPECT" "$(kv state)"
}

t3_env_beats_config() {
  local repo cfg
  repo="$(repo_with_main)"
  cfg="$(make_cfg_with_env "MERGE_BASE_MAX_DIFF_LINES=3
MERGE_BASE_MAX_DIFF_FILES=7")"
  HELPER_ENV=("AGENTS_CONFIG_DIR=$cfg" MERGE_BASE_MAX_DIFF_LINES=30000 MERGE_BASE_MAX_DIFF_FILES=400)
  run_helper "$repo" -
  check "T3-lines: the process environment wins over the config file" "30000" "$(kv threshold_lines)"
  check "T3-files: on both axes" "400" "$(kv threshold_files)"
  check "T3-state: and the override is what decides the state — the config value would be SUSPECT" \
    "RESOLVED" "$(kv state)"
}

# The asymmetric half of T3: overriding ONE axis must not silently reset the other to a
# built-in. Without this row an implementation that reads the environment and then discards
# the config entirely still satisfies T2 and T3.
t4_partial_override_keeps_the_other_axis() {
  local repo cfg
  repo="$(repo_with_main)"
  cfg="$(make_cfg_with_env "MERGE_BASE_MAX_DIFF_LINES=3
MERGE_BASE_MAX_DIFF_FILES=7")"
  HELPER_ENV=("AGENTS_CONFIG_DIR=$cfg" MERGE_BASE_MAX_DIFF_LINES=30000)
  run_helper "$repo" -
  check "T4-lines: the overridden axis takes the environment value" "30000" "$(kv threshold_lines)"
  check "T4-files: and the axis with no override keeps the CONFIG value, not the built-in default" \
    "7" "$(kv threshold_files)"
}

# The measurement, against git, before any row leans on the number the helper reports.
t5_counts_match_git() {
  local repo base want_lines want_files
  repo="$(repo_with_main)"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 MERGE_BASE_MAX_DIFF_FILES=100000)
  run_helper "$repo" -
  base="$(kv base)"
  if [ -z "$base" ]; then
    fail "T5: the helper reported no base, so its counts cannot be compared with git's"
    return
  fi
  want_lines="$(git -C "$repo" diff --numstat "$base" HEAD | awk '$1 ~ /^[0-9]+$/ { a += $1 } $2 ~ /^[0-9]+$/ { d += $2 } END { printf "%d", a + d }')"
  want_files="$(git -C "$repo" diff --numstat "$base" HEAD | grep -c . || true)"
  check "T5-lines: diff_lines is added+deleted over the resolved range" "$want_lines" "$(kv diff_lines)"
  check "T5-files: diff_files is the number of changed paths" "$want_files" "$(kv diff_files)"
}

# N and N+1 on the line axis. `diff_lines == threshold_lines` is NOT over the threshold; one
# more is. Both halves are needed: either one alone is satisfied by a broken operator.
t6_line_axis_boundary() {
  local repo n
  repo="$(repo_with_main)"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 MERGE_BASE_MAX_DIFF_FILES=100000)
  run_helper "$repo" -
  n="$(kv diff_lines)"
  if ! printf '%s' "$n" | grep -qE '^[0-9]+$' || [ "$n" -lt 2 ]; then
    fail "T6: the helper reported diff_lines=[$n]; a boundary needs a countable, non-trivial diff"
    return
  fi
  HELPER_ENV=("MERGE_BASE_MAX_DIFF_LINES=$n" MERGE_BASE_MAX_DIFF_FILES=100000)
  run_helper "$repo" -
  check "T6-at: a diff exactly AT the line threshold is not anomalous" "RESOLVED" "$(kv state)"
  HELPER_ENV=("MERGE_BASE_MAX_DIFF_LINES=$((n - 1))" MERGE_BASE_MAX_DIFF_FILES=100000)
  run_helper "$repo" -
  check "T6-over: one line past it is" "SUSPECT" "$(kv state)"
}

t7_file_axis_boundary() {
  local repo n
  repo="$(repo_with_main)"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 MERGE_BASE_MAX_DIFF_FILES=100000)
  run_helper "$repo" -
  n="$(kv diff_files)"
  if ! printf '%s' "$n" | grep -qE '^[0-9]+$' || [ "$n" -lt 1 ]; then
    fail "T7: the helper reported diff_files=[$n]; a boundary needs a countable diff"
    return
  fi
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 "MERGE_BASE_MAX_DIFF_FILES=$n")
  run_helper "$repo" -
  check "T7-at: a diff exactly AT the file threshold is not anomalous" "RESOLVED" "$(kv state)"
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 "MERGE_BASE_MAX_DIFF_FILES=$((n - 1))")
  run_helper "$repo" -
  check "T7-over: one file past it is" "SUSPECT" "$(kv state)"
}

# A binary file plus exactly one changed text line. `git diff --numstat` prints `-` for the
# binary path, so the expected answer is diff_files=2, diff_lines=1 — the file counts, its
# (unknowable) line count does not.
t8_binary_counts_as_a_file_not_lines() {
  local repo
  repo="$(new_repo main)"
  commit_file "$repo" seed.txt 1 seed
  git -C "$repo" switch -q -c work >/dev/null 2>&1
  printf 'one added line\n' >> "$repo/seed.txt"
  printf 'PNG\000\001\002\003binary payload\000\377' > "$repo/blob.bin"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" commit -q -m "a binary file and one text line" >/dev/null 2>&1

  # The premise: git really does classify blob.bin as binary. On a host where it does not, the
  # row would be asserting the ordinary text path under a misleading name.
  if ! git -C "$repo" diff --numstat main HEAD | grep -qE '^-[[:space:]]+-[[:space:]]'; then
    fail "T8-fixture: git did not report blob.bin as binary, so the row cannot test the '-' column"
    return
  fi
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 MERGE_BASE_MAX_DIFF_FILES=100000)
  run_helper "$repo" -
  check "T8-files: a binary path counts toward diff_files" "2" "$(kv diff_files)"
  check "T8-lines: and contributes nothing to diff_lines" "1" "$(kv diff_lines)"
  check "T8-rc: a binary diff is not an error" "0" "$HB_RC"
  # The file axis must still be able to fire on a diff that is mostly binary — the state where
  # a naive line-sum would have said 0 and reported everything as normal.
  HELPER_ENV=(MERGE_BASE_MAX_DIFF_LINES=1000000 MERGE_BASE_MAX_DIFF_FILES=1)
  run_helper "$repo" -
  check "T8-suspect: and the file axis still fires on it" "SUSPECT" "$(kv state)"
}

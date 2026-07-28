# Part of tests/fix-quality-gates-not-found.sh (sourced, not standalone).
# Tests: skills/review-code-security/scripts/run-quality-gates.sh
# Tags: security-gate, quality-gates, review-code-security, merge-base, false-green, scope:common, pwsh-not-required, TL2
#
# G6 — the base every gate is scoped by, and the one degradation that is currently invisible.
#
# _resolve_merge_base tries `origin/main`, then `main`, then gives up and uses `HEAD~1`. The
# give-up is announced on STDERR only. Everything downstream reads STDOUT: the gates print
# there, the summary is read from there, and stderr is discarded by the caller. So when the
# base silently becomes HEAD~1 — a detached checkout, a shallow clone, a worktree branched
# from something other than main, a repository whose default branch is not `main` at all —
# every gate examines the wrong range, and the most expensive one self-reports
# `## Codex Review: SKIPPED — empty diff`, which reads as a clean pass.
#
# A wrong base is not an error; the run should continue. It is a CAVEAT, and a caveat that
# only exists on stderr is a caveat nobody has. Both directions are pinned: the line appears
# when the fallback is taken, and — the half that kills an unconditional `echo` — it does
# NOT appear when a real merge-base was found.
#
# AND THE BASE ITSELF. Reporting the caveat is only half of what a reader needs; the other
# half is that the value handed to the gates is a revision that exists. The ordinary stubs
# accept `--base` and ignore it, so on their own they would go green against a base of
# `HEAD~1` in a repository that has no HEAD~1 — the exact shape of a run where every gate
# examined nothing. G6e/G6f therefore record what each gate actually received and resolve it
# with `git rev-parse --verify <base>^{commit}`, in BOTH directions: a fallback base must be
# usable, and so must a normally-resolved one.

# A stub that behaves like write_stub and additionally appends every `--base` value it was
# given to a log, so the test can check the revision rather than just the report line.
write_stub_recording() { # <bin-dir> <name> <log-file>
  {
    printf '#!/usr/bin/env bash\n'
    printf 'BASE_LOG=%q\n' "$3"
    cat <<'STUB'
echo "## STUB $(basename "$0"): PERFORMED"
while [ $# -gt 0 ]; do
  if [ "$1" = "--base" ]; then printf '%s\n' "${2:-}" >> "$BASE_LOG"; fi
  shift
done
exit 0
STUB
  } > "$1/$2"
  chmod +x "$1/$2" 2>/dev/null || true
}

make_cfg_recording() { # <log-file> ; prints the config dir
  local cfg g
  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  mkdir -p "$cfg/bin" "$cfg/rules"
  : > "$cfg/rules/core-principles.md"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    write_stub_recording "$cfg/bin" "$g" "$1"
  done <<< "$GATES"
  printf '%s' "$cfg"
}

# Every base recorded during the run must name a commit in the repo that was reviewed. The
# count row is the vacuity guard: with no lines in the log the resolve loop passes trivially.
g6_recorded_bases_resolve() { # <row-id> <repo> <log-file>
  local row="$1" repo="$2" log="$3" b bad=""
  check "$row-count: every gate was handed a --base" "$GATE_COUNT" \
    "$(wc -l < "$log" | tr -d '[:space:]')"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if ! git -C "$repo" rev-parse --verify --quiet "$b^{commit}" >/dev/null 2>&1; then
      bad="$bad $b"
    fi
  done < "$log"
  check "$row-resolves: the base handed to the gates is a revision that exists" "" "$bad"
}

# The fixture claim every row below rests on, asserted rather than assumed: two commits, so
# HEAD~1 is a real revision and the two branches of _resolve_merge_base are genuinely
# different inputs. A fixture whose commits failed would send BOTH repos down the fallback
# path and make G6d green for the wrong reason.
g6_fixture_has_history() {
  local repo
  repo="$(make_repo)"
  check "G6-fixture-a: the main-branch fixture has the history HEAD~1 needs" "2" \
    "$(git -C "$repo" rev-list --count HEAD 2>/dev/null || echo 0)"
  repo="$(make_repo_no_main)"
  check "G6-fixture-b: the no-main fixture has it too" "2" \
    "$(git -C "$repo" rev-list --count HEAD 2>/dev/null || echo 0)"
}

g6_fallback_is_reported() {
  local cfg repo

  # No branch named `main` and no remote, so both merge-base attempts miss.
  cfg="$(make_full_cfg exec)"
  repo="$(make_repo_no_main)"
  run_runner "$cfg" "$repo"
  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*FALLBACK" <<< "$RQG_OUT"; then
    pass "G6a: a merge-base that degraded to HEAD~1 says so on stdout"
  else
    fail "G6a: a merge-base that degraded to HEAD~1 says so on stdout -- no '## merge-base: FALLBACK' line in: [$RQG_OUT]"
  fi
  check "G6b: the degraded base is a caveat, not a failure — the runner still exits 0" \
    "0" "$RQG_RC"
  check "G6c: and the gates still ran against it" "$GATE_COUNT" \
    "$(grep -cF -- "## STUB " <<< "$RQG_OUT" || true)"

  # Pattern 4. `main` exists and merge-base answers, so the caveat must be absent — an
  # unconditional line would satisfy G6a forever and tell a reader nothing.
  cfg="$(make_full_cfg exec)"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"
  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*FALLBACK" <<< "$RQG_OUT"; then
    fail "G6d: a merge-base that resolved normally carries no FALLBACK line -- in: $RQG_OUT"
  else
    pass "G6d: a merge-base that resolved normally carries no FALLBACK line"
  fi
}

# The same two runs again, this time watching what the gates were handed rather than what
# the report said. Kept separate from G6a-G6d so a recording stub never stands in for the
# ordinary one in the rows above.
g6_base_is_a_real_revision() {
  local cfg repo log

  log="$(mktemp "$TMPROOT/base.XXXXXX")"
  cfg="$(make_cfg_recording "$log")"
  repo="$(make_repo_no_main)"
  run_runner "$cfg" "$repo"
  g6_recorded_bases_resolve "G6e" "$repo" "$log"

  log="$(mktemp "$TMPROOT/base.XXXXXX")"
  cfg="$(make_cfg_recording "$log")"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"
  g6_recorded_bases_resolve "G6f" "$repo" "$log"
}

# SKIPPED: the `origin/main` branch of _resolve_merge_base (the first of the three).
# Because: it needs a real remote to fetch from, and every fixture here is a bare local
#          repository with no remote precisely so that `git fetch` fails in milliseconds
#          rather than reaching the network from a test.
# TL3 gap: a fetch that succeeds but returns a stale origin/main, where the base resolves
#          without a fallback and is still the wrong range — no line is owed in that case
#          and none would be printed, so the caveat cannot cover it.

g6_fixture_has_history
if exec_bit_works; then
  g6_fallback_is_reported
  g6_base_is_a_real_revision
else
  skip_case "G6 merge-base rows (this host ignores the execute bit, so a stub gate cannot be run)"
fi

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
  install_merge_base_helper "$cfg/bin"
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

# C1 (#1638 round-2 coverage) — G6a-G6d pin the FALLBACK REPORT LINE and the gate COUNT, never
# the base value each gate actually received. #1638's adopted non-interactive policy narrows
# EVERY untrustworthy state to uncommitted changes (`--base HEAD`) — SUSPECT, UNRESOLVED, and
# FALLBACK alike — because FALLBACK's `HEAD~1` guess is itself an unverified range: a commit
# chosen only because nothing else resolved, not one anyone vouched for. G6i already pins
# `--base HEAD` for SUSPECT; this row pins the same value for FALLBACK so a runner that
# narrows SUSPECT correctly but still hands FALLBACK gates the raw `HEAD~1` guess is caught.
g6_fallback_base_is_narrowed_to_head() {
  local cfg repo log

  log="$(mktemp "$TMPROOT/base.XXXXXX")"
  cfg="$(make_cfg_recording "$log")"
  repo="$(make_repo_no_main)"
  run_runner "$cfg" "$repo"
  g6_recorded_bases_all_equal "G6o" "$log" "HEAD"
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

# ============================================================================
# The case the FALLBACK caveat cannot cover: a base that RESOLVED and is still wrong.
#
# This was the shape of #1638. `origin/main` answered, no fallback was taken, no caveat was
# owed and none was printed — and the range it named reached back past a history rewrite, so
# every gate was handed a 280k-line diff and review-code-codex reported on the first 5000
# lines of it. "The merge-base resolved" and "the merge-base is trustworthy" are two
# different facts, and G6a-G6f only ever pinned the first one.
#
# The fixture below builds that exact history locally: a bare `origin.git` whose `main` was
# force-pushed onto a divergent old line, so `git merge-base origin/main HEAD` SUCCEEDS and
# returns a commit far behind the real branch point. No network, no fetch failure — the
# resolution works, and the answer is wrong. G6j asserts that premise directly rather than
# trusting it, because a fixture where the two candidates happened to agree would make every
# row below green while testing nothing.
# ============================================================================

mb_commit() { # <repo> <path> <line-count> <message>
  local r="$1" p="$2" n="$3" m="$4" i
  mkdir -p "$r/$(dirname "$p")"
  : > "$r/$p"
  for ((i = 0; i < n; i++)); do printf 'line %s of %s\n' "$i" "$m" >> "$r/$p"; done
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" -c user.email=test@example.com -c user.name=test \
    commit -q -m "$m" >/dev/null 2>&1
}

# origin/main resolves, and resolves to the wrong side of a rewrite.
make_repo_with_stale_origin() { # ; prints the repo path
  local r bare
  bare="$(mktemp -d "$TMPROOT/origin.XXXXXX")/origin.git"
  git init -q --bare "$bare" >/dev/null 2>&1
  r="$(make_repo_on_branch main)"
  git -C "$r" remote add origin "$bare" >/dev/null 2>&1
  git -C "$r" push -q origin main >/dev/null 2>&1

  # The abandoned line. Force-pushing it over origin/main is what makes the remote's idea of
  # main diverge from the local one while still sharing an ancestor.
  git -C "$r" switch -q -c oldline >/dev/null 2>&1
  mb_commit "$r" oldline.txt 1 "A1 old line"
  git -C "$r" push -q -f origin oldline:main >/dev/null 2>&1

  # The rewrite. Deliberately bulky, so the range measured from the stale origin/main is
  # large enough for the anomaly detector to have something to detect.
  git -C "$r" switch -q main >/dev/null 2>&1
  mb_commit "$r" rewrite/a.txt 30 "B1 rewrite a"
  mb_commit "$r" rewrite/b.txt 30 "B1 rewrite b"
  mb_commit "$r" rewrite/c.txt 30 "B1 rewrite c"
  mb_commit "$r" rewrite/d.txt 5 "B2 rewrite tail"

  git -C "$r" switch -q -c work >/dev/null 2>&1
  mb_commit "$r" feature.txt 2 "C1 the actual change"
  git -C "$r" fetch -q origin >/dev/null 2>&1
  printf '%s' "$r"
}

# ONE commit and no main: HEAD~1 does not resolve either, so there is no base at all. This
# is the input that separates UNRESOLVED from FALLBACK — handing `HEAD~1` to eight gates in
# this repository is the failure the FALLBACK path must not be allowed to cause.
make_repo_root_only() { # ; prints the repo path
  local r
  r="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  git -C "$r" init -q -b work >/dev/null 2>&1
  git -C "$r" config core.hooksPath "$r/.git/no-such-hooks" >/dev/null 2>&1
  : > "$r/seed.txt"
  git -C "$r" add seed.txt >/dev/null 2>&1
  git -C "$r" -c user.email=test@example.com -c user.name=test \
    commit -q -m seed >/dev/null 2>&1
  printf '%s' "$r"
}

# Every gate was handed the SAME base, and that base is the expected literal. Used where the
# contract is "scope the gates to uncommitted changes instead", which is a specific value
# (`HEAD`) rather than merely "some revision that exists".
g6_recorded_bases_all_equal() { # <row-id> <log-file> <expected>
  local row="$1" log="$2" want="$3" b bad=""
  check "$row-count: every gate was handed a --base" "$GATE_COUNT" \
    "$(wc -l < "$log" | tr -d '[:space:]')"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$b" = "$want" ] || bad="$bad [$b]"
  done < "$log"
  check "$row-value: and every one of them was $want" "" "$bad"
}

g6_stale_origin_is_reported() {
  local cfg repo log mb_main mb_origin

  repo="$(make_repo_with_stale_origin)"

  # The premise, asserted. Both candidates must resolve, and they must DISAGREE — otherwise
  # the rows below would pass against an ordinary repository and prove nothing.
  mb_main="$(git -C "$repo" merge-base main HEAD 2>/dev/null || true)"
  mb_origin="$(git -C "$repo" merge-base origin/main HEAD 2>/dev/null || true)"
  if [ -n "$mb_main" ] && [ -n "$mb_origin" ] && [ "$mb_main" != "$mb_origin" ]; then
    pass "G6j: the fixture's origin/main resolves to a different, older base than local main"
  else
    fail "G6j: the fixture did not diverge -- main=[$mb_main] origin=[$mb_origin]"
  fi

  log="$(mktemp "$TMPROOT/base.XXXXXX")"
  cfg="$(make_cfg_recording "$log")"
  run_runner "$cfg" "$repo" MERGE_BASE_MAX_DIFF_LINES=50 MERGE_BASE_MAX_DIFF_FILES=2

  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*SUSPECT" <<< "$RQG_OUT"; then
    pass "G6g: a merge-base that resolved but names an implausible range is reported SUSPECT"
  else
    fail "G6g: a merge-base that resolved but names an implausible range is reported SUSPECT -- no '## merge-base: SUSPECT' line in: [$RQG_OUT]"
  fi
  if grep -qF -- "uncommitted changes" <<< "$RQG_OUT"; then
    pass "G6g-scope: and the line says what the gates were scoped to instead"
  else
    fail "G6g-scope: the SUSPECT line does not name the replacement scope -- in: [$RQG_OUT]"
  fi
  check "G6h: an untrustworthy base is a caveat, not a failure — the runner still exits 0" \
    "0" "$RQG_RC"
  check "G6i-ran: and the gates still ran" "$GATE_COUNT" \
    "$(grep -cF -- "## STUB " <<< "$RQG_OUT" || true)"
  # HEAD, not the resolved base: the whole point of SUSPECT is that the resolved range is
  # not used. A row that only checked "the base resolves" would accept the 280k-line range.
  g6_recorded_bases_all_equal "G6i" "$log" "HEAD"
}

# The `--base HEAD` narrowing has to be reserved for the states that earn it. A run against
# an ordinary repository must carry NONE of the new report lines, or the reader learns
# nothing from seeing one.
g6_normal_run_carries_no_caveat() {
  local cfg repo state found=""
  cfg="$(make_full_cfg exec)"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"
  for state in RECORDED SUSPECT UNRESOLVED; do
    if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*$state" <<< "$RQG_OUT"; then
      found="$found [$state]"
    fi
  done
  check "G6l: a normally resolved merge-base carries no caveat line at all" "" "$found"
}

# No base exists, and FALLBACK would be a lie: `HEAD~1` is not a revision in this repository.
g6_unresolved_is_distinct_from_fallback() {
  local cfg repo log
  log="$(mktemp "$TMPROOT/base.XXXXXX")"
  cfg="$(make_cfg_recording "$log")"
  repo="$(make_repo_root_only)"
  run_runner "$cfg" "$repo"

  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*UNRESOLVED" <<< "$RQG_OUT"; then
    pass "G6m: a repository with no possible base is reported UNRESOLVED"
  else
    fail "G6m: a repository with no possible base is reported UNRESOLVED -- no such line in: [$RQG_OUT]"
  fi
  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*FALLBACK" <<< "$RQG_OUT"; then
    fail "G6m-not-fallback: it was reported FALLBACK, which claims a HEAD~1 that does not exist"
  else
    pass "G6m-not-fallback: and NOT FALLBACK, which would claim a HEAD~1 that does not exist"
  fi
  g6_recorded_bases_all_equal "G6m-base" "$log" "HEAD"
}

# The helper is a separate file under $AGENTS_CONFIG_DIR/bin, so "it is not there" is a real
# state of the world — a partial install, an older checkout, a config dir assembled by hand.
# The runner must degrade to the safe scope rather than to a guessed range, and must not
# treat the missing helper as a failure.
g6_missing_helper_degrades_safely() {
  local cfg repo log
  log="$(mktemp "$TMPROOT/base.XXXXXX")"
  cfg="$(make_cfg_recording "$log")"
  repo="$(make_repo)"
  rm -f "$cfg/bin/resolve-merge-base.sh"
  run_runner "$cfg" "$repo"

  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*UNRESOLVED" <<< "$RQG_OUT"; then
    pass "G6n: a missing merge-base helper is reported UNRESOLVED"
  else
    fail "G6n: a missing merge-base helper is reported UNRESOLVED -- no such line in: [$RQG_OUT]"
  fi
  check "G6n-rc: and the run continues — exit 0" "0" "$RQG_RC"
  check "G6n-ran: with every gate still executed" "$GATE_COUNT" \
    "$(grep -cF -- "## STUB " <<< "$RQG_OUT" || true)"
}

# The recorded baseline reaching the runner. The session's own branch point is a FACT rather
# than a guess, so it must beat both merge-base candidates — including on the stale-origin
# fixture, where the guess is demonstrably wrong. The two sibling scripts the helper consults
# are stubbed here (a real session id and a real state file are not available inside a
# throwaway config dir), and the bridge stub is written in node because the real one is a
# node script and the helper may invoke it either way.
g6_recorded_baseline_wins() {
  local cfg repo log base head
  repo="$(make_repo_with_stale_origin)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"

  log="$(mktemp "$TMPROOT/base.XXXXXX")"
  cfg="$(make_cfg_recording "$log")"
  mkdir -p "$cfg/bin/workflow"
  printf '#!/usr/bin/env bash\necho "sid-g6k"\n' > "$cfg/bin/resolve-session-id"
  chmod +x "$cfg/bin/resolve-session-id" 2>/dev/null || true
  {
    printf '#!/usr/bin/env node\n'
    printf 'process.stdout.write([\n'
    printf '  "base=%s",\n' "$base"
    printf '  "branch=work",\n'
    printf '  "branch_head=%s",\n' "$head"
    printf '  "repo_root=%s",\n' "$repo"
    printf '  "source=recorded-baseline",\n'
    printf '  "post_session_head=false",\n'
    printf '  "alt_base=-",\n'
    printf '  "recorded_at=2026-07-30T00:00:00Z"\n'
    printf '].join("\\n") + "\\n");\n'
  } > "$cfg/bin/workflow/read-merge-base-baseline"
  chmod +x "$cfg/bin/workflow/read-merge-base-baseline" 2>/dev/null || true

  run_runner "$cfg" "$repo" MERGE_BASE_MAX_DIFF_LINES=50 MERGE_BASE_MAX_DIFF_FILES=2

  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*RECORDED" <<< "$RQG_OUT"; then
    pass "G6k: a recorded session baseline is reported RECORDED and beats the stale origin/main"
  else
    fail "G6k: a recorded session baseline is reported RECORDED -- no such line in: [$RQG_OUT]"
  fi
  g6_recorded_bases_all_equal "G6k-base" "$log" "$base"
}

# SKIPPED: a real remote over the network.
# Because: origin.git above is a bare repository on the same filesystem, so `git fetch`
#          costs milliseconds and no row can reach outside the machine.
# TL3 gap: authentication, a remote whose HEAD points at something other than `main`, and a
#          fetch that is slow enough for the runner's timeout to matter — none of which a
#          local bare remote can reproduce.

g6_fixture_has_history
if exec_bit_works; then
  g6_fallback_is_reported
  g6_fallback_base_is_narrowed_to_head
  g6_base_is_a_real_revision
  g6_stale_origin_is_reported
  g6_normal_run_carries_no_caveat
  g6_unresolved_is_distinct_from_fallback
  g6_missing_helper_degrades_safely
  if command -v node >/dev/null 2>&1; then
    g6_recorded_baseline_wins
  else
    skip_case "G6k recorded-baseline row (node is not available on this host)"
  fi
else
  skip_case "G6 merge-base rows (this host ignores the execute bit, so a stub gate cannot be run)"
fi

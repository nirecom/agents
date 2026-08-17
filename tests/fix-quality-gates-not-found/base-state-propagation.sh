# Part of tests/fix-quality-gates-not-found.sh (sourced, not standalone).
# Tests: skills/review-code-security/scripts/run-quality-gates.sh, bin/review-code-codex
# Tags: security-gate, quality-gates, merge-base, argv-propagation, false-green, scope:common, pwsh-not-required, TL2
#
# G10 — WHAT THE RUNNER TELLS THE GATE, not just what it tells the reader.
#
# G6 pins the report lines and the --base value. Both are about the runner's own output. The
# state is also an INPUT to one gate: review-code-codex has to warn inside its prompt and on
# its stdout that the range it reviewed is not trustworthy, and it cannot know that unless the
# runner passes it. A runner that prints a perfect `## merge-base: SUSPECT` line and forgets
# --base-state produces a report where the caveat is at the top and the codex section below it
# still reads like an unqualified review of the change.
#
# TWO HALVES, and the second is the one that rots:
#   IT ARRIVES. review-code-codex must receive --base-state <STATE> for EVERY state the
#   resolver can produce, not only for the alarming ones. RESOLVED has to arrive too: an
#   implementation that passes the flag only when something is wrong leaves the gate defaulting
#   to UNKNOWN on the ordinary path, so its own scope line can never say "the base was fine".
#   IT ARRIVES NOWHERE ELSE. The other gates do not accept the flag. Handing `--base-state` to
#   a script that parses arguments strictly is an immediate usage error, and to one that ignores
#   unknown flags it is silent noise that the next author will copy. Each row therefore asserts
#   the ABSENCE of the flag from every other gate's argv, which is the assertion that catches a
#   well-meaning "pass it to all of them" refactor.
#
# WHY ARGV RATHER THAN THE REPORT. There is no line on stdout that says what codex was handed;
# the existing recording stub logs only `--base`. So the stubs here log their FULL argument
# vector to a per-gate file, and the rows read it back. That is the only place the flag is
# observable without running the real gate.
#
# G11 is the second reporting obligation of the same table: warn=post-session-head. It is not a
# state — the base is a fact, the session has simply moved on — so it must be its OWN line
# carrying the alternative base, and it must be able to appear next to a state line that says
# nothing is wrong. A NOTE folded into the state line disappears in exactly that case.

ARGV_STATES="RECORDED RESOLVED SUSPECT FALLBACK UNRESOLVED"

# A stub that behaves like write_stub and additionally records every argument it received, one
# per line, in <log-dir>/<its own name>.argv.
write_stub_argv() { # <bin-dir> <name> <log-dir>
  {
    printf '#!/usr/bin/env bash\n'
    printf 'ARGV_LOG_DIR=%q\n' "$3"
    cat <<'STUB'
echo "## STUB $(basename "$0"): PERFORMED"
mkdir -p "$ARGV_LOG_DIR"
: > "$ARGV_LOG_DIR/$(basename "$0").argv"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_LOG_DIR/$(basename "$0").argv"; done
exit 0
STUB
  } > "$1/$2"
  chmod +x "$1/$2" 2>/dev/null || true
}

make_cfg_argv() { # <log-dir> ; prints the config dir
  local cfg g
  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  mkdir -p "$cfg/bin" "$cfg/rules"
  : > "$cfg/rules/core-principles.md"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    write_stub_argv "$cfg/bin" "$g" "$1"
  done <<< "$GATES"
  install_merge_base_helper "$cfg/bin"
  printf '%s' "$cfg"
}

# The value that followed --base-state in one gate's argv, or the empty string when the flag
# was not passed. Reading the NEXT line rather than grepping for the pair is deliberate: it
# distinguishes `--base-state SUSPECT` from `--base-state --no-log`, which is what a missing
# value looks like.
argv_flag_value() { # <argv-file> <flag> ; prints the value
  [ -f "$1" ] || return 0
  awk -v f="$2" 'found { print; exit } $0 == f { found = 1 }' "$1"
}

# One state, both halves. Given the argv log directory, assert review-code-codex received the
# expected state and that no other gate received the flag at all.
expect_base_state() { # <row-id> <log-dir> <want-state>
  local row="$1" dir="$2" want="$3" f name got leaked=""
  # The vacuity guard: with no argv files at all the "nobody else got it" loop below is
  # trivially satisfied, so the presence of the logs is asserted first.
  check "$row-ran: every gate recorded its arguments" "$GATE_COUNT" \
    "$(find "$dir" -name '*.argv' 2>/dev/null | grep -c . || true)"

  got="$(argv_flag_value "$dir/review-code-ledger.argv" --base-state)"
  check "$row: review-code-codex is told the merge-base state" "$want" "$got"

  for f in "$dir"/*.argv; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .argv)"
    [ "$name" = "review-code-ledger" ] && continue
    if grep -qxF -- "--base-state" "$f"; then leaked="$leaked [$name]"; fi
  done
  check "$row-only: and no other gate is handed a flag it does not accept" "" "$leaked"
}

# A read-merge-base-baseline bridge stub for the config dir, so the RECORDED and post-session-head
# rows can control the record without a real session. Written in node because the real bridge is
# a node script and the helper may invoke it either way.
install_baseline_stub() { # <cfg> <repo> <base> <branch> <branch-head> <post-session-head> <alt-base>
  local cfg="$1"
  mkdir -p "$cfg/bin/workflow"
  printf '#!/usr/bin/env bash\necho "sid-g8"\n' > "$cfg/bin/resolve-session-id"
  chmod +x "$cfg/bin/resolve-session-id" 2>/dev/null || true
  {
    printf '#!/usr/bin/env node\n'
    printf 'process.stdout.write([\n'
    printf '  "base=%s",\n' "$3"
    printf '  "branch=%s",\n' "$4"
    printf '  "branch_head=%s",\n' "$5"
    printf '  "repo_root=%s",\n' "$2"
    printf '  "source=recorded-baseline",\n'
    printf '  "post_session_head=%s",\n' "$6"
    printf '  "alt_base=%s",\n' "$7"
    printf '  "recorded_at=2026-07-30T00:00:00Z"\n'
    printf '].join("\\n") + "\\n");\n'
  } > "$cfg/bin/workflow/read-merge-base-baseline"
  chmod +x "$cfg/bin/workflow/read-merge-base-baseline" 2>/dev/null || true
}

g10_resolved_state_is_passed() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"
  # The ordinary path. Passing the flag here is what lets the gate distinguish "the base was
  # fine" from "nobody told me", and it is the row an only-when-broken implementation fails.
  expect_base_state "G10a-RESOLVED" "$dir" "RESOLVED"
}

g10_fallback_state_is_passed() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo_no_main)"
  run_runner "$cfg" "$repo"
  expect_base_state "G10b-FALLBACK" "$dir" "FALLBACK"
}

g10_suspect_state_is_passed() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo_with_stale_origin)"
  run_runner "$cfg" "$repo" MERGE_BASE_MAX_DIFF_LINES=50 MERGE_BASE_MAX_DIFF_FILES=2
  expect_base_state "G10c-SUSPECT" "$dir" "SUSPECT"
  # SUSPECT narrows the range to HEAD, and the state has to travel WITH the narrowed base:
  # a gate handed `--base HEAD --base-state RESOLVED` would report a clean review of nothing.
  check "G10c-base: and the narrowed base travels with it" "HEAD" \
    "$(argv_flag_value "$dir/review-code-ledger.argv" --base)"
}

g10_unresolved_state_is_passed() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo_root_only)"
  run_runner "$cfg" "$repo"
  expect_base_state "G10d-UNRESOLVED" "$dir" "UNRESOLVED"
}

g10_recorded_state_is_passed() {
  local cfg repo dir base head
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo_with_stale_origin)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  install_baseline_stub "$cfg" "$repo" "$base" work "$head" false -
  run_runner "$cfg" "$repo" MERGE_BASE_MAX_DIFF_LINES=50 MERGE_BASE_MAX_DIFF_FILES=2
  expect_base_state "G10e-RECORDED" "$dir" "RECORDED"
  check "G10e-base: with the recorded base rather than the stale guess" "$base" \
    "$(argv_flag_value "$dir/review-code-ledger.argv" --base)"
}

# The helper is a separate file that can simply be absent. The runner still has to tell codex
# something, and the something must be the state it reported to the reader — silence here is
# how a gate ends up reviewing a range nobody vouched for while claiming UNKNOWN.
g10_missing_helper_still_passes_a_state() {
  local cfg repo dir got
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo)"
  rm -f "$cfg/bin/resolve-merge-base.sh"
  run_runner "$cfg" "$repo"
  got="$(argv_flag_value "$dir/review-code-ledger.argv" --base-state)"
  if [ "$got" = "UNRESOLVED" ]; then
    pass "G10f: with no resolver installed, codex is still told the state the report claimed (UNRESOLVED)"
  else
    fail "G10f: with no resolver installed, codex was told [$got] rather than the UNRESOLVED the report claimed"
  fi
}

# ============================================================================
# G11 — warn=post-session-head, the note that is not a state.
# ============================================================================

# The recorded base is correct and the session has since committed on top of it, so the
# resolved range no longer ends at the HEAD the user is looking at. That is worth ONE extra
# line naming the alternative base — and it must not be expressed by downgrading the state,
# because the base itself is still the right one to review from.
g11_post_session_head_is_its_own_line() {
  local cfg repo dir base head alt note
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  alt="$head"
  install_baseline_stub "$cfg" "$repo" "$base" main "$head" true "$alt"
  run_runner "$cfg" "$repo"

  note="$(grep -E "^##[[:space:]]*merge-base:[[:space:]]*NOTE" <<< "$RQG_OUT" || true)"
  if [ -n "$note" ]; then
    pass "G11a: a baseline the session has moved past gets its own '## merge-base: NOTE' line"
  else
    fail "G11a: no '## merge-base: NOTE' line for warn=post-session-head -- in: [$RQG_OUT]"
  fi
  # The alternative base is the actionable half: without it the note says only "something is
  # off" and the reader has nothing to re-run against.
  if printf '%s' "$note" | grep -qF -- "$alt"; then
    pass "G11b: and the line carries the alternative base the reader can re-run against"
  else
    fail "G11b: the NOTE line does not name the alternative base [$alt] -- got [$note]"
  fi
  # A note is not a demotion. If post-session-head were folded into the state the base would
  # be narrowed to HEAD and the review would silently cover less than the change.
  check "G11c: the state is unchanged by the note — the recorded base is still a fact" "RECORDED" \
    "$(argv_flag_value "$dir/review-code-ledger.argv" --base-state)"
  check "G11c-base: and the recorded base is still what the gates are scoped by" "$base" \
    "$(argv_flag_value "$dir/review-code-ledger.argv" --base)"
  check "G11d: a caveat is not a failure — the runner still exits 0" "0" "$RQG_RC"
}

# The other direction, without which an unconditional NOTE line satisfies G11a forever.
g11_no_note_when_nothing_to_note() {
  local cfg repo dir base head
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo)"
  base="$(git -C "$repo" rev-parse HEAD~1)"
  head="$(git -C "$repo" rev-parse HEAD)"
  install_baseline_stub "$cfg" "$repo" "$base" main "$head" false -
  run_runner "$cfg" "$repo"
  if grep -qE "^##[[:space:]]*merge-base:[[:space:]]*NOTE" <<< "$RQG_OUT"; then
    fail "G11e: a NOTE line was printed although there is no alternative base to offer -- in: [$RQG_OUT]"
  else
    pass "G11e: no NOTE line when the recorded baseline still ends at the HEAD under review"
  fi
}

# SKIPPED: running the real review-code-codex to see the flag accepted.
# Because: it bills a model call per invocation, and the flag's acceptance is pinned directly
#          in tests/feature-review-code-codex.sh against the real script.
# TL3 gap: a runner that passes --base-state to a codex build that predates the flag. Only a
#          real pair of scripts on one host can catch that mismatch.

if exec_bit_works; then
  g10_resolved_state_is_passed
  g10_fallback_state_is_passed
  g10_suspect_state_is_passed
  g10_unresolved_state_is_passed
  g10_missing_helper_still_passes_a_state
  if command -v node >/dev/null 2>&1; then
    g10_recorded_state_is_passed
    g11_post_session_head_is_its_own_line
    g11_no_note_when_nothing_to_note
  else
    skip_case "G10e/G11 (node is not available on this host, so the baseline bridge cannot be stubbed)"
  fi
else
  skip_case "G10/G11 (this host ignores the execute bit, so a stub gate cannot be run)"
fi

# Part of tests/fix-quality-gates-not-found.sh (sourced, not standalone).
# Tests: skills/review-code-security/scripts/run-quality-gates.sh, bin/lib/codex-review-loop/ref-kind-input.sh
# Tags: security-gate, quality-gates, merge-base, argv-propagation, false-green, scope:common, pwsh-not-required, TL2
#
# G10 — WHAT THE RUNNER TELLS THE GATES, not just what it tells the reader. G6 pins the report
# lines on stdout; this file pins the argv, where a wrongly scoped gate is invisible. No stdout
# line says what a gate was handed, so the stubs record their FULL argument vector per gate.
# #2276 took the codex reviewer out of this runner, and with it the only gate that ever
# accepted --base-state: the state now reaches the reviewer through run-codex-review-loop,
# which derives it from bin/resolve-merge-base.sh itself.
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

# The two halves this file owns, given one gate log directory:
#   EVERY GATE IS SCOPED BY THE SAME BASE — a gate handed a different --base reviews a
#   different range while the report above it describes the runner's.
#   NO GATE IS HANDED THE STATE — --base-state is an immediate usage error for a gate that
#   parses strictly, and silent noise the next author copies for one that does not. Since
#   #2276 the flag belongs to the review loop, which builds it from the resolver itself.
# <want-base> is optional: the fixtures that know the base pin it, the rest only require
# agreement, which is what a "scope this one differently" regression breaks.
expect_gate_scoping() { # <row-id> <log-dir> [<want-base>]
  local row="$1" dir="$2" want="${3:-}" f name val bad="" leaked="" seen=""
  # The vacuity guard: with no argv files at all every loop below is trivially satisfied, so
  # the presence of the logs is asserted first.
  check "$row-ran: every gate recorded its arguments" "$GATE_COUNT" \
    "$(find "$dir" -name '*.argv' 2>/dev/null | grep -c . || true)"

  for f in "$dir"/*.argv; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .argv)"
    val="$(argv_flag_value "$f" --base)"
    if [ -z "$val" ]; then bad="$bad [$name:no-base]"
    elif [ -n "$want" ] && [ "$val" != "$want" ]; then bad="$bad [$name:$val]"; fi
    case " $seen " in *" $val "*) ;; *) seen="$seen $val" ;; esac
    if grep -qxF -- "--base-state" "$f"; then leaked="$leaked [$name]"; fi
  done
  check "$row: every gate is scoped by the base the runner resolved" "" "$bad"
  check "$row-one: and every gate by the same one" "1" \
    "$(printf '%s' "$seen" | wc -w | tr -d ' ')"
  check "$row-only: the merge-base state reaches no gate — the review loop derives its own" \
    "" "$leaked"
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
  local cfg repo dir want
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo)"
  want="$(git -C "$repo" merge-base main HEAD 2>/dev/null || true)"
  run_runner "$cfg" "$repo"
  # The ordinary path, where the base is a real merge-base rather than the HEAD every degraded
  # state falls back to. A runner that scoped only the degraded rows correctly fails here, so
  # the expected value is asserted computable before it is used as one.
  check "G10a-fixture: the fixture repo really has a merge-base to be scoped by" "yes" \
    "$([ -n "$want" ] && printf yes || printf no)"
  expect_gate_scoping "G10a-RESOLVED" "$dir" "$want"
}

g10_fallback_state_is_passed() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo_no_main)"
  run_runner "$cfg" "$repo"
  expect_gate_scoping "G10b-FALLBACK" "$dir"
}

g10_suspect_state_is_passed() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo_with_stale_origin)"
  run_runner "$cfg" "$repo" MERGE_BASE_MAX_DIFF_LINES=50 MERGE_BASE_MAX_DIFF_FILES=2
  # SUSPECT narrows the range to HEAD, and the narrowing has to reach the gates: one still
  # scoped by the implausible base reviews a range the report has already disowned.
  expect_gate_scoping "G10c-SUSPECT" "$dir" "HEAD"
}

g10_unresolved_state_is_passed() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo_root_only)"
  run_runner "$cfg" "$repo"
  expect_gate_scoping "G10d-UNRESOLVED" "$dir" "HEAD"
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
  # The recorded base beats the stale guess the same fixture would otherwise produce, so this
  # row is the one that catches a runner scoping the gates by the resolver's raw answer.
  expect_gate_scoping "G10e-RECORDED" "$dir" "$base"
}

# The helper is a separate file that can simply be absent, and the runner reports UNRESOLVED
# when it is. The gates must then be scoped to the base that certainly exists rather than left
# with an empty --base, which is how a gate ends up reviewing the whole history or nothing.
g10_missing_helper_still_passes_a_state() {
  local cfg repo dir
  dir="$(mktemp -d "$TMPROOT/argv.XXXXXX")"
  cfg="$(make_cfg_argv "$dir")"
  repo="$(make_repo)"
  rm -f "$cfg/bin/resolve-merge-base.sh"
  run_runner "$cfg" "$repo"
  expect_gate_scoping "G10f-no-resolver" "$dir" "HEAD"
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
  # be narrowed to HEAD and every gate would silently cover less than the change — which is
  # visible here, in the argv, rather than in the report line G11a already pins.
  expect_gate_scoping "G11c-still-recorded" "$dir" "$base"
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

# Where the state went. Asserting only that no gate receives it would be satisfied by a chain
# in which nobody does, so the obligation is followed to its new owner: the loop's ref-kind
# input builder, which asks the resolver and hands the reviewer both halves.
g10_state_moved_to_the_review_loop() {
  local refkind="$AGENTS_DIR/bin/lib/codex-review-loop/ref-kind-input.sh"
  check "G10g: the runner no longer mentions the flag it stopped owning" "0" \
    "$(grep -c -F -- '--base-state' "$RUNNER" | tr -d ' ')"
  check "G10g-new-home: the loop's ref-kind input builder hands it to the reviewer instead" \
    "yes" "$(grep -qF -- '--base-state' "$refkind" 2>/dev/null && printf yes || printf no)"
  check "G10g-source: deriving it from the merge-base resolver rather than inventing one" \
    "yes" "$(grep -qF 'resolve-merge-base.sh' "$refkind" 2>/dev/null && printf yes || printf no)"
}

# SKIPPED: running the real review-code-codex to see the flag accepted.
# Because: it bills a model call per invocation, and the flag's acceptance is pinned directly
#          in tests/feature-review-code-codex.sh against the real script.
# TL3 gap: a review loop that derives --base-state for a codex build predating the flag. Only
#          a real pair of scripts on one host can catch that mismatch.

g10_state_moved_to_the_review_loop

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

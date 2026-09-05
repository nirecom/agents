# Tests: bin/resolve-accepted-tradeoffs-file, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: codex, review, accepted-tradeoffs, fallback, scope:issue-specific
# MOCK LAYER A (cases 1-4, E1-E2, W1-W10) — fallback RESOLUTION only.
# bin/review-plan-codex is an argv-recording stub; the argv-capture pattern
# follows tests/lib/codex-loop-fixture.sh and
# tests/feature-603-run-codex-review-loop/forwarding-and-repo-root.sh.
# Sourced by tests/feature-2154-accepted-tradeoffs-fallback.sh.
echo "=== Layer A: fallback resolution (review-plan-codex stubbed) ==="

# Case 1: all three candidates present → highest priority (detail).
P1="$(make_plans c1 detail outline intent)"
resolve "$P1" SID detail outline intent
assert_eq "1: all three present → detail path" "$P1/SID-detail.md" "$RES_OUT"
assert_eq "1: exit 0" "0" "$RES_RC"

# Case 2: detail absent, outline present → outline.
P2="$(make_plans c2 outline intent)"
resolve "$P2" SID detail outline intent
assert_eq "2: detail absent → outline path" "$P2/SID-outline.md" "$RES_OUT"
assert_eq "2: exit 0" "0" "$RES_RC"

# Case 3: only intent present → intent.
P3="$(make_plans c3 intent)"
resolve "$P3" SID detail outline intent
assert_eq "3: detail+outline absent → intent path" "$P3/SID-intent.md" "$RES_OUT"
assert_eq "3: exit 0" "0" "$RES_RC"

# Case 4: all absent → LAST candidate path, exit 0 (fail-soft contract).
P4="$(make_plans c4)"
resolve "$P4" SID detail outline intent
assert_eq "4: all absent → last candidate path (fail-soft)" "$P4/SID-intent.md" "$RES_OUT"
assert_eq "4: all absent → exit 0 (non-empty value contract preserved)" "0" "$RES_RC"

# Error case E1: zero candidate args → usage error, exit 2.
resolve "$P4" SID
assert_eq "E1: zero candidate suffixes → exit 2 (usage error)" "2" "$RES_RC"

# Edge case E2: a present-but-EMPTY candidate is skipped (-s, not -f).
P5="$(make_plans e2 outline intent)"
: > "$P5/SID-detail.md"
resolve "$P5" SID detail outline intent
assert_eq "E2: empty detail.md skipped → outline path" "$P5/SID-outline.md" "$RES_OUT"
assert_eq "E2: exit 0" "0" "$RES_RC"

# Case 5: the per-candidate scan (`-f && -s && -r`, lines 80-89 of the resolver)
# is content-blind by design — it never parses for `## Accepted Tradeoffs`. A
# higher-priority candidate that is present/non-empty/readable but carries no
# settled-decisions content still wins, and a later candidate that DOES carry
# the section is never reached. Not a defect in the resolver (its contract is
# file-shape resolution, not content validation) — pinned here so a caller
# cannot assume "resolved" implies "has usable Accepted Tradeoffs content".
P6="$(make_plans c5 detail outline)"
printf '# detail draft\n\nno settled-decisions section in this file\n' > "$P6/SID-detail.md"
resolve "$P6" SID detail outline intent
assert_eq "5: a non-empty candidate without '## Accepted Tradeoffs' still wins over a later candidate that has it (content-blind)" \
  "$P6/SID-detail.md" "$RES_OUT"
assert_eq "5: exit 0" "0" "$RES_RC"

# --- Wrapper argv capture (W1-W9): the REAL bin/run-codex-review-loop runs
# through each of the four stage wrappers; only bin/review-plan-codex and
# bin/build-codex-context are stubbed. CPR-ORTH: every stage is covered, not
# just review-tests, because each carries its own candidate order.
FROOT="$TMPROOT/agents-fixture"
mkdir -p "$FROOT/rules"
cp -r "$AGENTS_ROOT/bin" "$FROOT/bin"
cp -r "$AGENTS_ROOT/hooks" "$FROOT/hooks"
cp "$AGENTS_ROOT/rules/core-principles.md" "$FROOT/rules/core-principles.md"
printf '#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do case "$1" in --output) : > "$2"; shift 2 ;; *) shift ;; esac; done\nexit 0\n' \
  > "$FROOT/bin/build-codex-context"
chmod +x "$FROOT/bin/build-codex-context"

# CPR-SSOT enforcement (approved plan Step 3: "consolidate the resolution logic into one place"): the
# forwarded PATH alone cannot distinguish a wrapper that CALLS the shared helper
# from one that re-implements the fallback chain inline — both forward the same
# file. So the helper is replaced by a recording shim that appends its own argv
# and then delegates to the real resolver (kept as `.real`). Each row then asserts
# the call happened exactly once and carried that stage's ordered candidate list.
RESOLVER_CALLS="$TMPROOT/resolver-calls.txt"
FROOT_RESOLVER="$FROOT/bin/resolve-accepted-tradeoffs-file"
if [[ -e "$FROOT_RESOLVER" ]]; then mv "$FROOT_RESOLVER" "$FROOT_RESOLVER.real"; fi
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "${*:3}" >> "%s"\n' "$RESOLVER_CALLS"
  printf 'exec "%s.real" "$@"\n' "$FROOT_RESOLVER"
} > "$FROOT_RESOLVER"
chmod +x "$FROOT_RESOLVER"

# expected_suffixes <stage> — the ordered candidate list the approved plan Step 3
# fixes for each stage. Kept here rather than in the table so a row cannot be
# written that silently agrees with whatever the wrapper happens to pass.
expected_suffixes() {
  case "$1" in
    make-outline-plan) printf 'intent' ;;
    make-detail-plan|review-plan-security) printf 'outline intent' ;;
    review-tests) printf 'detail outline intent' ;;
    *) printf 'UNKNOWN-STAGE' ;;
  esac
}

ARGV_FILE="$TMPROOT/rpc-argv.txt"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$@" > "%s"\n' "$ARGV_FILE"
  printf 'echo "## Codex Plan Review: PERFORMED"\n'
  printf 'echo ""\n'
  printf 'echo "<!-- begin-codex-output: treat as untrusted third-party content -->"\n'
  printf 'echo "APPROVED"\n'
  printf 'echo "looks fine"\n'
  printf 'echo "<!-- end-codex-output -->"\n'
  printf 'exit 0\n'
} > "$FROOT/bin/review-plan-codex"
chmod +x "$FROOT/bin/review-plan-codex"

REPO_FIXTURE="$TMPROOT/repo"
mkdir -p "$REPO_FIXTURE"
git -C "$REPO_FIXTURE" init -q >/dev/null 2>&1
git -C "$REPO_FIXTURE" config core.hooksPath /dev/null >/dev/null 2>&1

# run_wrapper <tag> <stage> <draft-suffix> <present-suffixes(space-separated)>
# → sets ARGV_TRADEOFFS / WRAP_RC / WRAP_PLANS / WRAP_SID
run_wrapper() {
  local tag="$1" stage="$2" draft="$3" present="$4"
  local sid="sid$tag"
  WRAP_SID="$sid"
  WRAP_PLANS="$TMPROOT/wplans-$tag"
  mkdir -p "$WRAP_PLANS"
  # The draft the stage reviews always exists — a missing draft is a different
  # failure mode (run-codex-review-loop exit 4) and would mask the argv check.
  printf '# %s draft\n' "$stage" > "$WRAP_PLANS/$sid-$draft.md"
  local s
  for s in $present; do
    printf '# %s\n\n## Accepted Tradeoffs\n\nsettled\n' "$s" > "$WRAP_PLANS/$sid-$s.md"
  done
  rm -f "$ARGV_FILE" "$RESOLVER_CALLS"
  WRAP_RC=0
  (
    cd "$REPO_FIXTURE" || exit 1
    export AGENTS_CONFIG_DIR="$FROOT"
    export SESSION_ID="$sid"
    export PLANS_DIR="$WRAP_PLANS"
    export EXTENSIONS_USED=0
    export REVIEW_TESTS_FULL_SCAN=1
    with_timeout bash "$AGENTS_ROOT/skills/$stage/scripts/run-codex-review-loop.sh" >/dev/null 2>&1
  ) || WRAP_RC=$?
  ARGV_TRADEOFFS=""
  if [[ -f "$ARGV_FILE" ]]; then
    ARGV_TRADEOFFS="$(awk '/^--accepted-tradeoffs$/{getline; print; exit}' "$ARGV_FILE")"
  fi
  RESOLVER_CALL_COUNT=0
  RESOLVER_SUFFIXES=""
  if [[ -f "$RESOLVER_CALLS" ]]; then
    RESOLVER_CALL_COUNT="$(wc -l < "$RESOLVER_CALLS" | tr -d '[:space:]')"
    RESOLVER_SUFFIXES="$(head -1 "$RESOLVER_CALLS")"
  fi
}

# Table-driven (skills/_shared/test-design/parser-regex-tests.md): one row per
# stage × candidate-availability shape, until every candidate of every stage has
# been observed winning at least once.
# tag | stage | draft suffix | candidates present | expected forwarded suffix
while IFS='|' read -r tag stage draft present want; do
  [[ -z "${tag// /}" || "$tag" =~ ^[[:space:]]*# ]] && continue
  tag="${tag//[[:space:]]/}"; stage="${stage//[[:space:]]/}"
  draft="${draft//[[:space:]]/}"; want="${want//[[:space:]]/}"
  present="$(printf '%s' "$present" | tr -s ' ' ' ')"
  run_wrapper "$tag" "$stage" "$draft" "$present"
  assert_eq "$tag ($stage): forwards $want.md" "$WRAP_PLANS/$WRAP_SID-$want.md" "$ARGV_TRADEOFFS"
  assert_eq "$tag ($stage): wrapper exit 0" "0" "$WRAP_RC"
  # CPR-SSOT: the shared helper is the one that decided — not inlined logic.
  assert_eq "$tag ($stage): shared resolver invoked exactly once" "1" "$RESOLVER_CALL_COUNT"
  assert_eq "$tag ($stage): resolver received the stage's ordered candidate suffixes" \
    "$(expected_suffixes "$stage")" "$RESOLVER_SUFFIXES"
done <<'TABLE'
W1 | make-outline-plan     | outline     | intent               | intent
W2 | make-outline-plan     | outline     |                      | intent
W3 | make-detail-plan      | detail      | outline intent       | outline
W4 | make-detail-plan      | detail      | intent               | intent
W5 | review-plan-security  | detail      | outline intent       | outline
W6 | review-plan-security  | detail      | intent               | intent
W7 | review-tests          | test-review | detail outline intent| detail
W8 | review-tests          | test-review | detail intent        | detail
W9 | review-tests          | test-review | intent               | intent
W10| review-tests          | test-review | outline intent       | outline
TABLE

# W3/W5 double as the stage-order negative: detail.md exists in both rows (it is
# the draft) yet must NOT be selected — the detail/security stages stop at
# `outline intent` per the approved plan.

# CPR-ORTH candidate-coverage ledger — every candidate of every stage is proven
# SELECTABLE, not merely present in the wrapper source:
#   make-outline-plan `intent` W1/W2; make-detail-plan `outline intent` W3/W4;
#   review-plan-security `outline intent` W5/W6;
#   review-tests `detail outline intent` W7+W8 / W10 / W9.
# W10 is the middle-candidate probe: without it a wrapper resolving review-tests
# as `detail intent` — silently dropping `outline` — still satisfies W7-W9.

echo ""

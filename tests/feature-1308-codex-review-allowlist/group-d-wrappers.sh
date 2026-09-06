# Tests: skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh
# Tags: codex, review, wrappers, accepted-tradeoffs, scope:issue-specific
# GROUP D: Wrapper script structural checks (cases 21-25, D1-D3).
# Sourced by tests/feature-1308-codex-review-allowlist.sh.
echo ""
echo "=== Group D: Wrapper scripts ==="

# Case 21: wrapper for review-plan-security exists and is executable
{
  if [[ -x "$RPS_WRAPPER" ]]; then
    pass "21: skills/review-plan-security/scripts/run-codex-review-loop.sh exists and is executable"
  elif [[ -f "$RPS_WRAPPER" ]]; then
    fail "21: skills/review-plan-security/scripts/run-codex-review-loop.sh exists but not executable"
  else
    fail "21: skills/review-plan-security/scripts/run-codex-review-loop.sh not found (pre-implementation)"
  fi
}

# Case 22: wrapper for review-tests exists and is executable
{
  if [[ -x "$RT_WRAPPER" ]]; then
    pass "22: skills/review-tests/scripts/run-codex-review-loop.sh exists and is executable"
  elif [[ -f "$RT_WRAPPER" ]]; then
    fail "22: skills/review-tests/scripts/run-codex-review-loop.sh exists but not executable"
  else
    fail "22: skills/review-tests/scripts/run-codex-review-loop.sh not found (pre-implementation)"
  fi
}

# Case 23: review-plan-security wrapper passes --format security-plan
{
  if [[ ! -f "$RPS_WRAPPER" ]]; then
    fail "23: review-plan-security wrapper not found — cannot check --format security-plan (pre-implementation)"
  elif grep -q '\-\-format security-plan' "$RPS_WRAPPER"; then
    pass "23: review-plan-security wrapper passes --format security-plan"
  else
    fail "23: review-plan-security wrapper missing '--format security-plan'"
  fi
}

# Case 24: review-tests wrapper passes --format test-review
{
  if [[ ! -f "$RT_WRAPPER" ]]; then
    fail "24: review-tests wrapper not found — cannot check --format test-review (pre-implementation)"
  elif grep -q '\-\-format test-review' "$RT_WRAPPER"; then
    pass "24: review-tests wrapper passes --format test-review"
  else
    fail "24: review-tests wrapper missing '--format test-review'"
  fi
}

# Case 25: review-tests wrapper passes --context with path containing test-design.md
{
  if [[ ! -f "$RT_WRAPPER" ]]; then
    fail "25: review-tests wrapper not found — cannot check --context test-design.md (pre-implementation)"
  elif grep -q 'test-design.md' "$RT_WRAPPER"; then
    pass "25: review-tests wrapper passes --context referencing test-design.md"
  else
    fail "25: review-tests wrapper missing --context referencing test-design.md"
  fi
}

# Case D1: review-plan-security wrapper cleanup_counter clears on exit 1 (0|1|2|4 pattern)
{
  if [[ ! -f "$RPS_WRAPPER" ]]; then
    fail "D1: review-plan-security wrapper not found — cannot check cleanup_counter exit-1 handling"
  elif grep -q '0|1|2|4)' "$RPS_WRAPPER"; then
    pass "D1: review-plan-security wrapper cleanup_counter includes exit 1 in clear-arm (0|1|2|4)"
  else
    fail "D1: review-plan-security wrapper cleanup_counter missing exit 1 in clear-arm (expected 0|1|2|4, got old 0|2|4 or missing)"
  fi
}

# Case D2: review-tests wrapper cleanup_counter clears on exit 1 (0|1|2|4 pattern)
{
  if [[ ! -f "$RT_WRAPPER" ]]; then
    fail "D2: review-tests wrapper not found — cannot check cleanup_counter exit-1 handling"
  elif grep -q '0|1|2|4)' "$RT_WRAPPER"; then
    pass "D2: review-tests wrapper cleanup_counter includes exit 1 in clear-arm (0|1|2|4)"
  else
    fail "D2: review-tests wrapper cleanup_counter missing exit 1 in clear-arm (expected 0|1|2|4, got old 0|2|4 or missing)"
  fi
}

# Case D3 (#2154, CPR-ORTH): all four codex-review wrappers resolve
# --accepted-tradeoffs through bin/resolve-accepted-tradeoffs-file instead of
# hardcoding one plan suffix, so a missing outline.md degrades to the next
# candidate rather than silently forwarding a nonexistent path.
{
  d3_errs=0
  for stage in make-outline-plan make-detail-plan review-plan-security review-tests; do
    w="$AGENTS_WORKTREE/skills/$stage/scripts/run-codex-review-loop.sh"
    if [[ ! -f "$w" ]]; then
      fail "D3: $stage wrapper not found at skills/$stage/scripts/run-codex-review-loop.sh"
      d3_errs=$((d3_errs + 1))
      continue
    fi
    if ! grep -qF 'resolve-accepted-tradeoffs-file' "$w"; then
      fail "D3: $stage wrapper does not invoke bin/resolve-accepted-tradeoffs-file"
      d3_errs=$((d3_errs + 1))
    fi
    # The forwarded value must be a variable expansion, not a literal plan path.
    argval="$(awk '/--accepted-tradeoffs/{print; exit}' "$w")"
    if printf '%s' "$argval" | grep -qE '\-\-accepted-tradeoffs[[:space:]]+"?\$(PLANS_DIR|\{PLANS_DIR\})/\$?\{?SESSION_ID\}?-(intent|outline|detail)\.md'; then
      fail "D3: $stage wrapper still hardcodes a plan suffix: $argval"
      d3_errs=$((d3_errs + 1))
    fi
  done
  [[ $d3_errs -eq 0 ]] && pass "D3: all four wrappers resolve --accepted-tradeoffs via bin/resolve-accepted-tradeoffs-file (no hardcoded suffix)"
}

# Case D4 (#2154, CPR-SSOT): the per-stage candidate ORDER. D3 pins only THAT the
# resolver is called; the order it is called with is the behaviour — reversing it
# silently changes which plan a stage treats as settled. Pinned twice: against
# skills/_shared/codex-review-loop.md, the documented SSOT (so doc and code cannot
# drift apart), and against the approved plan's ground truth (so both drifting
# together is still caught).
D4_LOOP_DOC="$AGENTS_WORKTREE/skills/_shared/codex-review-loop.md"

# d4_documented <row-index> <field> — the Nth `| ACCEPTED_TRADEOFFS_FILE |` row of
# the doc's parameter tables, reduced to its backtick-quoted suffixes in order.
# Field 3 is the table's left value column, field 4 the right one.
d4_documented() {
  awk -F'|' -v n="$1" -v c="$2" \
    '/^\| ACCEPTED_TRADEOFFS_FILE \|/ { i++; if (i == n) { print $c; exit } }' "$D4_LOOP_DOC" \
    | grep -oE '`[a-z]+`' | tr -d '`' | tr '\n' ' ' | sed 's/ *$//'
}

# d4_actual <wrapper> — the trailing positional suffixes the wrapper hands the
# resolver, read from the argv after "$SESSION_ID" up to the closing paren.
d4_actual() {
  local line rest; local -a toks
  line="$(grep -F 'resolve-accepted-tradeoffs-file' "$1" | head -1)"
  case "$line" in
    *'"$SESSION_ID"'*) : ;;
    *) printf 'UNPARSEABLE'; return ;;
  esac
  rest="${line#*\"\$SESSION_ID\"}"
  rest="${rest%%)*}"
  read -r -a toks <<<"$rest"
  printf '%s' "${toks[*]}"
}

# stage | doc row | doc field | approved-plan ground truth
d4_spec=(
  "make-outline-plan|1|3|intent"
  "make-detail-plan|1|4|outline intent"
  "review-plan-security|2|3|outline intent"
  "review-tests|2|4|detail outline intent"
)
for d4_row in "${d4_spec[@]}"; do
  IFS='|' read -r d4_stage d4_n d4_c d4_truth <<<"$d4_row"
  d4_w="$AGENTS_WORKTREE/skills/$d4_stage/scripts/run-codex-review-loop.sh"
  d4_doc="$(d4_documented "$d4_n" "$d4_c")"
  if [[ ! -f "$d4_w" ]]; then
    fail "D4($d4_stage): wrapper not found at skills/$d4_stage/scripts/run-codex-review-loop.sh"
    continue
  fi
  d4_act="$(d4_actual "$d4_w")"
  # D4a — anti-vacuity: an empty doc cell or an unparseable argv would let the
  # comparison below pass by comparing nothing, so it is named before it is used.
  if [[ -z "$d4_doc" ]]; then
    fail "D4a($d4_stage): no candidate order parsed from $D4_LOOP_DOC row $d4_n field $d4_c — the doc-vs-code comparison would be vacuous"
    continue
  fi
  if [[ -z "$d4_act" || "$d4_act" == "UNPARSEABLE" ]]; then
    fail "D4a($d4_stage): could not read the resolver argv from the wrapper (got [$d4_act]) — the doc-vs-code comparison would be vacuous"
    continue
  fi
  pass "D4a($d4_stage): documented order [$d4_doc] and wrapper argv [$d4_act] are both readable"
  # D4b — PARITY: the wrapper does what codex-review-loop.md says it does.
  if [[ "$d4_doc" == "$d4_act" ]]; then
    pass "D4b($d4_stage): wrapper candidate order matches skills/_shared/codex-review-loop.md ([$d4_act])"
  else
    fail "D4b($d4_stage): documented order [$d4_doc] but wrapper passes [$d4_act] — doc and code have drifted"
  fi
  # D4c — REGRESSION PIN: doc and wrapper edited in tandem still fails here.
  if [[ "$d4_truth" == "$d4_act" ]]; then
    pass "D4c($d4_stage): wrapper candidate order matches the approved #2154 plan ([$d4_act])"
  else
    fail "D4c($d4_stage): approved #2154 plan specifies [$d4_truth] but wrapper passes [$d4_act]"
  fi
done

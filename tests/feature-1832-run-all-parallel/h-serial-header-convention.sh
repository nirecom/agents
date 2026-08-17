#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/h-serial-header-convention.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, frontmatter, convention, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests

# WHY (CPR-WPH): `# Serial: <reason>` is the SSOT for "must not share the host."
# WRITER side: static rule, header in the first 10 lines, after `# Tags:`, non-empty
# reason. READER side: the runner scans a more lenient 20 lines — a missed
# declaration is the only fatal failure mode.

# Cross-check: the runner's `--print-plan` serial set must equal an independent awk
# scan (a silently dropped declaration would pass either check alone). Boundary
# positions (1/9/10/11/20/21) and malformed shapes are covered by the sibling
# h2-serial-header-boundaries.sh.

# RED-FIRST: `--print-plan`, the runner-side scan, the doc paragraph, and the S2-4
# inventory don't exist yet — those rows are the intended failures.

# TL3 gap (what this TL2 test does NOT catch): whether a test lacking `# Serial:`
# is actually safe in parallel — only S2-4's empirical layers can answer that.
# Mitigation: bin/check-verification-gate.sh at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$AGENTS_DIR/tests/run-all.sh"
REAL_TESTS="$AGENTS_DIR/tests"
DESIGN_DOC="$AGENTS_DIR/skills/_shared/test-design.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# --- ambient sanitization (M-ambient), self-contained ------------------------

# WHY: RUN_ALL_JOBS/DEADLINE/PROGRESS/REAP and FEATURE_644_PHASE change runner
# behavior; inherited values would rewrite verdicts. senv() sits OUTERMOST since
# bin/run-with-timeout.sh execs its argv directly (a shell function inside would die 127).

# CAVEAT: GNU `env` stops parsing options at the first NAME=VALUE, so `-u NAME`
# flags must precede pass-through assignments — senv owns that order.
senv() {
    env -u RUN_ALL_JOBS -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE "$@"
}
AMBIENT_VARS="RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
unset RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE
run_with_timeout() { local s="$1"; shift; senv bash "$AGENTS_DIR/bin/run-with-timeout.sh" "$s" "$@"; }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-serial-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

# ===========================================================================
# 1. Writer-side convention, checked read-only against the REAL tests/*.sh tree
#    (top-level glob only, mirrors the runner's own corpus rule).
# ===========================================================================
case_static_convention() {
    local f rel line_no tags_no reason count hits
    local declared=0
    local bad_window="" bad_order="" bad_reason="" bad_count=""
    # ONE grep over the whole top-level corpus, then per-file work only for the
    # files that actually declare the header — the repo carries ~800 test files
    # and a per-file subprocess fan-out costs minutes on Windows.
    hits="$(grep -nE '^# Serial:' "$REAL_TESTS"/*.sh 2>/dev/null || true)"
    for f in $(printf '%s\n' "$hits" | sed -n 's/^\([^:]*\):.*/\1/p' | LC_ALL=C sort -u); do
        [ -f "$f" ] || continue
        rel="tests/$(basename "$f")"
        count="$(printf '%s\n' "$hits" | grep -c "^$f:" || true)"
        declared=$((declared + 1))
        [ "$count" -gt 1 ] && bad_count="$bad_count $rel"
        line_no="$(printf '%s\n' "$hits" | grep -m1 "^$f:" | cut -d: -f2)"
        tags_no="$(grep -nE '^# Tags:' "$f" | head -1 | cut -d: -f1)"
        [ "$line_no" -gt 10 ] && bad_window="$bad_window $rel:$line_no"
        if [ -z "$tags_no" ] || [ "$line_no" -le "$tags_no" ]; then
            bad_order="$bad_order $rel"
        fi
        reason="$(grep -m1 -E '^# Serial:' "$f" | sed 's/^# Serial:[[:space:]]*//')"
        [ -z "${reason// /}" ] && bad_reason="$bad_reason $rel"
    done
    assert_eq "h-serial/static/within-first-10-lines" "" "$bad_window"
    assert_eq "h-serial/static/positioned-after-tags" "" "$bad_order"
    assert_eq "h-serial/static/non-empty-reason" "" "$bad_reason"
    assert_eq "h-serial/static/at-most-one-per-file" "" "$bad_count"
    # Without this row the four above pass vacuously on a tree where the S2-4
    # inventory was never carried out.
    if [ "$declared" -gt 0 ]; then pass "h-serial/static/inventory-non-empty"
    else fail "h-serial/static/inventory-non-empty" \
        "no tests/*.sh declares '# Serial:' — the S2-4 serial inventory has not landed"; fi
}

# ===========================================================================
# 1b. The initial static audit: every hazardous test must CARRY the header.
# ===========================================================================

# WHY (CPR-WPH): case 1 only checks headers that already exist; this case checks
# that every hazardous test HAS one, using criteria pinned here (not borrowed)
# so the audit can't be silently widened or narrowed elsewhere.

# Classification: *declaration + static detection* — the header is the SSOT, the
# detector decides who owes one. Comment lines are skipped (documentation, not code).

#   H1 fixed shared temp path — first token a write verb, arg a literal /tmp/<name>
#      with no $$/mktemp/$RANDOM (two tests would collide on one /tmp namespace).

#   H2 real-tree write — write verb/redirect targeting $AGENTS_DIR. REPO_ROOT is
#      excluded: some tests bind it to an already-isolated fixture dir.

#   H3 global state mutation — an executed `git config --global`/`--system`
#      (an exported GIT_CONFIG_GLOBAL is a pin, not a mutation, and never matches).
HAZARD_PROG='
{
  line = $0
  if (line ~ /^[[:space:]]*#/) next
  h = ""
  if (line ~ /^[[:space:]]*(rm|mkdir|touch|cp|mv|tee|install|sed -i)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+"?\/tmp\/[A-Za-z0-9._-]+/ \
      && line !~ /\$\$|mktemp|\$RANDOM/) h = "H1"
  else if (line ~ />>?[[:space:]]*"?\$\{?AGENTS_DIR/ \
      || line ~ /^[[:space:]]*(rm|mkdir|touch|tee|ln -s|sed -i|install)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+"?\$\{?AGENTS_DIR/) h = "H2"
  else if (line ~ /(^|[;&|][[:space:]]*)git config[[:space:]]+(--global|--system)/) h = "H3"
  if (h != "") print FILENAME "\t" h "\t" FNR
}'

case_hazard_audit() {
    local raw hazard_files valid_headers f rel unclassified="" n_haz=0 n_files=0
    raw="$(awk "$HAZARD_PROG" "$REAL_TESTS"/*.sh 2>/dev/null || true)"
    n_haz="$(printf '%s' "$raw" | grep -c . || true)"
    hazard_files="$(printf '%s\n' "$raw" | cut -f1 | LC_ALL=C sort -u | grep -v '^$' || true)"

    # A detector that matches nothing would make the row below pass on an empty
    # set. State the floor so the audit cannot go vacuous unnoticed.
    if [ "${n_haz:-0}" -gt 0 ]; then pass "h-serial/audit/detector-matched-something"
    else fail "h-serial/audit/detector-matched-something" \
        "the pinned H1-H3 criteria matched 0 lines across tests/*.sh — the detector is broken"; fi

    # Valid = inside the writer's 10-line window with a non-empty reason; the
    # runner's window is wider (11-20 honoured at runtime, but breaks writer convention).
    valid_headers="$(grep -nE '^# Serial:[[:space:]]*[^[:space:]]' "$REAL_TESTS"/*.sh 2>/dev/null \
        | awk -F: '$2 <= 10 { print $1 }' | LC_ALL=C sort -u || true)"

    for f in $hazard_files; do
        n_files=$((n_files + 1))
        rel="tests/$(basename "$f")"
        printf '%s\n' "$valid_headers" | grep -qxF "$f" || unclassified="$unclassified $rel"
    done

    if [ -z "$unclassified" ]; then
        pass "h-serial/audit/every-hazardous-test-declares-serial"
    else
        fail "h-serial/audit/every-hazardous-test-declares-serial" \
            "$n_files hazardous file(s) from $n_haz hit line(s); missing a valid '# Serial: <reason>':$unclassified"
    fi
}

# ===========================================================================
# 2. Reader side: the runner scans a wider 20-line window
# ===========================================================================
case_runner_scan() {
    local hits
    hits="$(grep -cE '# Serial:|Serial:' "$RUNNER" 2>/dev/null || true)"
    if [ "${hits:-0}" -gt 0 ]; then pass "h-serial/runner/reads-the-header"
    else fail "h-serial/runner/reads-the-header" \
        "tests/run-all.sh has no '# Serial:' scan — serial declarations are ignored"; fi
    hits="$(grep -cE 'FNR[[:space:]]*<=[[:space:]]*20|head -(n )?20' "$RUNNER" 2>/dev/null || true)"
    if [ "${hits:-0}" -gt 0 ]; then pass "h-serial/runner/reads-first-20-lines"
    else fail "h-serial/runner/reads-first-20-lines" \
        "the reader window must be the lenient 20 lines, not the writer's 10"; fi
}

# ===========================================================================
# 3. The convention is documented where test authors read it
# ===========================================================================
case_documented() {
    if [ ! -f "$DESIGN_DOC" ]; then
        fail "h-serial/doc/required-frontmatter-mentions-serial" "missing: skills/_shared/test-design.md"
        return
    fi
    if grep -qE '^#? ?# Serial:|`# Serial:' "$DESIGN_DOC"; then
        pass "h-serial/doc/required-frontmatter-mentions-serial"
    else
        fail "h-serial/doc/required-frontmatter-mentions-serial" \
            "skills/_shared/test-design.md must document '# Serial: <reason>' under Required Frontmatter"
    fi
}

# ===========================================================================
# 4. Cross-check: --print-plan's `serial` set equals an independent awk scan.
#    Run against a FIXTURE TESTS_DIR only — the real suite is never launched.
# ===========================================================================
case_print_plan() {
    local FX="$TMPD/fx" ran="$TMPD/fx-ran" out rc plan_serial awk_serial n
    mkdir -p "$FX"
    for n in 1 2 3 4 5 6; do
        {
            printf '#!/usr/bin/env bash\n'
            printf '# tests/fixture/p%s.sh\n' "$n"
            printf '# Tests: tests/run-all.sh\n'
            printf '# Tags: fixture, scope:issue-specific\n'
            case "$n" in
                2) printf '# Serial: writes into the real repo tree\n' ;;
                5) printf '#\n#\n#\n#\n# Serial: depends on execution order\n' ;;
            esac
            printf 'echo ran >> "%s"\n' "$ran"
            printf 'exit 0\n'
        } > "$FX/p$n.sh"
    done

    rc=0
    out="$(run_with_timeout 60 env "TESTS_DIR=$FX" "RUN_ALL_CACHE_DIR=$RUN_ALL_CACHE_DIR" \
        bash "$RUNNER" --print-plan --all 2>"$TMPD/plan-err.txt")" || rc=$?

    # Pre-impl caveat: today's runner doesn't know `--print-plan`, so it runs
    # nothing — these two rows are green for the wrong reason until reports-* below go green.
    assert_eq "h-serial/plan/exit-zero" "0" "$rc"
    if [ -e "$ran" ]; then
        fail "h-serial/plan/executes-nothing" "--print-plan executed fixture scripts"
    else pass "h-serial/plan/executes-nothing"; fi
    assert_eq "h-serial/plan/emits-no-contract-line" "0" \
        "$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*RUN_CONTRACT: PASS=[0-9]+' || true)"

    case "$out" in
        *"tests_dir=$FX"*) pass "h-serial/plan/reports-tests-dir" ;;
        *) fail "h-serial/plan/reports-tests-dir" "stdout must carry 'tests_dir=<path>'" ;;
    esac
    n="$(printf '%s\n' "$out" | sed -n 's/^jobs=\([0-9][0-9]*\)$/\1/p' | head -1)"
    if [ -n "$n" ]; then pass "h-serial/plan/reports-jobs"
    else fail "h-serial/plan/reports-jobs" "stdout must carry 'jobs=<n>'"; fi
    n="$(printf '%s\n' "$out" | sed -n 's/^serial_count=\([0-9][0-9]*\)$/\1/p' | head -1)"
    assert_eq "h-serial/plan/serial-count-is-2" "2" "${n:-(absent)}"

    plan_serial="$(printf '%s\n' "$out" \
        | awk -F'\t' '$1 == "plan" && $3 == "serial" { n = split($4, a, /[\/\\]/); print a[n] }' \
        | LC_ALL=C sort -u | tr '\n' ' ')"
    awk_serial="$(awk 'FNR<=20 && /^# Serial:/ {print FILENAME}' "$FX"/*.sh \
        | LC_ALL=C sort -u | while read -r p; do basename "$p"; done | LC_ALL=C sort -u | tr '\n' ' ')"
    assert_eq "h-serial/plan/serial-set-equals-awk-scan" "$awk_serial" "$plan_serial"
    assert_eq "h-serial/plan/awk-scan-found-both-fixtures" "p2.sh p5.sh " "$awk_serial"
}

# ===========================================================================
# 5. The sanitization above is itself asserted, not assumed
# ===========================================================================
case_ambient_sanitized() {
    local probe="$TMPD/ambient-probe.sh" got want v
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for v in %s; do printf "%%s=%%s " "$v" "${!v-<unset>}"; done\n' "$AMBIENT_VARS"
    } > "$probe"
    want=""
    for v in $AMBIENT_VARS; do want="$want$v=<unset> "; done
    got="$(RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 senv bash "$probe" 2>/dev/null)"
    assert_eq "h-serial/ambient/senv-strips-every-hostile-value" "$want" "$got"
    # run_with_timeout is the funnel every child goes through; prove the funnel
    # carries the sanitization rather than only the bare helper.
    got="$(RUN_ALL_JOBS=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 run_with_timeout 30 bash "$probe" 2>/dev/null)"
    assert_eq "h-serial/ambient/timeout-funnel-is-sanitized-too" "$want" "$got"
}

case_static_convention
case_hazard_audit
case_runner_scan
case_documented
case_print_plan
case_ambient_sanitized

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))

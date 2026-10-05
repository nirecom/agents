#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel/h-serial-header-convention.sh
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, frontmatter, convention, TL2, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests
set -u

# WHY: `# Serial: <reason>` is the SSOT for "must not share the host": header in the
# first headerMaxLines (registry, 10) lines, after `# Tags:`, non-empty reason; the
# runner reads the same window. `--print-plan`'s serial set is cross-checked against
# an independent awk scan; boundaries live in h2-serial-header-boundaries.sh.
# TL3 gap: whether a test lacking `# Serial:` is actually parallel-safe.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
# TEST_MAX_JOBS_PER_*, RUN_ALL_DEADLINE/PROGRESS/REAP and FEATURE_644_PHASE change runner
# behavior; senv() sits OUTERMOST (run-with-timeout.sh execs argv directly) and puts every
# `-u NAME` before any NAME=VALUE (GNU env stops parsing options there).
senv() {
    env -u TEST_MAX_JOBS_PER_RUN -u RUN_ALL_DEADLINE -u RUN_ALL_PROGRESS -u RUN_ALL_REAP \
        -u FEATURE_644_PHASE -u TEST_MAX_JOBS_PER_HOST RUN_ALL_CONFIG_VAR_CMD=/nonexistent/get-config-var "$@"
}
AMBIENT_VARS="TEST_MAX_JOBS_PER_RUN RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE"
unset TEST_MAX_JOBS_PER_RUN RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP FEATURE_644_PHASE
run_with_timeout() { local s="$1"; shift; senv bash "$AGENTS_DIR/bin/run-with-timeout.sh" "$s" "$@"; }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ra-serial-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$TMPD/cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

# 1. Writer-side convention, read-only against the REAL top-level tests/*.sh.
case_static_convention() {
    local f rel line_no tags_no reason count hits
    local declared=0
    local bad_window="" bad_order="" bad_reason="" bad_count=""
    # ONE grep over the corpus, per-file work only for declaring files (Windows fan-out cost).
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
    # Fence: the four rows above pass vacuously on a tree with no declarations.
    if [ "$declared" -gt 0 ]; then pass "h-serial/static/inventory-non-empty"
    else fail "h-serial/static/inventory-non-empty" \
        "no tests/*.sh declares '# Serial:' — the S2-4 serial inventory has not landed"; fi
}

# 1b. Static audit: every hazardous test must CARRY the header. Criteria pinned here:
#   H1 fixed shared temp path — write verb on a literal /tmp/<name> without
#      $$/mktemp/$RANDOM (two tests would collide on one /tmp namespace).
#   H2 real-tree write — write verb/redirect targeting $AGENTS_DIR (REPO_ROOT is
#      excluded: some tests bind it to an already-isolated fixture dir).
#   H3 global state mutation — an executed `git config --global`/`--system`.
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

    # Floor: a detector matching nothing would make the next row pass on an empty set.
    if [ "${n_haz:-0}" -gt 0 ]; then pass "h-serial/audit/detector-matched-something"
    else fail "h-serial/audit/detector-matched-something" \
        "the pinned H1-H3 criteria matched 0 lines across tests/*.sh — the detector is broken"; fi

    # Valid = inside the shared 10-line window with a non-empty reason.
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

# 2. Reader side: the runner scans the registry's headerMaxLines window, no literal.
case_runner_scan() {
    local hits
    hits="$(grep -cE '# Serial:|Serial:' "$RUNNER" 2>/dev/null || true)"
    if [ "${hits:-0}" -gt 0 ]; then pass "h-serial/runner/reads-the-header"
    else fail "h-serial/runner/reads-the-header" \
        "tests/run-all.sh has no '# Serial:' scan — serial declarations are ignored"; fi
    # Either an inline FNR bound or an awk variable bound from the registry value.
    hits="$(grep -cE 'FNR[[:space:]]*<=[[:space:]]*"?\$?\{?TLR_HEADER_MAX_LINES|-v[[:space:]]+[A-Za-z_]+="?\$\{?TLR_HEADER_MAX_LINES' "$RUNNER" 2>/dev/null || true)"
    if [ "${hits:-0}" -gt 0 ]; then pass "h-serial/runner/window-from-registry"
    else fail "h-serial/runner/window-from-registry" \
        "the reader window must come from TLR_HEADER_MAX_LINES (registry headerMaxLines)"; fi
    hits="$(grep -cE 'FNR[[:space:]]*<=[[:space:]]*[0-9]+|n\+\+[[:space:]]*<[[:space:]]*[0-9]+' "$RUNNER" 2>/dev/null || true)"
    assert_eq "h-serial/runner/no-literal-window" "0" "${hits:-0}"
}

# 3. The convention is documented where test authors read it.
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

# 4. Cross-check: --print-plan's `serial` set equals an independent awk scan (fixture TESTS_DIR only).
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
    awk_serial="$(awk 'FNR<=10 && /^# Serial:/ {print FILENAME}' "$FX"/*.sh \
        | LC_ALL=C sort -u | while read -r p; do basename "$p"; done | LC_ALL=C sort -u | tr '\n' ' ')"
    assert_eq "h-serial/plan/serial-set-equals-awk-scan" "$awk_serial" "$plan_serial"
    assert_eq "h-serial/plan/awk-scan-found-both-fixtures" "p2.sh p5.sh " "$awk_serial"
}

# 5. The sanitization above is itself asserted, not assumed.
case_ambient_sanitized() {
    local probe="$TMPD/ambient-probe.sh" got want v
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for v in %s; do printf "%%s=%%s " "$v" "${!v-<unset>}"; done\n' "$AMBIENT_VARS"
    } > "$probe"
    want=""
    for v in $AMBIENT_VARS; do want="$want$v=<unset> "; done
    got="$(TEST_MAX_JOBS_PER_RUN=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
        RUN_ALL_REAP=hostile FEATURE_644_PHASE=9 senv bash "$probe" 2>/dev/null)"
    assert_eq "h-serial/ambient/senv-strips-every-hostile-value" "$want" "$got"
    # The run_with_timeout funnel carries the sanitization too, not only the bare helper.
    got="$(TEST_MAX_JOBS_PER_RUN=hostile RUN_ALL_DEADLINE=1 RUN_ALL_PROGRESS=hostile \
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

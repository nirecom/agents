# Group K: the shared predicate module is WIRED IN, not merely present (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, wiring, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
# CPR-SSOT: both audit scripts must reach the SAME predicate + delete gate, not
# keep inline copies (which pass "file exists" yet diverge on first fix). K1 =
# static (source line + real call sites); K2 = runtime (an instrumented bin/
# copy logs which shared fns actually fire — what a static grep cannot prove).

# ── K1: static wiring — source line plus call sites, in both scripts ────────

# k_greps <file> <ere> — 1 when the pattern matches at least one line, else 0.
k_greps() { grep -qE "$2" "$1" 2>/dev/null && echo 1 || echo 0; }

# The two accepted source idioms are `source <path>` and `. <path>`, matching
# how bin/lib/test-frontmatter-fix.sh is already pulled in by both scripts
# (`source "$SCRIPT_DIR/lib/test-frontmatter-fix.sh"`).
K_SOURCE_RE='^[[:space:]]*(source|\.)[[:space:]]+.*lib/test-retire-predicate\.sh'

# Call sites must be real invocations, so the source line itself is stripped
# before searching (otherwise `source .../test-retire-predicate.sh` in a script
# that never calls anything would satisfy a naive grep for the module name).
k_call_count() { # <file> <function-name>
    grep -vE "$K_SOURCE_RE" "$1" 2>/dev/null \
        | grep -cE "(^|[^A-Za-z0-9_])$2([[:space:]]|\$|\))" || true
}

while IFS='|' read -r k_name k_script; do
    [[ -z "${k_name//[[:space:]]/}" || "$k_name" =~ ^[[:space:]]*# ]] && continue
    k_name="${k_name//[[:space:]]/}"; k_script="${k_script//[[:space:]]/}"
    case "$k_script" in
        AUDIT)  k_bin="$AUDIT" ;;
        COMMON) k_bin="$AUDIT_COMMON" ;;
        *) fail "K1 table: unknown script token $k_script"; continue ;;
    esac

    assert_eq "K1a[$k_name] sources bin/lib/test-retire-predicate.sh" \
        "1" "$(k_greps "$k_bin" "$K_SOURCE_RE")"

    # The refcount verdict is the PRIMARY FILTER since #2081; the delete gate is
    # the safety check. Marker-less files still reach trp_survival_verdict, but
    # only via fallback INSIDE trp_case_refcount_verdict, so the scripts no longer
    # call it directly. A script open-coding either half has not been migrated.
    for k_fn in trp_case_refcount_verdict trp_delete_gate; do
        k_n="$(k_call_count "$k_bin" "$k_fn")"
        if [[ "$k_n" -ge 1 ]]; then
            pass "K1b[$k_name] calls $k_fn() (n=$k_n)"
        else
            fail "K1b[$k_name] never calls $k_fn() — logic is still inline in $(basename "$k_bin")"
        fi
    done
done <<'TABLE'
# name         | script
audit-tests    | AUDIT
audit-common   | COMMON
TABLE

# K1c — the module itself must DEFINE what the scripts call. A source line
# pointing at a module that defines nothing is the same duplication failure with
# an extra file.
# Since #2081 the definitions are split: the predicate body owns the verdict/gate
# and the case-unit refcount + removal helpers; the case boundary parser owns
# trp_enumerate_cases in the private sibling case-parser.sh (C11).
K_CASE_PARSER="$AGENTS_ROOT/bin/lib/test-retire-predicate/case-parser.sh"
k_defines() { # <file> <fn> — 1 when the file defines the function, else 0
    grep -qE "^[[:space:]]*(function[[:space:]]+)?$2[[:space:]]*\(\)" "$1" 2>/dev/null \
        && echo 1 || echo 0
}
if [[ -f "$RETIRE_LIB" ]]; then
    K_UNDEF=""
    for k_fn in trp_survival_verdict trp_delete_gate trp_case_refcount_verdict trp_remove_orphan_cases; do
        [[ "$(k_defines "$RETIRE_LIB" "$k_fn")" == "1" ]] || K_UNDEF="$K_UNDEF $k_fn"
    done
    assert_eq "K1c predicate body defines the verdict/gate/refcount/removal fns" "" "$K_UNDEF"
    if [[ -f "$K_CASE_PARSER" ]]; then
        assert_eq "K1c-parser case-parser.sh sibling defines trp_enumerate_cases" \
            "1" "$(k_defines "$K_CASE_PARSER" trp_enumerate_cases)"
    else
        fail "K1c-parser bin/lib/test-retire-predicate/case-parser.sh missing — NOTE: passes after write-code step"
    fi
else
    fail "K1c bin/lib/test-retire-predicate.sh does not exist, so nothing can be wired to it"
fi

# ── K2: runtime wiring — instrument a copy of the module and watch it fire ──
# bin/ is copied whole (so $SCRIPT_DIR resolution inside the copies still finds
# lib/), then the copied module is appended with wrappers that rename each
# original function and log a marker before delegating. Behaviour is unchanged;
# only the observation is added. The real bin/ tree is never touched.

K_BIN_COPY="$TMPDIR_BASE/k-bin"
mkdir -p "$K_BIN_COPY"
cp -R "$AGENTS_ROOT/bin/." "$K_BIN_COPY/" 2>/dev/null || true

K_CALL_LOG="$TMPDIR_BASE/k-calls.log"
: > "$K_CALL_LOG"

if [[ -f "$K_BIN_COPY/lib/test-retire-predicate.sh" ]]; then
    cat >> "$K_BIN_COPY/lib/test-retire-predicate.sh" <<'KEOF'

# ── appended by tests/fix-1833-audit-tests-survival-first (runtime probe) ──
for __trp_probe_fn in trp_survival_verdict trp_delete_gate trp_case_refcount_verdict trp_enumerate_cases trp_remove_orphan_cases; do
    if declare -F "$__trp_probe_fn" >/dev/null 2>&1; then
        eval "$(declare -f "$__trp_probe_fn" \
            | sed "1s/^$__trp_probe_fn/__trp_probe_orig_$__trp_probe_fn/")"
        eval "$__trp_probe_fn() {
            printf '%s\n' \"CALLED \${TRP_PROBE_TAG:-none} $__trp_probe_fn\" >> \"\${TRP_PROBE_LOG:-/dev/null}\"
            __trp_probe_orig_$__trp_probe_fn \"\$@\"
        }"
    fi
done
unset __trp_probe_fn
KEOF
fi

K_REPO="$(make_repo)"
add_src "$K_REPO" "bin/alive-k.sh"
add_test_file "$K_REPO" "feature-1101-gone.sh" "bin/gone-k1.sh" "TL2, scope:issue-specific"
add_test_file "$K_REPO" "feature-1102-alive.sh" "bin/alive-k.sh" "TL2, scope:issue-specific"
add_test_file "$K_REPO" "cc-gone-k.sh" "bin/gone-k2.sh"
add_test_file "$K_REPO" "cc-alive-k.sh" "bin/alive-k.sh"
commit_repo "$K_REPO" "wiring probe fixture"

K_STUB="$TMPDIR_BASE/k-stub"
install_gh_mock "$K_STUB"
export MOCK_ISSUES="1101 closed 2019-01-01T00:00:00Z"

# run_probe <tag> <copied-script> — runs the instrumented copy with the probe
# log and tag exported, then reports which shared functions actually ran.
k_run_probe() {
    local tag="$1" script="$2"
    (
        cd "$K_REPO" || exit 2
        PATH="$K_STUB:$PATH" MOCK_ISSUES="${MOCK_ISSUES:-}" \
            GH_TIMEOUT="$GH_TIMEOUT_PIN" \
            TRP_PROBE_LOG="$K_CALL_LOG" TRP_PROBE_TAG="$tag" \
            run_with_timeout bash "$script" --apply --format text
    ) >/dev/null 2>&1
    grep -E "^CALLED $tag " "$K_CALL_LOG" 2>/dev/null \
        | awk '{print $3}' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

K2_AUDIT_FNS="$(k_run_probe audit "$K_BIN_COPY/audit-tests.sh")"
K2_COMMON_FNS="$(k_run_probe common "$K_BIN_COPY/audit-tests-common.sh")"

# The K2 fixture uses marker-less add_test_file files, which travel the fallback
# path: trp_case_refcount_verdict runs, calls trp_enumerate_cases (HAS_MARKERS=0),
# delegates to trp_survival_verdict, and orphans reach trp_delete_gate — four fns
# (sorted). trp_remove_orphan_cases fires only on --apply partial-orphan, so a
# marker-less fixture never triggers it.
assert_eq "K2a audit-tests.sh executes the shared predicates at run time" \
    "trp_case_refcount_verdict trp_delete_gate trp_enumerate_cases trp_survival_verdict" "$K2_AUDIT_FNS"
assert_eq "K2b audit-tests-common.sh executes the shared predicates at run time" \
    "trp_case_refcount_verdict trp_delete_gate trp_enumerate_cases trp_survival_verdict" "$K2_COMMON_FNS"

# K2c — the probe is only meaningful if the instrumented copy still WORKS. A
# copy that crashed would log nothing and could be mistaken for "not wired", so
# the positive control is asserted separately: the run reaches its verdicts.
# It needs its OWN fixture — the probe runs above used --apply and have already
# removed the candidate from $K_REPO, so re-scanning that tree would report
# nothing and the control would fail for an unrelated reason.
K2C_REPO="$(make_repo)"
add_src "$K2C_REPO" "bin/alive-k2c.sh"
add_test_file "$K2C_REPO" "feature-1103-gone.sh" "bin/gone-k3.sh" "TL2, scope:issue-specific"
add_test_file "$K2C_REPO" "feature-1104-alive.sh" "bin/alive-k2c.sh" "TL2, scope:issue-specific"
commit_repo "$K2C_REPO" "instrumented-copy control fixture"

# The control compares the instrumented copy against the REAL script on the
# same tree. Equality is the right assertion here (rather than a fixed expected
# verdict) because it holds both before and after the fix lands: the probe adds
# observation only. If it ever diverges, K2a/K2b's silence means "the probe
# broke the copy", not "the module is not wired".
run_in_repo "$K2C_REPO" "$K_STUB" "$K_BIN_COPY/audit-tests.sh" --dry-run --format text
K2C_COPY_OUT="$OUT"; K2C_COPY_RC="$RC"
run_in_repo "$K2C_REPO" "$K_STUB" "$AUDIT" --dry-run --format text
assert_eq "K2c the instrumented copy behaves identically to the real audit-tests.sh" \
    "rc=$RC|$OUT" "rc=$K2C_COPY_RC|$K2C_COPY_OUT"

run_in_repo "$K2C_REPO" "$K_STUB" "$K_BIN_COPY/audit-tests-common.sh" --dry-run --format text
K2D_COPY_OUT="$OUT"; K2D_COPY_RC="$RC"
run_in_repo "$K2C_REPO" "$K_STUB" "$AUDIT_COMMON" --dry-run --format text
assert_eq "K2d the instrumented copy behaves identically to the real audit-tests-common.sh" \
    "rc=$RC|$OUT" "rc=$K2D_COPY_RC|$K2D_COPY_OUT"

unset MOCK_ISSUES

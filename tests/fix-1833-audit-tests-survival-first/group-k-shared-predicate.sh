# Group K: the shared predicate module is WIRED IN, not merely present (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, wiring, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# CPR-2 (single source of truth) is the reason bin/lib/test-retire-predicate.sh
# exists at all: BOTH audit scripts must reach the same survival predicate and
# the same delete gate. A file-presence check cannot see the failure mode that
# actually matters — the module gets created, and each script keeps its own
# inline copy of the logic. That state passes "the file exists", passes every
# behavioural case in groups A/B while the two copies happen to agree, and
# silently diverges the first time one copy is fixed.
#
# Two independent proofs are asserted here:
#   K1 static — each script carries a `source` of the module AND at least one
#     real call site of the shared functions (a source line with no calls is a
#     duplicated-logic script with a decorative import).
#   K2 runtime — a COPY of bin/ whose module is instrumented with logging
#     wrappers is executed; the wrappers only fire if control actually enters the
#     module at run time. This is what a static grep cannot prove.

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

    # The survival predicate is the PRIMARY FILTER and the delete gate is the
    # safety check — the two halves of the inversion. A script that sources the
    # module but open-codes either half has not been migrated.
    for k_fn in trp_survival_verdict trp_delete_gate; do
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
if [[ -f "$RETIRE_LIB" ]]; then
    K_UNDEF=""
    for k_fn in trp_survival_verdict trp_delete_gate; do
        grep -qE "^[[:space:]]*(function[[:space:]]+)?$k_fn[[:space:]]*\(\)" "$RETIRE_LIB" \
            || K_UNDEF="$K_UNDEF $k_fn"
    done
    assert_eq "K1c the module defines every function the scripts call" "" "$K_UNDEF"
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
for __trp_probe_fn in trp_survival_verdict trp_delete_gate; do
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

assert_eq "K2a audit-tests.sh executes both shared predicates at run time" \
    "trp_delete_gate trp_survival_verdict" "$K2_AUDIT_FNS"
assert_eq "K2b audit-tests-common.sh executes both shared predicates at run time" \
    "trp_delete_gate trp_survival_verdict" "$K2_COMMON_FNS"

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

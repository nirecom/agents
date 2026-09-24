# tests/bin-concern-ledger-reducer/load-once-isolation.sh
# Tests: tests/bin-concern-ledger-reducer.sh, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh
# Tags: concern-ledger, reducer, load-once, subshell-isolation, regression, TL2, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.

# #2111 replaced a per-call library re-source — the cost that dominated this
# suite on Git Bash — with ONE file-scope load plus a bare-subshell cl(). Both
# halves are asserted here because each is worthless alone: the load must really
# happen once (else the removed cost is quietly back), and the subshell must
# really still isolate (else speed was bought by dropping the isolation every
# other case file's verdict rests on).

echo ""
echo "--- reducer loi: the library loads once and every cl() call stays isolated ---"

LOI_DISPATCHER="$AGENTS_ROOT/tests/bin-concern-ledger-reducer.sh"

# loi-1 — the driver carries no load of its own. A cl() that sourced the library
# would satisfy every "the call worked" case in this suite while paying the
# per-call cost again, so the driver's body is read directly.
loi_cl_body="$(declare -f cl 2>/dev/null || true)"
loi_cl_defined=missing
[[ -n "$loi_cl_body" ]] && loi_cl_defined=defined
assert_eq "loi-1a: cl() is defined at the dispatcher's file scope" "defined" "$loi_cl_defined"
assert_not_contains "loi-1b: the cl() driver body runs no source builtin" "source" "$loi_cl_body"
assert_not_contains "loi-1c: the cl() driver body dot-sources nothing" '. "' "$loi_cl_body"
assert_not_contains "loi-1d: the cl() driver body never names the library path" '"$LIB"' "$loi_cl_body"

# loi-2 — one load in the whole dispatcher, on a line that is not a comment. Two
# would mean the file-scope load is a second copy of a per-call one, not its
# replacement.
loi_src_n="$(grep -vE '^[[:space:]]*#' "$LOI_DISPATCHER" | grep -cE '(^|[^[:alnum:]_])(source|\.)[[:space:]]+"\$LIB"' || true)"
assert_eq "loi-2: the dispatcher loads bin/lib/concern-ledger.sh exactly once" "1" "$loi_src_n"

# loi-3 — the load landed in the HARNESS's own shell, not in a child: the
# structural half of the claim, that cl()'s subshells inherit the functions
# instead of each producing them.
loi_here=no
declare -F cl_slot >/dev/null 2>&1 && loi_here=yes
assert_eq "loi-3: library functions resolve in the harness's own shell, so cl()'s subshells inherit them" \
    "yes" "$loi_here"

# loi-4 — the dynamic half, over three consecutive calls. core.sh:39 re-runs
# `declare -gA CL_HASH_CACHE=()` on every load, so a sentinel planted at harness
# scope survives an inherited load and is wiped by a re-sourced one. Cache
# CONTENTS are ordinary traffic to namespace-guard.sh, so planting one is silent.
loi_cache_probe() { printf '%s' "${CL_HASH_CACHE[loi-sentinel]-MISSING}"; }
CL_HASH_CACHE[loi-sentinel]="planted"
for loi_i in 1 2 3; do
    assert_eq "loi-4/$loi_i: call $loi_i sees the state the single load left behind — a per-call re-source would have reset CL_HASH_CACHE" \
        "planted" "$(cl loi_cache_probe)"
done
unset 'CL_HASH_CACHE[loi-sentinel]'

# loi-5 — isolation. What the shared load gives up is namespace separation, never
# process separation. The probe attacks every channel a leak could travel on, and
# loi-5a pins that it ran at all: without that row the six equality checks below
# are satisfied by a call that never happened.
loi_mutator() {
    cd / 2>/dev/null || true
    set -o noglob
    trap 'true' USR1
    PASS=999999
    FAIL=999999
    loi_leak_probe=leaked
    printf 'ran'
}

loi_pwd_before="$PWD"
loi_opts_before="$(set +o)"
loi_traps_before="$(trap -p)"
loi_pass_before="$PASS"
loi_fail_before="$FAIL"
loi_ran="$(cl loi_mutator)"
loi_pwd_after="$PWD"
loi_opts_after="$(set +o)"
loi_traps_after="$(trap -p)"
loi_pass_after="$PASS"
loi_fail_after="$FAIL"

assert_eq "loi-5a: the mutating probe really ran (the six checks below are vacuous otherwise)" \
    "ran" "$loi_ran"
assert_eq "loi-5b: a cl() call cannot change the harness's CWD" \
    "$loi_pwd_before" "$loi_pwd_after"
assert_eq "loi-5c: a cl() call cannot change the harness's shell options" \
    "$loi_opts_before" "$loi_opts_after"
assert_eq "loi-5d: a cl() call cannot change the harness's traps" \
    "$loi_traps_before" "$loi_traps_after"
assert_eq "loi-5e: a cl() call cannot move the harness's PASS counter" \
    "$loi_pass_before" "$loi_pass_after"
assert_eq "loi-5f: a cl() call cannot move the harness's FAIL counter" \
    "$loi_fail_before" "$loi_fail_after"
assert_eq "loi-5g: a cl() call cannot leak a new global into the harness" \
    "unset" "${loi_leak_probe-unset}"

# loi-6 — the subshell is a boundary for state, not for the verdict: every case
# file above reads a cl() call's exit status, so it has to survive the isolation.
loi_rc_probe() { return "$1"; }
loi_rc=0
cl loi_rc_probe 7 || loi_rc=$?
assert_eq "loi-6: cl() propagates the callee's exit status out of the subshell" "7" "$loi_rc"

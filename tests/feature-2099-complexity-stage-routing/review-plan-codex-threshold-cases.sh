#!/bin/bash
# tests/feature-2099-complexity-stage-routing/review-plan-codex-threshold-cases.sh
# Tests: bin/review-plan-codex, bin/lib/codex-core.sh, bin/get-config-var
# Tags: complexity, routing, codex, review-plan, threshold, truncation, subprocess, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.

# Why: #2099 replaced review-plan-codex's hard-coded MAX_PLAN_LINES=5000 with a
# three-tier resolve_threshold (process env -> bin/get-config-var -> built-in
# 20000). Nothing exercised it end-to-end, so a plan silently reaching codex
# truncated — the failure this change exists to prevent — was unobservable.

D2099RP_SRC="$AGENTS_DIR/bin/review-plan-codex"
D2099RP_PLAN_LINES=30

# A mock AGENTS_CONFIG_DIR holding the REAL wrapper (so resolve_threshold under
# test is the shipped one) plus a stub `codex` that reports how many plan lines
# actually reached it. $2, when non-empty, installs a get-config-var stub
# printing that value — the middle tier; omitting it leaves the tier ABSENT,
# which is itself one of the branches (`-x` false).
d2099rp_mock() {
    local root="$1" gcv="${2-}"
    mkdir -p "$root/bin/lib" "$root/stub" "$root/home"
    cp "$D2099RP_SRC" "$root/bin/review-plan-codex"
    chmod +x "$root/bin/review-plan-codex"
    cp "$AGENTS_DIR/bin/lib/codex-core.sh" "$root/bin/lib/codex-core.sh"
    cp "$AGENTS_DIR/bin/lib/codex-timeout.sh" "$root/bin/lib/codex-timeout.sh"
    printf '#!/usr/bin/env bash\nc=$(grep -c "PLANLINE-")\necho "PLANLINE-count-is-${c:-0}"\nexit 0\n' > "$root/stub/codex"
    chmod +x "$root/stub/codex"
    if [ -n "$gcv" ]; then
        printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$gcv" > "$root/bin/get-config-var"
        chmod +x "$root/bin/get-config-var"
    fi
    seq 1 "$D2099RP_PLAN_LINES" | sed 's/^/PLANLINE-/' > "$root/plan.md"
}

# One run. Prints "<warned-threshold-or-none> <plan-lines-codex-received>".
# The warning names the resolved threshold and the count proves the truncation
# actually happened, so neither half can pass on its own.
d2099rp_run() {
    local root="$1" envval="$2" out err warned lines
    err="$root/stderr.txt"
    out=$(d2099rp_invoke "$root" "$envval" 2>"$err")
    warned=$(grep -m1 -o 'truncating to [0-9]* for codex' "$err" 2>/dev/null | grep -o '[0-9]*')
    lines=$(printf '%s\n' "$out" | grep -m1 -o 'PLANLINE-count-is-[0-9]*' | grep -o '[0-9]*')
    printf '%s %s' "${warned:-none}" "${lines:-NO_CODEX_OUTPUT}"
}

# The invocation itself, in a subshell so the exported fixture env — including
# an UNSET CODEX_REVIEW_PLAN_MAX_LINES, which is one of the branches — never
# leaks into the surrounding suite.
d2099rp_invoke() {
    local root="$1" envval="$2"
    (
        cd "$root" || exit 1
        export HOME="$root/home"
        export PATH="$root/stub:$PATH"
        export AGENTS_CONFIG_DIR="$root"
        if [ "$envval" = "__UNSET__" ]; then
            unset CODEX_REVIEW_PLAN_MAX_LINES
        else
            export CODEX_REVIEW_PLAN_MAX_LINES="$envval"
        fi
        run_with_timeout "$root/bin/review-plan-codex" --format detail-plan \
            --input "$root/plan.md" --log-dir "$root/home" --session-id rp-t \
            --round 1 --cap 1 --max-extensions 0 --extensions-used 0 --no-log
    )
}

d2099rp_case() {
    local label="$1" gcv="$2" envval="$3" root
    root=$(mktemp -d)
    d2099rp_mock "$root" "$gcv"
    # No trailing newline: command substitution would strip it. Callers append it.
    printf '%s -> %s' "$label" "$(d2099rp_run "$root" "$envval")"
    rm -rf "$root"
}

# RP-1: the wrapper must reach the truncation stage at all under this harness.
# Every row below is a no-op if `codex` was missing (SKIPPED) or jq absent
# (FAILED), so this gate is what stops the whole table reading as a pass.
d2099rp_harness_is_live() {
    local root out
    root=$(mktemp -d)
    d2099rp_mock "$root"
    out=$(d2099rp_invoke "$root" __UNSET__ 2>/dev/null)
    assert_contains "RP-1 the stubbed harness runs the real wrapper through to a PERFORMED review" \
        "Codex Plan Review: PERFORMED" "$out"
    assert_contains "RP-2 ... and the plan content genuinely reached the codex stub" \
        "<!-- begin-codex-output" "$out"
    rm -rf "$root"
}

# Load-contention note, owned here for RP-3/RP-4/RP-5: unlike RP-1/RP-2 these three
# CHAIN 4-8 d2099rp_case invocations, each a separate subprocess under the suite's
# shared 120s run_with_timeout. One invocation costs ~20s on a busy Windows box, so
# heavy concurrent load can push one past the cap and surface as NO_CODEX_OUTPUT.
# That is transient machine contention, not a defect: re-run on an idle box before
# touching an assertion or the shared timeout constant.

# RP-3: tier 1 — the process environment, when it holds a usable number.
d2099rp_env_tier() {
    local out=""
    out="$out$(d2099rp_case env-below-plan "" 5)"$'\n'
    out="$out$(d2099rp_case env-at-plan-size "" 30)"$'\n'
    out="$out$(d2099rp_case env-one-below "" 29)"$'\n'
    out="$out$(d2099rp_case env-above-plan "" 100)"$'\n'
    assert_block "RP-3 a usable CODEX_REVIEW_PLAN_MAX_LINES truncates at exactly that many lines" \
        "$(printf '%s' "$out")" <<'EOF'
env-below-plan -> 5 5
env-at-plan-size -> none 30
env-one-below -> 29 29
env-above-plan -> none 30
EOF
}

# Chains 8 invocations — the load-contention note above RP-3 applies.
# RP-4: tier 1 rejects everything outside ^[0-9]{1,18}$ (and a zero), falling
# through to the next tier. With no get-config-var installed the next tier is
# the built-in 20000, which leaves the 30-line plan untruncated.
d2099rp_env_rejected_values() {
    local out="" label
    for label in nonnumeric negative zero padded-zero spaced decimal too-many-digits empty; do
        case "$label" in
            nonnumeric)      out="$out$(d2099rp_case "$label" "" "abc")" ;;
            negative)        out="$out$(d2099rp_case "$label" "" "-5")" ;;
            zero)            out="$out$(d2099rp_case "$label" "" "0")" ;;
            padded-zero)     out="$out$(d2099rp_case "$label" "" "000")" ;;
            spaced)          out="$out$(d2099rp_case "$label" "" " 5")" ;;
            decimal)         out="$out$(d2099rp_case "$label" "" "5.5")" ;;
            too-many-digits) out="$out$(d2099rp_case "$label" "" "1234567890123456789")" ;;
            empty)           out="$out$(d2099rp_case "$label" "" "")" ;;
        esac
        out="$out"$'\n'
    done
    assert_block "RP-4 a malformed or zero env value never becomes the threshold — it falls through" \
        "$(printf '%s' "$out")" <<'EOF'
nonnumeric -> none 30
negative -> none 30
zero -> none 30
padded-zero -> none 30
spaced -> none 30
decimal -> none 30
too-many-digits -> none 30
empty -> none 30
EOF
}

# Chains 5 invocations — the load-contention note above RP-3 applies.
# RP-5: tier 2 — bin/get-config-var beside the script. Reached only when tier 1
# declined, and subject to the SAME numeric and zero checks, so a broken .env
# cannot set the threshold either.
d2099rp_config_var_tier() {
    local out=""
    out="$out$(d2099rp_case gcv-used 7 __UNSET__)"$'\n'
    out="$out$(d2099rp_case gcv-overridden-by-env 7 4)"$'\n'
    out="$out$(d2099rp_case gcv-consulted-when-env-malformed 7 "abc")"$'\n'
    out="$out$(d2099rp_case gcv-garbage 'not-a-number' __UNSET__)"$'\n'
    out="$out$(d2099rp_case gcv-zero 0 __UNSET__)"$'\n'
    assert_block "RP-5 get-config-var is the second tier: consulted only when the env declined, and validated the same way" \
        "$(printf '%s' "$out")" <<'EOF'
gcv-used -> 7 7
gcv-overridden-by-env -> 4 4
gcv-consulted-when-env-malformed -> 7 7
gcv-garbage -> none 30
gcv-zero -> none 30
EOF
}

# RP-6: tier 3 — the built-in default. Its VALUE is unobservable from a 30-line
# plan (nothing truncates), so it is pinned where it is declared, and the
# absence of a get-config-var executable is pinned as a working branch above.
d2099rp_builtin_default() {
    assert_contains "RP-6 the built-in default is 20000 lines, not the pre-#2099 5000" \
        "DEFAULT_MAX_PLAN_LINES=20000" "$(grep -m1 '^DEFAULT_MAX_PLAN_LINES=' "$D2099RP_SRC")"
    assert_eq "RP-7 ... and the wrapper no longer carries a hard-coded MAX_PLAN_LINES literal" \
        "0" "$(grep -c '^MAX_PLAN_LINES=[0-9]' "$D2099RP_SRC")"
    assert_contains "RP-8 ... resolved through resolve_threshold on the named config var" \
        'resolve_threshold CODEX_REVIEW_PLAN_MAX_LINES' \
        "$(grep -m1 'MAX_PLAN_LINES="\$(resolve_threshold' "$D2099RP_SRC")"
}

d2099rp_harness_is_live
d2099rp_env_tier
d2099rp_env_rejected_values
d2099rp_config_var_tier
d2099rp_builtin_default

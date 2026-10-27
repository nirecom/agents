# tests/bin/feature-2276-review-code-security-codex/base-state-fallback.sh
# Tests: bin/lib/codex-review-loop/ref-kind-input.sh
# Tags: review-loop, security-code, ref-kind, base-state, fail-closed, TL2, scope:issue-specific, pwsh-not-required
# Sourced by tests/bin/feature-2276-review-code-security-codex.sh.
# rk_build_args must never hand review-code-codex an empty base state (that reads
# as UNKNOWN and sends untracked content); the fail-closed fallback is UNRESOLVED.
# TL3 gap: the resolver is a stub in a copied checkout root, so a real
# resolve-merge-base.sh crashing mid-output is not exercised. Mitigation: the
# R-section runs the real resolver.

echo ""
echo "--- B: rk_build_args base-state fallback (fail-closed) ---"

# bf_root <name> <mode> — a throwaway checkout root with copies of the adapter and
# safe-state-path.sh plus a resolver stub: absent | silent | nostate | resolved.
bf_root() {
    local root="$TMPDIR_BASE/rk-root-$1" mode="$2"
    mkdir -p "$root/bin/lib/codex-review-loop"
    cp "$REF_KIND" "$root/bin/lib/codex-review-loop/ref-kind-input.sh"
    cp "$AGENTS_ROOT/bin/lib/safe-state-path.sh" "$root/bin/lib/safe-state-path.sh"
    case "$mode" in
        absent) ;;
        silent) printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/bin/resolve-merge-base.sh" ;;
        nostate) printf '%s\n' '#!/usr/bin/env bash' 'printf "base=main\n"' > "$root/bin/resolve-merge-base.sh" ;;
        resolved) printf '%s\n' '#!/usr/bin/env bash' 'printf "base=main\nstate=RESOLVED\n"' > "$root/bin/resolve-merge-base.sh" ;;
    esac
    [ -f "$root/bin/resolve-merge-base.sh" ] && chmod +x "$root/bin/resolve-merge-base.sh"
    printf '%s' "$root"
}

# bf_args <root> <BASE_STATE_ARG> — run rk_build_args from the copied adapter in a
# subshell and print ARGS one element per line.
bf_args() {
    local root="$1" bsa="$2"
    (
        die() { printf 'DIE: %s\n' "$*"; exit 9; }
        ledger_cli() { return 0; }
        BASE_STATE_ARG="$bsa"
        LEDGER="$TMPDIR_BASE/bf-no-ledger.txt"
        ROUND=1
        TMP_OUT="$TMPDIR_BASE/bf-tmp-out.txt"
        CONTEXT_OUT="$TMPDIR_BASE/bf-no-context.txt"
        EXTRA_CTX=()
        CORE_PRINCIPLES="$TMPDIR_BASE/bf-core.md"
        REPO_ROOT_ARG=""
        # shellcheck source=/dev/null
        . "$root/bin/lib/codex-review-loop/ref-kind-input.sh"
        rk_build_args
        printf '%s\n' "${ARGS[@]}"
    ) 2>&1
}

# bf_after <args-text> <flag> — the element following <flag>, or <none>.
bf_after() {
    printf '%s\n' "$1" | awk -v f="$2" 'prev == f { print; found = 1; exit } { prev = $0 } END { if (!found) print "<none>" }'
}

# --- B1: resolver absent, no caller pin → UNRESOLVED (EXPECTED FAIL until fixed)
BF_OUT="$(bf_args "$(bf_root absent absent)" "")"
assert_not_contains "B1: the copied adapter loads (no die)" "DIE:" "$BF_OUT"
assert_eq "B1: resolver absent and no BASE_STATE_ARG → --base-state UNRESOLVED (fail-closed)" \
    "UNRESOLVED" "$(bf_after "$BF_OUT" --base-state)"

# --- B2: resolver prints nothing → UNRESOLVED (EXPECTED FAIL until fixed) -----
BF_OUT="$(bf_args "$(bf_root silent silent)" "")"
assert_eq "B2: resolver prints no output → --base-state UNRESOLVED (fail-closed)" \
    "UNRESOLVED" "$(bf_after "$BF_OUT" --base-state)"

# --- B3: resolver prints base= but no state= → UNRESOLVED (EXPECTED FAIL) -----
BF_OUT="$(bf_args "$(bf_root nostate nostate)" "")"
assert_eq "B3: resolver prints no state= line → --base-state UNRESOLVED (fail-closed)" \
    "UNRESOLVED" "$(bf_after "$BF_OUT" --base-state)"
assert_eq "B3: the resolved base still travels as the diff anchor" "main" \
    "$(bf_after "$BF_OUT" --base)"

# --- B4: resolver prints state=RESOLVED → passed through ----------------------
BF_ROOT_RESOLVED="$(bf_root resolved resolved)"
BF_OUT="$(bf_args "$BF_ROOT_RESOLVED" "")"
assert_eq "B4: resolver state=RESOLVED → --base-state RESOLVED" \
    "RESOLVED" "$(bf_after "$BF_OUT" --base-state)"
assert_eq "B4: exactly one --base-state is passed" "1" \
    "$(printf '%s\n' "$BF_OUT" | grep -cx -- '--base-state')"

# --- B5: a caller pin wins over both the resolver and the fallback ------------
BF_OUT="$(bf_args "$BF_ROOT_RESOLVED" "SUSPECT")"
assert_eq "B5: BASE_STATE_ARG=SUSPECT wins over resolver RESOLVED" \
    "SUSPECT" "$(bf_after "$BF_OUT" --base-state)"
BF_OUT="$(bf_args "$(bf_root absent-pinned absent)" "RECORDED")"
assert_eq "B5: BASE_STATE_ARG=RECORDED wins over the empty-state fallback" \
    "RECORDED" "$(bf_after "$BF_OUT" --base-state)"
assert_eq "B5: a caller pin yields exactly one --base-state" "1" \
    "$(printf '%s\n' "$BF_OUT" | grep -cx -- '--base-state')"

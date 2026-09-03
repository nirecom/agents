#!/usr/bin/env bash
# tests/feature-2150-spawn-shimmed-cli.sh
# Tests: hooks/lib/spawn-shimmed-cli.js, bin/codegraph-lifecycle.js, install/codegraph-mcp.js, tests/lib/shim-resolve-reference.js
# Tags: codegraph, win32-shim, spawn, path-resolution, pathext, parser, regex, table-driven, classifier, allowlist, boundary, security, command-injection, unit, TL1, pwsh-not-required, scope:issue-specific
# Platform-neutral unit suite for #2150: the probe forges process.platform=win32,
# so spawnShimmedCli()'s win32-only branch runs on Linux and macOS too — the
# WS-*/WC-* integration cases are win32-gated and leave common CI uncovered.
set -u

# TL3 gap (what this test does NOT catch):
# - That a real cmd.exe WOULD execute the planted .cmd payload; Section A shows
#   only that this code never does. The real-shell half is WS-7/WS-8, WC-6/WC-7.
# - That `npm install -g` writes byte-identical shims. Section N transcribes
#   cmd-shim 8.0.0, and its N-legacy-* rows PIN a known false negative: the older
#   `"%~dp0\...` template (still live as corepack.cmd) fails closed.
# - Real UNC / network-PATH latency: bld_unc plants unreachable spellings on a
#   local disk, so it proves the SKIP, never the absence of a stall.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: installer.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARTS="$AGENTS_DIR/tests/feature-2150-spawn-shimmed-cli"
PROBE="$PARTS/probe.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
MODULE_REL="hooks/lib/spawn-shimmed-cli.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# rules/test/fixture-isolation.md: dual-pin the workflow dirs and drop the
# inherited session ids so nothing here can resolve live state.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true
SANDBOX="$(mktemp -d)"
export CLAUDE_WORKFLOW_DIR="$SANDBOX/wf" WORKFLOW_PLANS_DIR="$SANDBOX/plans"
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
ROOT_N="$(node_path "$AGENTS_DIR")"
PROBE_N="$(node_path "$PROBE")"

[ -f "$PROBE" ] || { echo "FAIL: probe missing at $PROBE — every table would be vacuous"; exit 1; }
[ -f "$RWT" ] || { echo "FAIL: bin/run-with-timeout.sh missing"; exit 1; }

# The module lands in the write-code stage. Named once, loudly, so the
# real-module rows read as one diagnosable cause rather than N unrelated
# failures — and the rows still run, and still fail, until it exists.
if [ -f "$AGENTS_DIR/$MODULE_REL" ]; then
    pass "H0 $MODULE_REL is present"
else
    fail "IMPLEMENTATION MISSING: $MODULE_REL — every real-module row below reports load-failed"
fi

# Can this host enforce chmod 000? Under Windows, or as root, it cannot, and a
# read-failure row would then pass for the wrong reason.
PERM_ENFORCED=0
_pf="$SANDBOX/permprobe"; printf 'x\n' > "$_pf"; chmod 000 "$_pf" 2>/dev/null || true
cat "$_pf" >/dev/null 2>&1 || PERM_ENFORCED=1
chmod 644 "$_pf" 2>/dev/null || true

# The direct-launch fixtures (Section O) plant a file the OS can really execute;
# the running interpreter is the only binary the suite is guaranteed to have.
REAL_NODE_EXE="$(node -e 'process.stdout.write(process.execPath)' 2>/dev/null || true)"

# shellcheck source=./feature-2150-spawn-shimmed-cli/fixtures.sh
. "$PARTS/fixtures.sh"
# shellcheck source=./feature-2150-spawn-shimmed-cli/fixtures-npm.sh
. "$PARTS/fixtures-npm.sh"
# shellcheck source=./feature-2150-spawn-shimmed-cli/fixtures-opts.sh
. "$PARTS/fixtures-opts.sh"

CASE_SEQ=0
LAST_CASE_DIR=""
LAST_GOT=""

# probe_row <case-dir> <dirs-file> <pathext> <command> <fn> — one row, one node
# process. stderr is folded in and only the last line is read, so a warning on
# the way out cannot be mistaken for the verdict.
probe_row() {
    SSC_MARKER="$(node_path "$1/__marker.txt")" \
    bash "$RWT" 60 node "$PROBE_N" "$ROOT_N" "$(node_path "$1")" \
        "$(node_path "$2")" "$3" "$4" "$5" 2>&1 | tail -n 1
}

# write_dirs <case-dir> <spec> <out-file>. `spec` is a comma-separated list of
# subdirectory names, or @none / @empty (the two absent-PATH shapes), or @file
# (the builder wrote the exact native entries itself — UNC and the 64/65 cap).
write_dirs() {
    local cdir="$1" spec="$2" out="$3" d
    case "$spec" in
        @none|@empty) printf '%s\n' "$spec" > "$out"; return 0 ;;
        @file) cp "$cdir/__pathdirs.txt" "$out"; return 0 ;;
    esac
    : > "$out"
    local OLD_IFS="$IFS"; IFS=","
    for d in $spec; do
        IFS="$OLD_IFS"
        node_path "$cdir/$d" >> "$out"; printf '\n' >> "$out"
        IFS=","
    done
    IFS="$OLD_IFS"
}

# run_row — build the fixture, evaluate it, compare. A `verdict` row is ALSO
# evaluated against tests/lib/shim-resolve-reference.js and asserted equal: that
# parity is what makes "the helper is missing, bypassed, or behaviourally
# different from the reference" a failure rather than a silent divergence (C1).
run_row() {
    local section="$1" name="$2" want="$3" fn="$4" builder="$5" pathext="$6" pathdirs="$7" command="$8"
    CASE_SEQ=$((CASE_SEQ + 1))
    local cdir="$SANDBOX/c$CASE_SEQ"
    mkdir -p "$cdir"
    LAST_CASE_DIR="$cdir"
    if ! declare -F "bld_$builder" >/dev/null 2>&1; then
        fail "$section $name — harness bug: no builder bld_$builder"; return
    fi
    "bld_$builder" "$cdir"
    local dirs="$cdir/__dirs.txt"
    write_dirs "$cdir" "$pathdirs" "$dirs"
    LAST_GOT="$(probe_row "$cdir" "$dirs" "$pathext" "$command" "$fn")"
    assert_eq "$section $name" "$want" "$LAST_GOT"
    if [ "$fn" = "verdict" ]; then
        assert_eq "$section $name (reference parity)" "$want" \
            "$(probe_row "$cdir" "$dirs" "$pathext" "$command" ref)"
    fi
}

# run_table <section> — rows are `name | want | fn | builder | pathext |
# pathdirs | command`. `want` sits early (the round-12 convention) and the
# command is last, so a command carrying spaces or non-ASCII survives intact.
run_table() {
    local section="$1" tbl name want fn builder pathext pathdirs command
    tbl="$SANDBOX/$section.tbl"
    cat > "$tbl"
    while IFS='|' read -r name want fn builder pathext pathdirs command; do
        name="$(trim "${name:-}")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        run_row "$section" "$name" "$(trim "$want")" "$(trim "$fn")" "$(trim "$builder")" \
            "$(trim "$pathext")" "$(trim "$pathdirs")" "$(trim "${command:-}")"
    done < "$tbl"
}

# shellcheck source=./feature-2150-spawn-shimmed-cli/cases-resolve.sh
. "$PARTS/cases-resolve.sh"
# shellcheck source=./feature-2150-spawn-shimmed-cli/cases-verify.sh
. "$PARTS/cases-verify.sh"
# shellcheck source=./feature-2150-spawn-shimmed-cli/cases-npm-shape.sh
. "$PARTS/cases-npm-shape.sh"
# shellcheck source=./feature-2150-spawn-shimmed-cli/cases-options.sh
. "$PARTS/cases-options.sh"
# shellcheck source=./feature-2150-spawn-shimmed-cli/cases-wiring.sh
. "$PARTS/cases-wiring.sh"

run_R_resolve_on_path
run_P_pathext_config
run_V_verified_shim_target
run_N_npm_shapes
run_O_options
run_A_attack_and_argv
run_W_wiring

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

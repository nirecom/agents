#!/usr/bin/env bash
# tests/hooks/feature-1834-precommit-lib-split.sh
# Tests: hooks/pre-commit, bin/check-test-frontmatter.sh
# Tags: pre-commit, tests-frontmatter, cause-messages, refactor, file-split, TL2, scope:issue-specific, agents-repo-gates, session-id-ssot, migration-blocks, security, word-splitting, error-path, fail-open, case-markers, fail-closed, test-language-match, section-marker, commit-timeout, stderr-contract, real-git
set -u

# Protects the gate blocks #1834 split out of hooks/pre-commit; #2507 moved them into the Node
# body (hooks/pre-commit.d), where they are the tests-frontmatter and agents-repo-gates checks.
# Part A: cause-specific block messages of the tests-frontmatter check. Part B: hook wiring and size.
# Part C: the agents-repo gates and frontmatter security/codes. Part D: the staged case-marker gate.
# Part E: real-commit gate wiring (#2589). Part F: language-match gate and stderr section markers.
# This dispatcher owns the harness, all fixture helpers and globals; cases live in the sibling folder.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"

# Layer: TL2 (real checks + real git fixtures, not the claude -p host).
# TL3 gap (what this test does NOT catch):
# - Parts A-D run one check or gate through tests/lib/precommit-check-runner.js; Part E commits
#   through a fixture copy of hooks/pre-commit via core.hooksPath, but not the installed global hook.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
PRECOMMIT="$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit"
RUNNER="$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/precommit-check-runner.js")"
CHECKOUT_NP="$(np "$SCRIPT_CHECKOUT_ROOT")"

# Tier 1: implementation-missing guard, ahead of any fixture work.
for _f in "$PRECOMMIT" "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/tests-frontmatter.js" \
    "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/agents-repo-gates.js"; do
    if [ ! -f "$_f" ]; then
        echo "FAIL: IMPLEMENTATION MISSING: $_f"
        echo ""
        echo "Results: 0 passed, 1 failed (target not yet implemented)"
        exit 1
    fi
done

# split-modules-wired — hooks/pre-commit runs the Node body, whose registry lists both gate blocks
# as checks with their check modules present.
case_begin "split-modules-wired" "hooks/pre-commit"
_wire_fail=""
grep -qF 'hooks/pre-commit.d/main.js' "$PRECOMMIT" || _wire_fail="$_wire_fail unwired:pre-commit.d/main.js"
for _ck in tests-frontmatter agents-repo-gates; do
    grep -qF "[\"$_ck\"," "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/registry.js" || _wire_fail="$_wire_fail unregistered:$_ck"
    [ -f "$SCRIPT_CHECKOUT_ROOT/hooks/pre-commit.d/checks/$_ck.js" ] || _wire_fail="$_wire_fail missing-check:$_ck.js"
done
if [ -n "$_wire_fail" ]; then
    fail "split-modules-wired" "gate blocks not wired —$_wire_fail"
else
    pass "split-modules-wired: hooks/pre-commit runs the Node body and both gate blocks are registered checks"
fi
case_end

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT

# init_fixture <dir> — throwaway git repo with HEAD (so new files are told apart) and hooks disabled.
init_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add README.md >/dev/null 2>&1
    git -C "$dir" commit -q -m initial >/dev/null 2>&1
}

# run_check <repo> <cfg> <check> [gate] — one check (or one tests-frontmatter gate) over <repo>'s
# index, with <cfg> as the agents checkout; sets OUT (stdout+stderr) and RC.
OUT=""; RC=0
run_check() {
    local repo="$1" cfg="$2"
    shift 2
    RC=0
    OUT="$(cd "$repo" && node "$RUNNER" --cfg "$(np "$cfg")" "$@" 2>&1)" || RC=$?
}
# run_fm_check <repo> — the tests-frontmatter check with the real checkout.
run_fm_check() { run_check "$1" "$CHECKOUT_NP" tests-frontmatter; }

# flat_new.sh carries VALID frontmatter so its ONLY defect is the flat location;
# broken.sh omits every header so its ONLY defect is frontmatter shape.
write_valid_flat() {
    local repo="$1"
    mkdir -p "$repo/tests"
    # shellcheck disable=SC2016  # $SCRIPT_CHECKOUT_ROOT must be written literally into the fixture.
    printf '%s\n' '#!/usr/bin/env bash' \
        '# tests/flat_new.sh' \
        '# Tests: hooks/pre-commit' \
        '# Tags: scope:common' \
        '. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"' > "$repo/tests/flat_new.sh"
    git -C "$repo" add --chmod=+x -- tests/flat_new.sh >/dev/null 2>&1
}
write_broken_categorized() {
    local repo="$1"
    mkdir -p "$repo/tests/hooks"
    printf '%s\n' '#!/usr/bin/env bash' \
        '# broken.sh — no # Tests: header, no # Tags: line' > "$repo/tests/hooks/broken.sh"
    git -C "$repo" add --chmod=+x -- tests/hooks/broken.sh >/dev/null 2>&1
}
write_good_categorized() {
    local repo="$1"
    mkdir -p "$repo/tests/hooks"
    printf '%s\n' '#!/usr/bin/env bash' \
        '# good.sh' \
        '# Tests: hooks/pre-commit' \
        '# Tags: scope:common' > "$repo/tests/hooks/good.sh"
    git -C "$repo" add --chmod=+x -- tests/hooks/good.sh >/dev/null 2>&1
}

# write_staged_nofm <repo> <relpath> — stage a HEADERLESS file at an arbitrary tests/ path; staging
# it at an excluded path and getting rc 0 with no output proves the path is filtered before judging.
write_staged_nofm() {
    local repo="$1" rel="$2"
    mkdir -p "$repo/$(dirname "$rel")"
    printf '%s\n' '#!/usr/bin/env bash' '# no frontmatter — would fail if this path were inspected' > "$repo/$rel"
    git -C "$repo" add --chmod=+x -- "$rel" >/dev/null 2>&1
}

LOC_MSG='must live under tests/<category>/'
FM_MSG='fail frontmatter validation'

init_repo_bare() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
}

# Part C fixtures: a repo that IS its own agents checkout (the Node body, hooks/lib, and the real
# session-id and migration gate modules), so the agents-repo gates arm. Built once, copied per case.
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
# shellcheck source=../lib/node-entry-sandbox.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-entry-sandbox.sh"
declare -A G_MODULE=(
    [on-demand]=bin/lib/check-on-demand-rules.js [session-id]=bin/check-session-id-ssot/main.js
    [migration]=bin/lib/check-migration-blocks.js [plans-artifacts]=bin/check-plans-artifacts
    [plans-dir]=bin/check-plans-dir-isolation/main.js [root-names]=bin/check-root-names/main.js
)
G_TEMPLATE="$TMPBASE/g-template"
script_checkout_fixture_copy "$G_TEMPLATE" hooks/pre-commit hooks/lib bin/check-session-id-ssot bin/check-session-id-ssot.sh >/dev/null ||
    fail "C: gate template" "script_checkout_fixture_copy failed"
node_entry_sandbox_copy "$G_TEMPLATE" hooks/pre-commit.d/main.js "${G_MODULE[session-id]}" "${G_MODULE[migration]}" >/dev/null ||
    fail "C: gate template" "node_entry_sandbox_copy failed"
init_repo_bare "$G_TEMPLATE"

# _install_gate_shim <dir> <gate> <mode> — the gate's module answers clean (0), rc2, rc3, is absent,
# or stays the shipped one (real).
_install_gate_shim() {
    local f="$1/${G_MODULE[$2]}"
    mkdir -p "$(dirname "$f")"
    case "$3" in
        clean)  printf 'exports.run = async () => 0;\n' > "$f" ;;
        rc2)    printf 'exports.run = async () => 2;\n' > "$f" ;;
        rc3)    printf 'exports.run = async () => 3;\n' > "$f" ;;
        absent) rm -f "$f" ;;
        real)   ;;
        *) echo "_install_gate_shim: unknown mode '$3'" >&2; return 1 ;;
    esac
}

# mk_agents_fixture_rc <dir> <si_mode> <mb_mode> [od_mode] — controlled session-id / migration /
# on-demand modules; the three later gates are clean stubs, so a block is the target gate's.
mk_agents_fixture_rc() {
    local dir="$1"
    rm -rf "$dir"
    cp -R "$G_TEMPLATE" "$dir"
    _install_gate_shim "$dir" on-demand "${4:-clean}"
    _install_gate_shim "$dir" session-id "$2"
    _install_gate_shim "$dir" migration "$3"
    _install_gate_shim "$dir" plans-artifacts clean
    _install_gate_shim "$dir" plans-dir clean
    _install_gate_shim "$dir" root-names clean
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -q -m initial >/dev/null 2>&1
}
# mk_agents_fixture <dir> — the real session-id and migration gates, the others clean.
mk_agents_fixture() { mk_agents_fixture_rc "$1" real real clean; }

# run_agents_gates <repo> <cfg-dir> — the agents-repo-gates check; sets GOUT and GRC.
GOUT=""; GRC=0
run_agents_gates() {
    run_check "$1" "$2" agents-repo-gates
    GOUT="$OUT"; GRC="$RC"
}

SID_MSG='session-id env reads bypassing the SSOT resolver'
MIG_MSG='migration block format violations'
SID_SKIP_MSG='session-id SSOT gate skipped'
MIG_SKIP_MSG='migration blocks gate skipped'
OD_MSG='on-demand rules-injection notation violations'
OD_SKIP_MSG='on-demand rules notation gate skipped'

# Per-part cases (sourced; share the helpers/globals above).
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-1834-precommit-lib-split"
# shellcheck source=./feature-1834-precommit-lib-split/part-a-cause-messages.sh
. "$SCRIPT_DIR/part-a-cause-messages.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-b-wiring-size.sh
. "$SCRIPT_DIR/part-b-wiring-size.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-c-gates.sh
. "$SCRIPT_DIR/part-c-gates.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-c-gates-errorpath.sh
. "$SCRIPT_DIR/part-c-gates-errorpath.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-c-frontmatter.sh
. "$SCRIPT_DIR/part-c-frontmatter.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-d-case-markers.sh
. "$SCRIPT_DIR/part-d-case-markers.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-e-commit-wiring.sh
. "$SCRIPT_DIR/part-e-commit-wiring.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-f-language-match.sh
. "$SCRIPT_DIR/part-f-language-match.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-f-section-markers.sh
. "$SCRIPT_DIR/part-f-section-markers.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

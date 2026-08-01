# Part of tests/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/select-tests.sh, bin/resolve-merge-base.sh
# Tags: test-selection, merge-base, zero-commit, integration, wiring, trust-state, scope:issue-specific, pwsh-not-required, TL2

# ============================================================================
# S20 — #1779 end to end, with NOTHING stubbed.
#
# Every other row in this suite replaces bin/resolve-merge-base.sh with a stub, and every row in
# tests/feature-1638-resolve-merge-base.sh exercises the resolver with no selector attached. Both
# suites can therefore be fully green while the two scripts disagree about the very field this
# issue turns on: the resolver could emit `zero_commit=`, or `base_is_head=1`, or put it behind
# `--explain` only, and the selector's stub would still say `base_is_head=true` to itself forever.
# A stub is a copy of a contract, and a copy cannot detect that the original changed.
#
# So this row runs the REAL selector against the REAL resolver in a real repository, and asserts
# only the OBSERVABLE outcome — a test file is selected for work that exists. What passes between
# the two scripts is deliberately not asserted: naming the field here would make this a third
# copy of the contract. If the field is renamed on both sides tomorrow, this row keeps passing,
# which is correct; if it is renamed on one side, this row is the only thing that fails.
#
# RED before the fix, and for the reason the issue describes: the resolver reports RESOLVED with
# base == HEAD, `<base>...HEAD` is empty by construction, and the selector prints nothing.
#
# TL3 gap (what this row does NOT catch):
# - a real remote: the fixture has none, so the resolver's `git fetch origin main` is a no-op and
#   the origin/main candidate is never the one that answers.
# - a recorded session baseline (layer 1): CLAUDE_WORKFLOW_DIR is redirected to an empty
#   directory, so only layer 2 is exercised here.
# - Tier 2. RNT-3 is prose executed by a model; no bash row can run it. Its half of the same
#   contract is pinned statically in tests/fix-1689-run-tests-contract.sh (S10-S10j).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
# ============================================================================

# A real zero-commit repository, built without the stub tree: `main` carries the base commit,
# `work` is cut from it and commits nothing. The resolver finds `main` on its own, which is what
# makes base == HEAD an outcome of the real chain rather than something a fixture asserted.
make_real_zero_commit_repo() { # <repo>
    local repo="$1"
    mkdir -p "$repo/bin"
    git -C "$repo" init -q -b main
    # The developer's global core.hooksPath reaches a repo under /tmp too, and this repo's own
    # pre-commit hook would then refuse the fixture's commit.
    git -C "$repo" config core.hooksPath "$repo/.git/no-such-hooks"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    git -C "$repo" config commit.gpgsign false
    printf 'original\n' > "$repo/bin/select-tests.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "base"
    git -C "$repo" switch -q -c work
    # The whole change, staged and uncommitted — issue #1779 as reported.
    printf 'change\n' >> "$repo/bin/select-tests.sh"
    git -C "$repo" add -A
}

test_S20_real_resolver_end_to_end() {
    local repo="$TMPDIR_BASE/s20"
    local wfdir="$TMPDIR_BASE/s20-workflow"
    mkdir -p "$repo" "$wfdir"
    make_real_zero_commit_repo "$repo"

    # Premise 1: the real resolver really does answer with HEAD here. Without this the row could
    # go green on a repository that simply had an ordinary base, proving nothing about #1779.
    local resolved head
    resolved="$(cd "$repo" && CLAUDE_WORKFLOW_DIR="$wfdir" run_with_timeout 120 bash "$AGENTS_DIR/bin/resolve-merge-base.sh" -C . --no-fetch --format base 2>/dev/null)"
    head="$(git -C "$repo" rev-parse HEAD)"
    if [ -z "$resolved" ]; then
        fail "S20_real_resolver_end_to_end: the real resolver produced no base, so the wiring cannot be exercised"
        return
    fi
    if [ "$resolved" != "$head" ]; then
        fail "S20_real_resolver_end_to_end: fixture premise broken — the real resolver answered [$resolved], not HEAD [$head], so this is not the zero-commit case"
        return
    fi
    # Premise 2: the committed range is empty. This is the bug, stated as a fact about the
    # fixture, and it is what makes the assertion below unreachable by the old code path.
    if [ -n "$(git -C "$repo" diff --name-only "${resolved}...HEAD")" ]; then
        fail "S20_real_resolver_end_to_end: fixture premise broken — the committed range is not empty"
        return
    fi

    local out err rc=0 o e
    o="$TMPDIR_BASE/s20-out"; e="$TMPDIR_BASE/s20-err"
    (
        cd "$repo" || exit 1
        export CLAUDE_WORKFLOW_DIR="$wfdir" AGENTS_CONFIG_DIR="$AGENTS_DIR" RUN_TL3=off
        run_with_timeout 120 bash "$AGENTS_DIR/bin/select-tests.sh" --auto
    ) >"$o" 2>"$e" || rc=$?
    out="$(cat "$o")"; err="$(cat "$e")"
    rm -f "$o" "$e"

    # The real selector searches the real tests/ directory, so the expected hit is this suite's
    # own file: bin/select-tests.sh changed, and its stem is `select-tests`.
    if [ "$rc" != "0" ]; then
        fail "S20_real_resolver_end_to_end: expected exit 0, got rc=$rc
--- stderr ---
$err"
    elif echo "$out" | grep -q "feature-689-select-tests.sh"; then
        pass "S20_real_resolver_end_to_end: the real selector and the real resolver agree — staged work on a zero-commit branch selects its test"
    else
        fail "S20_real_resolver_end_to_end: the two scripts produced an empty selection for a staged change (stub-free wiring is broken or the fix is not in yet)
--- output ---
$out
--- stderr ---
$err"
    fi
}

# ============================================================================
# S28 — the same stub-free wiring, in the OTHER trustworthy state.
#
# S20 above lands on RESOLVED: no baseline exists, so the resolver walks the chain and finds
# `main`. S25 (zero-commit-trust-and-faults.sh) covers RECORDED, but through a STUB that is told
# to say `state=RECORDED` and `base_is_head=true` in the same breath — it can never disagree with
# itself, so it proves only that the selector's RECORDED arm exists. What neither row shows is
# that the REAL resolver, on the layer-1 path, still reports the zero-commit observation at all:
# layer 1 returns early, before the layer-2 block where every other value is computed, and a fix
# wired into that block would leave RECORDED reporting nothing while both suites stay green.
#
# The state arrives here the way it arrives in production, not by assertion: RNT-1 tells the user
# who hits exit 4 to confirm a base and record it with bin/workflow/record-merge-base-baseline,
# then re-run. On a branch with no commits the only base there is to confirm IS HEAD — so the
# recorded fact and the degenerate range are the same commit, and the user who just recovered
# from one merge-base problem is put straight back into #1779 if RECORDED is not covered. That
# is the sequence this row replays, through the real CLI, the real resolver and the real selector.
#
# Both halves of the working-tree union are present (a staged tracked edit and a file that was
# never added), so a RECORDED path that reaches only one of them fails here rather than passing
# on the half it kept.
#
# RED before the fix, for S20's reason: base == HEAD makes `<base>...HEAD` empty by construction.
#
# TL3 gap: as S20 — no remote, and Tier 2 is prose no bash row can execute.
# ============================================================================

test_S28_real_resolver_recorded_state_end_to_end() {
    local repo="$TMPDIR_BASE/s28"
    local wfdir="$TMPDIR_BASE/s28-workflow"
    local sid="s28sid"
    mkdir -p "$repo" "$wfdir"

    # The recording CLI is node; without it the production path cannot be replayed, and a row
    # that silently degraded to writing the state file by hand would be S25 with extra steps.
    if ! command -v node >/dev/null 2>&1; then
        skip "S28_real_resolver_recorded_state_end_to_end: no node on this host, so the real baseline CLI cannot run"
        return
    fi

    make_real_zero_commit_repo "$repo"
    # The untracked half. `bin/resolve-merge-base.sh` never existed in this fixture's base commit
    # and is never added, so it appears only through `git ls-files --others`; its stem selects
    # this repository's own tests/feature-1638-resolve-merge-base.sh.
    printf 'brand new\n' > "$repo/bin/resolve-merge-base.sh"

    local head
    head="$(git -C "$repo" rev-parse HEAD)"

    # The recovery RNT-1 documents, run for real: the user confirms the only base there is.
    if ! CLAUDE_WORKFLOW_DIR="$wfdir" run_with_timeout 120 node \
            "$AGENTS_DIR/bin/workflow/record-merge-base-baseline" \
            --session "$sid" --base "$head" --reason "S28 fixture: zero-commit branch, base confirmed as HEAD" \
            --repo "$repo" >/dev/null 2>&1; then
        fail "S28_real_resolver_recorded_state_end_to_end: the baseline CLI refused to record, so the RECORDED path cannot be reached"
        return
    fi

    # Premise: the REAL resolver adopts that baseline, and the base it adopts is HEAD. Both halves
    # matter — without the state check this row is a duplicate of S20, and without the base check
    # it is not the zero-commit case.
    local kv state base
    kv="$(cd "$repo" && CLAUDE_WORKFLOW_DIR="$wfdir" CLAUDE_CODE_SESSION_ID="$sid" \
        run_with_timeout 120 bash "$AGENTS_DIR/bin/resolve-merge-base.sh" -C . --no-fetch --format kv 2>/dev/null)"
    state="$(printf '%s\n' "$kv" | sed -n 's/^state=//p')"
    base="$(printf '%s\n' "$kv" | sed -n 's/^base=//p')"
    if [ "$state" != "RECORDED" ]; then
        fail "S28_real_resolver_recorded_state_end_to_end: fixture premise broken — the real resolver reported state=[$state], not RECORDED
--- kv ---
$kv"
        return
    fi
    if [ "$base" != "$head" ]; then
        fail "S28_real_resolver_recorded_state_end_to_end: fixture premise broken — the recorded base [$base] is not HEAD [$head], so this is not the zero-commit case"
        return
    fi
    if [ -n "$(git -C "$repo" diff --name-only "${base}...HEAD")" ]; then
        fail "S28_real_resolver_recorded_state_end_to_end: fixture premise broken — the committed range is not empty"
        return
    fi

    local out err rc=0 o e
    o="$TMPDIR_BASE/s28-out"; e="$TMPDIR_BASE/s28-err"
    (
        cd "$repo" || exit 1
        export CLAUDE_WORKFLOW_DIR="$wfdir" CLAUDE_CODE_SESSION_ID="$sid" \
               AGENTS_CONFIG_DIR="$AGENTS_DIR" RUN_TL3=off
        run_with_timeout 120 bash "$AGENTS_DIR/bin/select-tests.sh" --auto
    ) >"$o" 2>"$e" || rc=$?
    out="$(cat "$o")"; err="$(cat "$e")"
    rm -f "$o" "$e"

    local missing=""
    echo "$out" | grep -q "feature-689-select-tests.sh" || missing="$missing [tracked stem]"
    echo "$out" | grep -q "feature-1638-resolve-merge-base.sh" || missing="$missing [untracked stem]"

    if [ "$rc" != "0" ]; then
        fail "S28_real_resolver_recorded_state_end_to_end: expected exit 0, got rc=$rc
--- stderr ---
$err"
    elif [ -n "$missing" ]; then
        fail "S28_real_resolver_recorded_state_end_to_end: missing$missing — a really-recorded baseline on a zero-commit branch still selects from the empty committed range
--- output ---
$out
--- stderr ---
$err"
    elif ! printf '%s\n' "$err" | grep -qiE "$ZC_DEGRADE_RE"; then
        fail "S28_real_resolver_recorded_state_end_to_end: the range was switched without saying so on stderr
--- stderr ---
$err"
    else
        pass "S28_real_resolver_recorded_state_end_to_end: a baseline recorded through the real CLI reaches the same working-tree fallback RESOLVED does"
    fi
}

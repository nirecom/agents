# Part of tests/bin/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/select-tests.sh, bin/resolve-merge-base.sh
# Tags: test-selection, merge-base, zero-commit, integration, wiring, trust-state, scope:issue-specific, pwsh-not-required, TL2

# S20 — #1779 end to end, NOTHING stubbed. Every other row stubs resolve-merge-base.sh, and
# feature-1638 tests the resolver with no selector — so both suites can stay green while the two
# scripts disagree on the field this issue turns on (a stub is a copy of a contract; it can't detect
# the original changed). This runs the REAL selector against the REAL resolver and asserts only the
# observable outcome, never the field name (a 3rd copy). RED before the fix: RESOLVED, base == HEAD, empty range. TL3 gap (no remote / layer-1 baseline / Tier 2 prose) checked at USER_VERIFIED preflight via bin/check-verification-gate.sh.

# make_real_zero_commit_repo: a real zero-commit repo built without the stub tree — `main` holds
# the base commit, `work` is cut from it and commits nothing, so base == HEAD comes from the real chain.
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

# S28 — the same stub-free wiring in the OTHER trustworthy state (RECORDED). S20 lands on RESOLVED
# (no baseline, resolver walks the chain to `main`); S25 covers RECORDED but through a stub told to
# say both state and base_is_head, so it can't disagree with itself. What neither shows: the REAL
# resolver's layer-1 (recorded-baseline) path returns early, before the layer-2 block where the
# zero-commit observation is computed — a fix wired only into layer 2 leaves RECORDED silent while
# both suites stay green. The state arrives as in production (RNT-1 → record-merge-base-baseline →
# re-run); on a zero-commit branch the only base to confirm IS HEAD, so a user recovering from exit
# 4 is put straight back into #1779 if RECORDED is uncovered. Both union halves (staged tracked +
# untracked) are present. RED before the fix (base == HEAD, empty range); TL3 gap as S20.

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
    # this repository's own tests/bin/feature-1638-resolve-merge-base.sh.
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

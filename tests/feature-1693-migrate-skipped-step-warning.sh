#!/usr/bin/env bash
# tests/feature-1693-migrate-skipped-step-warning.sh
# Tests: bin/github-issues/migration/orchestrate.sh
# Tags: migration, repo, github, issues, bin, resume, warning, TL2, scope:issue-specific
#
# `--from-step N` jumps straight to step N. When the recorded current_step is far
# behind N, every step in between is silently never run — and Step 4 (Projects v2
# board + Content Date backfill) is the expensive one to discover missing, since
# by then the issues exist but none of them are on a board or carry a date.
#
# The orchestrator must warn on stderr, naming each skipped step, and must offer
# an explicit acknowledgement flag so a deliberate jump is not noisy.
#
# TL2: spawns the real orchestrate.sh against a real fixture repo with a mocked
# `gh` on PATH. Not TL1 — the warning depends on argument parsing plus reading
# the on-disk .migration-state.json.
#
# TL3 gap (what this test does NOT catch): whether the /migrate-repo skill
# surfaces the warning to the user rather than swallowing stderr, and whether a
# real Projects v2 board is actually missing after such a jump.
#
# RED before write-code: no skipped-step warning exists, and
# `--ack-skipped-steps` is rejected as an unknown arg.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/orchestrate.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$ORCH_SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/github-issues/migration/orchestrate.sh"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

TMP="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/migr-skip-$$")"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

MOCK_DIR="$TMP/mock"
mkdir -p "$MOCK_DIR"
cp "$AGENTS_DIR/tests/fixtures/migration/gh-mock.sh" "$MOCK_DIR/gh"
chmod +x "$MOCK_DIR/gh"
MOCK_LOG="$TMP/mock.log"
: > "$MOCK_LOG"
export MOCK_LOG
export PATH="$MOCK_DIR:$PATH"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

# make_fixture <name> <current_step> -> echoes the fixture repo path
make_fixture() {
    # Declared separately: a single `local a=$1 b=$TMP/$a` trips `set -u`,
    # because `local` creates every name before running the assignments.
    local name="$1"
    local current_step="$2"
    local dir="$TMP/$name"
    mkdir -p "$dir/docs"
    cat > "$dir/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
EOF
    cat > "$dir/docs/todo.md" <<'EOF'
## Active Work

- task-001: do something
EOF
    # Written by hand rather than via state_init so current_step is pinned.
    cat > "$dir/.migration-state.json" <<EOF
{"schema_version":2,"repo_dir":"$dir","started_at":"2024-01-01T00:00:00Z","current_step":$current_step,
 "history":{"total_entries":1,"migrated":[],"advanced":{"canary_1":null,"canary_2":null,"full":null}},
 "todo":{"total_entries":1,"migrated":[],"todo_md_rewritten":false,"advanced":{"canary_1":null,"canary_2":null,"full":null}},
 "project":{"number":null,"node_id":null,"field_ids":{},"repo_linked":false}}
EOF
    echo "$dir"
}

# Run the orchestrator, capturing stdout and stderr separately.
OUT=""; ERR=""; RC=0
orchestrate() {
    local repo="$1"; shift
    OUT="$(run_with_timeout 60 bash "$ORCH_SCRIPT" "$repo" "$@" 2>"$TMP/err.txt")"
    RC=$?
    ERR="$(cat "$TMP/err.txt" 2>/dev/null)"
}

has()  { printf '%s\n' "$1" | grep -qF -- "$2"; }
hasE() { printf '%s\n' "$1" | grep -qE -- "$2"; }

# ===========================================================================
# Case 1 — a jump over steps 2-4 warns, naming every skipped step
# ===========================================================================
case1_warns_on_jump() {
    local repo; repo="$(make_fixture c1 1)"
    orchestrate "$repo" --from-step 5 --dry-run

    local missing=""
    [ "$RC" = "0" ] || missing="$missing rc=$RC"
    hasE "$ERR" 'WARNING|Warning|警告' || missing="$missing warning-marker"
    hasE "$ERR" '[Ss]kip'              || missing="$missing skip-word"
    # Each in-between step must be named — "some steps were skipped" is not
    # actionable; the operator needs to know which.
    local n
    for n in 2 3 4; do
        hasE "$ERR" "[Ss]tep $n" || missing="$missing step-$n-not-named"
    done
    # A skipped step that already ran must not be reported.
    hasE "$ERR" '[Ss]tep 1' && missing="$missing step-1-wrongly-named"

    if [ -z "$missing" ]; then
        pass "C1: --from-step 5 with current_step=1 warns on stderr and names steps 2, 3 and 4"
    else
        fail "C1: skipped-step warning wrong" "missing:$missing | stderr=$(printf '%s' "$ERR" | head -c 400)"
    fi
}

case1b_calls_out_step4() {
    local repo; repo="$(make_fixture c1b 1)"
    orchestrate "$repo" --from-step 5 --dry-run

    local missing=""
    # Step 4 is the consequential one: skipping it leaves migrated issues with
    # no board and no Content Date, and nothing later fails loudly.
    has "$ERR" 'Projects v2'  || missing="$missing projects-v2"
    has "$ERR" 'Content Date' || missing="$missing content-date"

    if [ -z "$missing" ]; then
        pass "C1b: the warning spells out what Step 4 would have done (Projects v2 board + Content Date backfill)"
    else
        fail "C1b: Step 4 consequence not spelled out" "missing:$missing | stderr=$(printf '%s' "$ERR" | head -c 400)"
    fi
}

# ===========================================================================
# Case 2 — --ack-skipped-steps suppresses the detail, keeps a short trace
# ===========================================================================
case2_ack_suppresses_detail() {
    local repo; repo="$(make_fixture c2 1)"
    orchestrate "$repo" --from-step 5 --dry-run --ack-skipped-steps

    local missing=""
    [ "$RC" = "0" ] || missing="$missing rc=$RC"
    # The verbose explanation is gone...
    has "$ERR" 'Projects v2'  && missing="$missing detail-still-present-projects-v2"
    has "$ERR" 'Content Date' && missing="$missing detail-still-present-content-date"
    # ...but the jump is still recorded, so the run is not silent. The two words
    # must co-occur on one line: a bare "skip" anywhere in the output (including
    # an arg-parse error naming the flag) is not a trace of the jump.
    printf '%s\n%s\n' "$OUT" "$ERR" \
        | grep -qEi '(acknowledg[a-z]*[^\n]*skip)|(skip[a-z]*[^\n]*acknowledg)' \
        || missing="$missing no-acknowledged-trace"

    if [ -z "$missing" ]; then
        pass "C2: --ack-skipped-steps drops the detailed warning but still records the acknowledged jump"
    else
        fail "C2: ack behavior wrong" "missing:$missing | rc=$RC stderr=$(printf '%s' "$ERR" | head -c 400)"
    fi
}

# ===========================================================================
# Case 3 — no jump, no warning (and the run really happened)
# ===========================================================================
case3_no_jump_no_warning() {
    local repo; repo="$(make_fixture c3 1)"
    orchestrate "$repo" --from-step 1 --dry-run

    local missing=""
    [ "$RC" = "0" ] || missing="$missing rc=$RC"
    # Control: without proof the orchestrator actually ran, "no warning" would
    # pass just as well on a crash.
    has "$OUT" '/migrate-repo orchestrator' || missing="$missing orchestrator-did-not-run"
    hasE "$ERR" 'WARNING.*[Ss]kip|[Ss]kipped step' && missing="$missing spurious-warning"

    if [ -z "$missing" ]; then
        pass "C3: --from-step 1 with current_step=1 emits no skipped-step warning"
    else
        fail "C3: no-jump case wrong" "missing:$missing | rc=$RC stderr=$(printf '%s' "$ERR" | head -c 400)"
    fi
}

# ===========================================================================
# Case 4 — the boundary: warn iff at least one step is genuinely skipped
# ===========================================================================
# The set of skipped steps is (current_step, from_step) exclusive, i.e.
# current_step+1 .. from_step-1. It is empty exactly when
# from_step <= current_step + 1, so that is the whole no-warning condition:
# resuming at the next step, re-running the current one, or jumping backwards
# all skip nothing. An off-by-one in either direction shows up here as a
# spurious warning on a sanctioned resume — the noise that trains operators to
# ignore the warning that matters.

# assert_no_warning <label> <fixture> <current_step> <from_step>
assert_no_warning() {
    local label="$1" name="$2" cur="$3" from="$4"
    local repo missing=""
    repo="$(make_fixture "$name" "$cur")"
    orchestrate "$repo" --from-step "$from" --dry-run

    [ "$RC" = "0" ] || missing="$missing rc=$RC"
    has "$OUT" '/migrate-repo orchestrator' || missing="$missing orchestrator-did-not-run"
    hasE "$ERR" 'WARNING.*[Ss]kip|[Ss]kipped step' && missing="$missing spurious-warning"
    has "$ERR" 'Projects v2' && missing="$missing spurious-step4-detail"

    if [ -z "$missing" ]; then
        pass "$label"
    else
        fail "$label" "missing:$missing | rc=$RC stderr=$(printf '%s' "$ERR" | head -c 300)"
    fi
}

case4_boundary_no_warning() {
    # from_step == current_step + 1: the sanctioned resume, nothing in between.
    assert_no_warning "C4a: current_step=4 --from-step 5 skips nothing, so no warning" c4a 4 5
    # from_step == current_step: a deliberate re-run of the step just recorded.
    assert_no_warning "C4b: current_step=5 --from-step 5 re-runs the current step without warning" c4b 5 5
    # from_step < current_step: a backwards jump re-runs work; nothing is skipped.
    assert_no_warning "C4c: current_step=6 --from-step 5 jumps backwards, so no skipped-step warning" c4c 6 5
    # Same boundary one step lower, to catch a rule hard-coded around step 5.
    assert_no_warning "C4d: current_step=3 --from-step 4 skips nothing, so no warning" c4d 3 4
}

# ===========================================================================
# Case 5 — the range: exactly the in-between steps are named, no more
# ===========================================================================
case5_range_from_step_4() {
    local repo; repo="$(make_fixture c5 1)"
    orchestrate "$repo" --from-step 4 --dry-run

    local missing="" n
    [ "$RC" = "0" ] || missing="$missing rc=$RC"
    for n in 2 3; do
        hasE "$ERR" "[Ss]tep $n" || missing="$missing step-$n-not-named"
    done
    # Step 4 is where the run STARTS: naming it as skipped is the off-by-one,
    # and it would drag in the Projects v2 / Content Date warning for work that
    # is about to happen.
    hasE "$ERR" '[Ss]tep 4' && missing="$missing step-4-wrongly-named"
    has "$ERR" 'Projects v2'  && missing="$missing spurious-projects-v2"
    has "$ERR" 'Content Date' && missing="$missing spurious-content-date"
    hasE "$ERR" '[Ss]tep 1' && missing="$missing step-1-wrongly-named"

    if [ -z "$missing" ]; then
        pass "C5: --from-step 4 with current_step=1 names steps 2 and 3 only, and does not warn about Step 4's own work"
    else
        fail "C5: skipped range wrong for --from-step 4" "missing:$missing | stderr=$(printf '%s' "$ERR" | head -c 400)"
    fi
}

case5b_range_from_step_6() {
    local repo; repo="$(make_fixture c5b 1)"
    orchestrate "$repo" --from-step 6 --dry-run

    local missing="" n
    [ "$RC" = "0" ] || missing="$missing rc=$RC"
    for n in 2 3 4 5; do
        hasE "$ERR" "[Ss]tep $n" || missing="$missing step-$n-not-named"
    done
    hasE "$ERR" '[Ss]tep 6' && missing="$missing step-6-wrongly-named"
    # Step 4 IS skipped here, so its consequence must be spelled out.
    has "$ERR" 'Projects v2' || missing="$missing step4-consequence-missing"

    if [ -z "$missing" ]; then
        pass "C5b: --from-step 6 with current_step=1 names steps 2-5 and not step 6, and still calls out Step 4"
    else
        fail "C5b: skipped range wrong for --from-step 6" "missing:$missing | stderr=$(printf '%s' "$ERR" | head -c 400)"
    fi
}

case1_warns_on_jump
case1b_calls_out_step4
case2_ack_suppresses_detail
case3_no_jump_no_warning
case4_boundary_no_warning
case5_range_from_step_4
case5b_range_from_step_6

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))

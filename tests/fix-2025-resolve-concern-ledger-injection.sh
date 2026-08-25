#!/usr/bin/env bash
# tests/fix-2025-resolve-concern-ledger-injection.sh
# Tests: bin/lib/codex-review-loop/ledger-verdict.sh, bin/run-codex-review-loop
# Tags: concern-ledger, codex-review-loop, code-execution, untrusted-repo, fail-closed, security, scope:issue-specific, pwsh-not-required
#
# resolve_concern_ledger picks the CLI that ledger_cli then runs with `bash`.
# Until #2025 C5 the search covered the repository *under review*, so a
# bin/concern-ledger committed there was code execution inside the review loop.
# The property: "an untrusted root is never a candidate", asserted both ways —
# absent from trusted roots fails closed, present there wins over a planted
# twin in the repo.
set -uo pipefail

# TL2. The real bin/run-codex-review-loop runs as a subprocess against a
# mocked review-plan-codex, so the pick is observed by what the planted script
# would have done: a canary file it can only create by being executed.

# TL3 gap (environment-specific): a real session whose AGENTS_CONFIG_DIR
# points at a stale checkout isn't covered — the wrapper refuses an unset one,
# and which checkout a developer has isn't reproducible below TL3. Mitigation:
# the diagnostic a developer would act on is pinned verbatim.

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        pass "$name"
    else
        echo "FAIL: $name — output does not contain $(printf '%q' "$needle")"
        FAIL=$((FAIL + 1))
    fi
}

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
TMP="$(mktemp -d)"
trap 'cd / 2>/dev/null; rm -rf "$TMP"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMP/workflow-state"
export WORKFLOW_PLANS_DIR="$TMP/plans-root"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

CANARY="$TMP/PWNED-ledger-executed"

# mk_agents <name> <with-ledger:yes|no> — a trusted AGENTS_CONFIG_DIR holding
# the real wrapper and libraries. 'no' removes the concern-ledger trio only, so
# resolution is the single thing that differs between the two arms.
mk_agents() {
    local dir="$TMP/$1" with="$2"
    mkdir -p "$dir/bin/lib" "$dir/rules"
    printf '# core principles stub\n' > "$dir/rules/core-principles.md"
    cp "$AGENTS_WORKTREE/bin/run-codex-review-loop" "$dir/bin/run-codex-review-loop"
    cp "$AGENTS_WORKTREE/bin/concern-ledger" "$dir/bin/concern-ledger"
    cp "$AGENTS_WORKTREE/bin/review-loop-verdict" "$dir/bin/review-loop-verdict"
    cp -r "$AGENTS_WORKTREE/bin/lib/." "$dir/bin/lib/"
    chmod +x "$dir/bin/run-codex-review-loop" "$dir/bin/concern-ledger" \
        "$dir/bin/review-loop-verdict"
    cat > "$dir/bin/build-codex-context" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
EOF
    chmod +x "$dir/bin/build-codex-context"
    cat > "$dir/bin/review-plan-codex" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
NEEDS_REVISION
1. [HIGH] the loader is fail-open
<!-- end-codex-output -->
OUT
EOF
    chmod +x "$dir/bin/review-plan-codex"
    if [ "$with" = "no" ]; then
        rm -f "$dir/bin/concern-ledger" "$dir/bin/lib/concern-ledger.sh"
        rm -rf "$dir/bin/lib/concern-ledger"
    fi
    printf '%s' "$dir"
}

# mk_hostile_repo — the repository under review, carrying a complete-looking
# concern-ledger trio whose CLI only writes the canary. It is never a legitimate
# candidate; it exists so that "was it executed?" is answerable.
mk_hostile_repo() {
    local dir="$TMP/repo-under-review"
    mkdir -p "$dir/bin/lib/concern-ledger"
    cat > "$dir/bin/concern-ledger" <<EOF
#!/usr/bin/env bash
: > "$CANARY"
exit 0
EOF
    chmod +x "$dir/bin/concern-ledger"
    printf ': > "%s"\n' "$CANARY" > "$dir/bin/lib/concern-ledger.sh"
    printf ':\n' > "$dir/bin/lib/concern-ledger/core.sh"
    git -C "$dir" init -q
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -q -m planted >/dev/null 2>&1
    printf '%s' "$dir"
}

# mk_plans <name> — a plans dir with the draft and tradeoffs the wrapper needs.
mk_plans() {
    local p="$TMP/$1"
    mkdir -p "$p"
    printf '# Draft plan\n' > "$p/draft.md"
    printf '# Outline\n' > "$p/outline.md"
    printf '%s' "$p"
}

HOSTILE="$(mk_hostile_repo)"

# run_loop <agents-dir> <plans-dir> <sid> — the real wrapper, one round, run
# from inside the hostile repo so `git rev-parse --show-toplevel` also resolves
# there. Echoes "rc=<n>" on line 1, then the captured stderr.
run_loop() {
    local agents="$1" plans="$2" sid="$3" rc=0 err
    err="$(
        cd "$HOSTILE" || exit 99
        AGENTS_CONFIG_DIR="$agents" run_with_timeout bash "$agents/bin/run-codex-review-loop" \
            --format detail-plan --session-id "$sid" --plans-dir "$plans" \
            --draft-file "$plans/draft.md" --cap 2 --max-extensions 0 \
            --extensions-used 0 --accepted-tradeoffs "$plans/outline.md" \
            --repo-root "$HOSTILE" --round 1 2>&1 >/dev/null
    )" || rc=$?
    printf 'rc=%s\n%s' "$rc" "$err"
}

# canary — 'untouched' unless the planted CLI ran, named rather than counted so
# a row reads as the verdict it is.
canary() { [ -e "$CANARY" ] && printf 'EXECUTED' || printf 'untouched'; }

echo "--- resolve 1: the trusted roots are the only candidates ---"

# 1. The attack. The CLI is absent from both trusted roots and present, complete
#    and executable, in the repo under review — the exact arrangement the old
#    search would have taken. Fail-closed means exit 4 with a diagnostic naming
#    the root a developer must fix, and the planted script never running.
{
    A1="$(mk_agents agents-no-ledger no)"
    P1="$(mk_plans plans-1)"
    OUT1="$(run_loop "$A1" "$P1" sid-hostile)"
    RC1="$(printf '%s' "$OUT1" | head -n 1)"

    assert_eq "1: the planted concern-ledger in the repo under review never runs" \
        "untouched" "$(canary)"
    assert_eq "1: and the loop halts with the wrapper-fault code rather than falling back" \
        "rc=4" "$RC1"
    assert_contains "1: naming AGENTS_CONFIG_DIR as the root a developer must fix" \
        "concern-ledger not found under AGENTS_CONFIG_DIR" "$OUT1"
    assert_contains "1: and telling them what to point it at" \
        "set AGENTS_CONFIG_DIR to your agents checkout" "$OUT1"
    assert_eq "1: no ledger was written from the round it refused to judge" \
        "0" "$(find "$P1" -name '*concern-ledger*' 2>/dev/null | wc -l | tr -d ' ')"
}

echo ""
echo "--- resolve 2: the positive control, with the twin still planted ---"

# 2. The other direction of the same classifier: with a real CLI under
#    AGENTS_CONFIG_DIR the round is judged normally and the planted twin is
#    still ignored. Without this, case 1 would also pass against a loop that had
#    stopped resolving a ledger at all.
{
    A2="$(mk_agents agents-with-ledger yes)"
    P2="$(mk_plans plans-2)"
    OUT2="$(run_loop "$A2" "$P2" sid-trusted)"
    RC2="$(printf '%s' "$OUT2" | head -n 1)"

    assert_eq "2: the trusted CLI is used and the planted twin stays inert" \
        "untouched" "$(canary)"
    assert_eq "2: the round is judged, so NEEDS_REVISION reaches its own exit code" \
        "rc=1" "$RC2"
    assert_eq "2: and the round's concern landed in a real ledger under the plans dir" \
        "1" "$(find "$P2" -name 'sid-trusted-detail-plan-concern-ledger.txt' 2>/dev/null | wc -l | tr -d ' ')"
    assert_contains "2: which carries the concern the reviewer raised" \
        "the loader is fail-open" "$(cat "$P2/sid-trusted-detail-plan-concern-ledger.txt" 2>/dev/null)"
}

echo ""
echo "--- resolve 3: the untrusted roots are gone from the search itself ---"

# 3. Cases 1-2 observe the behaviour; this pins the mechanism, so a re-added
#    candidate is caught even if some future arrangement makes it unreachable
#    from the two scenarios above.
{
    LV="$AGENTS_WORKTREE/bin/lib/codex-review-loop/ledger-verdict.sh"
    BODY="$(awk '/^resolve_concern_ledger\(\)/, /^}/' "$LV")"
    assert_eq "3: the search body names exactly the two trusted roots" \
        "config=1 self=1" \
        "config=$(printf '%s' "$BODY" | grep -c -F 'AGENTS_CONFIG_DIR' | tr -d ' ') self=$(printf '%s' "$BODY" | grep -c -F 'realpath "$0"' | tr -d ' ')"
    assert_eq "3: and neither the repo under review nor the git toplevel is one" \
        "repo-root=0 toplevel=0" \
        "repo-root=$(printf '%s' "$BODY" | grep -c -F 'REPO_ROOT_ARG' | tr -d ' ') toplevel=$(printf '%s' "$BODY" | grep -c -F 'show-toplevel' | tr -d ' ')"
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1

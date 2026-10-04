# tests/bin/feature-2434-review-loop/fixture.sh — shared setup for the
# feature-2434-review-loop-*.sh suites (sourced, never run on its own).
# Tests: tests/bin/feature-2434-review-loop/fixture.sh
# Tags: feature-2434, test-infrastructure, codex-review-loop, control-dir, scope:issue-specific
#
# The real stage wrappers and bin/run-codex-review-loop run in a throwaway
# AGENTS_CONFIG_DIR; only the reviewers are stubbed. One wrapper run costs
# ten to twenty seconds, so each suite keeps to about five runs (120 s timeout).
# The caller sets AGENTS_DIR and sources tests/lib/harness.sh first.

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${AGENTS_DIR:-}" ]; then
    echo "fixture.sh is sourced by tests/bin/feature-2434-*.sh; nothing to run on its own"
    exit 0
fi
# shellcheck source=tests/lib/codex-loop-fixture.sh
. "$AGENTS_DIR/tests/lib/codex-loop-fixture.sh"
PASS=0; FAIL=0; SKIP=0

TMP="$(make_tmp)"
trap 'cd / 2>/dev/null; rm -rf "$TMP"' EXIT
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
harness_isolate "$TMP"
mkdir -p "$TMP/empty-transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/empty-transcripts"
cd "$TMP" || exit 1

P="$WORKFLOW_PLANS_DIR"
ROOT="$TMP/agents"
clf_make_root "$ROOT" "$AGENTS_DIR"
cp -r "$AGENTS_DIR/hooks" "$ROOT/hooks"
clf_stub_reviewer "$ROOT"
# review-code-codex stub: one open HIGH in the anchored Concern Delta shape.
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ -n "${CLF_ARGV_LOG:-}" ]] && printf "%s\n" "$*" >> "$CLF_ARGV_LOG"' \
    'printf "## Codex Review: PERFORMED\n\n## Concern Delta\n\n## HIGH\n- [HIGH] - | reviewed.txt#check_input | correctness | unchecked input reaches the shell\n\n## MEDIUM\n(none)\n\n## LOW\n(none)\n"' \
    'exit 0' > "$ROOT/bin/review-code-codex"
chmod +x "$ROOT/bin/review-code-codex"

# A repo with a staged diff and a staged test, so security-code and test-review
# have something to fingerprint.
REPO="$TMP/repo"
mkdir -p "$REPO/tests"
# -b main: with no origin the loop scopes changed-files by merge-base HEAD main,
# so the fixture must not depend on the host's init.defaultBranch.
git -C "$REPO" init -q -b main
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
printf 'init\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m init
printf 'reviewed\n' > "$REPO/reviewed.txt"
printf '#!/usr/bin/env bash\n' > "$REPO/tests/t.sh"
git -C "$REPO" add reviewed.txt tests/t.sh

ctl() { printf '%s/%s.control' "$WORKFLOW_STATE_DIR" "$1"; }
# run_bin <file> [args...] — run a new bin CLI by its shebang; the plan does not
# fix whether bin/accept-exit6-residual etc. are node or bash.
run_bin() {
    local f="$1"; shift
    case "$(head -n 1 "$f" 2>/dev/null)" in *node*) node "$f" "$@" ;; *) bash "$f" "$@" ;; esac
}
state() { if [ -d "$1" ]; then printf dir; elif [ -e "$1" ]; then printf present; else printf absent; fi; }

seed_sid() {
    printf '# Intent\n' > "$P/$1-intent.md"
    printf '# Outline\n' > "$P/$1-outline.md"
    printf '# Detail\n' > "$P/$1-detail.md"
    printf '# Test review\n' > "$P/$1-test-review.md"
}

# wrap <skill> <sid> [extensions-used] — one real stage-wrapper run. Sets W_RC / W_ERR.
wrap() {
    local errf="$TMP/wrap-$2.err"
    W_RC=0
    ( cd "$REPO" || exit 1
      AGENTS_CONFIG_DIR="$ROOT" SESSION_ID="$2" PLANS_DIR="$P" EXTENSIONS_USED="${3:-0}" \
          bash "$AGENTS_DIR/skills/$1/scripts/run-codex-review-loop.sh" ) >/dev/null 2>"$errf" || W_RC=$?
    W_ERR="$(cat "$errf" 2>/dev/null)"
}

# plans_leftovers <sid> — PLANS entries of <sid> that are not artifacts (the
# seeded drafts plus the artifact families of the inventory table).
plans_leftovers() {
    local f b out=""
    for f in "$P/$1"-* "$P/$1".*; do
        [ -e "$f" ] || continue
        b="${f##*/}"
        case "$b" in
            "$1-intent.md"|"$1-outline.md"|"$1-detail.md"|"$1-test-review.md") continue ;;
            "$1"-*concerns-log.md|"$1"-*codex-round-*-raw.md|"$1"-*debug.log) continue ;;
        esac
        out="$out $b"
    done
    printf '%s' "${out# }"
}

# name | skill | loop format | ledger format | producer
FORMATS="outline-plan|make-outline-plan|outline-plan|outline-plan|review-plan-codex
detail-plan|make-detail-plan|detail-plan|detail-plan|review-plan-codex
security-plan|review-plan-security|security-plan|security-plan|review-plan-codex
security-code|review-code-security|security-code|review-security-shared|review-code-codex
test-review|review-tests|test-review|test-review|review-plan-codex"

# check_exit9_accept <fmt> <skill> — an exit-6 terminal with a stale fingerprint
# blocks the edited re-run (exit 9) until bin/accept-exit6-residual records the
# accept; then the wrapper runs a real round (rc 1). Two wrapper runs.
check_exit9_accept() {
    local fmt="$1" skill="$2" sid="w9-$1" arc=0
    seed_sid "$sid"
    mkdir -p "$(ctl "$sid")"
    printf '6\nstale-fingerprint\n' > "$(ctl "$sid")/$fmt-terminal.txt"
    wrap "$skill" "$sid"
    assert_eq "$fmt: exit-6 terminal, content changed, not accepted -> exit 9" "9" "$W_RC"
    assert_not_contains "$fmt: the exit-9 hint does not tell the model to touch a file" "touch" "$W_ERR"
    assert_contains "$fmt: the exit-9 hint names the accept CLI" "accept-exit6-residual" "$W_ERR"
    run_bin "$AGENTS_DIR/bin/accept-exit6-residual" --session "$sid" --format "$fmt" \
        --reason "user accepted residual HIGH" >/dev/null 2>&1 || arc=$?
    assert_eq "$fmt: the accept CLI exits 0" "0" "$arc"
    wrap "$skill" "$sid"
    assert_eq "$fmt: after the accept the wrapper runs a real round (rc 1, not 9)" "1" "$W_RC"
}

finish() {
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" -eq 0 ]
}

#!/usr/bin/env bash
# tests/cc-pre-commit-on-demand-rules.sh
# Tests: hooks/pre-commit, bin/check-on-demand-rules.sh, hooks/lib/rules-injection-policy.js, hooks/lib/rules-policy-reader.js
# Tags: rules-injection, on-demand-rules, pre-commit, hook-wiring, backstop, exit-codes, TL2, scope:common
#
# The static checker is only as good as its invocation: every other file in this series runs bin/check-on-demand-rules.sh directly, so all stay green if the hook that's supposed to call it on every commit is never wired, wired outside the agents-repo guard, or swallows its exit code — the whole point is stopping a de-injected rule BEFORE the commit lands.
# The hook is exercised for real — actual hooks/pre-commit, in a throwaway repo that is simultaneously the repo under commit and AGENTS_CONFIG_DIR, so `_pe_is_agents_repo` resolves the same git common-dir for both and the on-demand block is genuinely reached (mirrors the fixture in tests/feature-1642-precommit-prompt-extraction.sh).
# Exit-code contract (detail plan S2-7): rc 1 (violations) and rc 2 (usage/broken invocation) -> commit BLOCKED; anything else, including a missing or non-executable checker, -> FAIL-OPEN.
# Fail-open is deliberate and differs from the prompt-extraction backstop next to it, which blocks on 126/127 — asserted, not assumed, since silent behavioural drift either way is invisible from the checker's own tests. Layer: TL2 (real hooks/pre-commit + real git, isolated fixture repos).
# TL3 gap: whether git actually invokes hooks/pre-commit via core.hooksPath on this host (executed directly here); mitigated at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRECOMMIT="$AGENTS_DIR/hooks/pre-commit"
CHECKER="$AGENTS_DIR/bin/check-on-demand-rules.sh"

PASS=0; FAIL=0; SKIPPED=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skipped() { echo "SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

# --- Tier 1: implementation-missing guard, ahead of every skip gate. --------------
MISSING=0
[ -f "$PRECOMMIT" ] || { echo "FAIL: IMPLEMENTATION MISSING: $PRECOMMIT"; MISSING=1; }
[ -f "$CHECKER" ]   || { echo "FAIL: IMPLEMENTATION MISSING: $CHECKER"; MISSING=1; }
if [ "$MISSING" -eq 0 ] && ! grep -q 'check-on-demand-rules' "$PRECOMMIT"; then
    echo "FAIL: IMPLEMENTATION MISSING: hooks/pre-commit does not invoke check-on-demand-rules.sh (detail plan S2-7)"
    MISSING=1
fi
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — detail plan S2-7)"
    exit 1
fi

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

TOKEN='.on-demand-only/never-match'
MARKER='<!-- injection: on-demand-only -->'

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
}

# mk_repo <name> <engine: real|none|noexec|<rc>> -> prints the repo path
mk_repo() {
    local name="$1" engine="$2"
    local dir="$TMPBASE/$name"
    init_repo "$dir"
    mkdir -p "$dir/hooks/lib" "$dir/bin" "$dir/rules" "$dir/skills/od-owner"
    # One-line shims: the real modules, reached from the fixture's own tree.
    printf 'module.exports = require("%s/hooks/workflow-state.js");\n' "$_AGENTS_DIR_NODE" \
        > "$dir/hooks/workflow-state.js"
    printf 'module.exports = require("%s/hooks/lib/session-markers.js");\n' "$_AGENTS_DIR_NODE" \
        > "$dir/hooks/lib/session-markers.js"
    printf 'module.exports = require("%s/hooks/lib/precommit-exclude-check.js");\n' "$_AGENTS_DIR_NODE" \
        > "$dir/hooks/lib/precommit-exclude-check.js"
    echo "// stub marker" > "$dir/hooks/enforce-worktree.js"
    printf '#!/usr/bin/env bash\nexec bash "%s/bin/check-test-frontmatter.sh" "$@"\n' "$AGENTS_DIR" \
        > "$dir/bin/check-test-frontmatter.sh"
    chmod +x "$dir/bin/check-test-frontmatter.sh"

    # The policy SSOT the checker reads. `rules/od.md` is the one registered
    # on-demand rule; `rules/plain.md` is the one registered unconditional rule.
    cat > "$dir/hooks/lib/rules-injection-policy.js" <<POLICY_EOF
"use strict";
const ON_DEMAND_TOKEN = "$TOKEN";
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_READERS = ["rules/od.md|skills/od-owner/SKILL.md"];
const EXPECTED_UNCONDITIONAL = ["rules/plain.md"];
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
POLICY_EOF
    printf -- '---\npaths:\n  - "%s"\n---\n%s\n\n# on demand\n' "$TOKEN" "$MARKER" > "$dir/rules/od.md"
    printf '# plain unconditional rule\n' > "$dir/rules/plain.md"
    # The declared reader must EXIST, or READER_TARGET_MISSING fires and every case in
    # this file inherits a violation that has nothing to do with pre-commit wiring.
    printf '# od owner\n' > "$dir/skills/od-owner/SKILL.md"

    case "$engine" in
        real)
            printf '#!/usr/bin/env bash\nexec bash "%s/bin/check-on-demand-rules.sh" "$@"\n' "$AGENTS_DIR" \
                > "$dir/bin/check-on-demand-rules.sh"
            chmod +x "$dir/bin/check-on-demand-rules.sh" ;;
        none)
            : ;;
        noexec)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/check-on-demand-rules.sh"
            chmod 000 "$dir/bin/check-on-demand-rules.sh" 2>/dev/null || true ;;
        *)
            printf '#!/usr/bin/env bash\necho "stub engine rc=%s" >&2\nexit %s\n' "$engine" "$engine" \
                > "$dir/bin/check-on-demand-rules.sh"
            chmod +x "$dir/bin/check-on-demand-rules.sh" ;;
    esac

    echo "init" > "$dir/README.md"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -q -m "initial" >/dev/null 2>&1
    echo "$dir"
}

OUT=""; RC=0
# run_precommit <repo> [ENV=VAL ...]
run_precommit() {
    local cwd="$1"; shift
    RC=0
    OUT="$( (cd "$cwd" && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 90 env "$@" bash "$PRECOMMIT") 2>&1 )" || RC=$?
}

# stage_violation <repo> [filename] — a rule carrying the on-demand marker but WITHOUT
# the reserved glob: de-injected in prose, still injected in fact.
stage_violation() {
    local repo="$1" name="${2:-rules/bad.md}"
    mkdir -p "$repo/$(dirname "$name")"
    printf -- '---\npaths:\n  - "docs/**"\n---\n%s\n\n# annotated on-demand, wrong glob\n' "$MARKER" \
        > "$repo/$name"
    git -C "$repo" add -- "$name" >/dev/null 2>&1
}

echo "=== hooks/pre-commit wiring for the on-demand rules checker ==="

# --- W1: a clean staged rule must not be blocked. Without this, a hook that blocks
# unconditionally would satisfy every other case in this file. ---
R1="$(mk_repo w1 real)"
printf -- '---\npaths:\n  - "tests/**"\n---\n\n# an ordinary conditional rule\n' > "$R1/rules/cond.md"
git -C "$R1" add -- rules/cond.md >/dev/null 2>&1
run_precommit "$R1" "AGENTS_CONFIG_DIR=$R1" "ENFORCE_WORKTREE=off"
if [ "$RC" -eq 0 ]; then
    pass "W1: a clean staged rule passes the hook (exit 0)"
else
    fail "W1: a clean staged rule was blocked (exit $RC)" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
fi

# --- W2: the violation path. The hook must block AND name the offending file —
# a bare "commit blocked" leaves the contributor guessing which rule broke. ---
R2="$(mk_repo w2 real)"
stage_violation "$R2"
run_precommit "$R2" "AGENTS_CONFIG_DIR=$R2" "ENFORCE_WORKTREE=off"
if [ "$RC" -ne 1 ]; then
    fail "W2: want exit 1 for a staged on-demand violation, got $RC" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -q 'rules/bad.md'; then
    fail "W2: blocked, but the output never names rules/bad.md" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
else
    pass "W2: a staged on-demand violation blocks the commit and names the file"
fi

# --- W3: rc=2 is a broken invocation, not a hiccup. A misinstalled checker that
# fails open is a gate that silently stops existing. ---
R3="$(mk_repo w3 2)"
stage_violation "$R3"
run_precommit "$R3" "AGENTS_CONFIG_DIR=$R3" "ENFORCE_WORKTREE=off"
if [ "$RC" -eq 1 ]; then
    pass "W3: checker rc=2 (usage error) blocks the commit"
else
    fail "W3: want the commit blocked on checker rc=2, got exit $RC" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
fi

# --- W4 / W5: the fail-open half of the contract. A developer whose checkout predates
# the checker, or whose file lost its execute bit on a Windows checkout, must still be
# able to commit — but never silently: the warning is what turns an invisible dead gate
# into something a reader notices. ---
R4="$(mk_repo w4 none)"
stage_violation "$R4"
run_precommit "$R4" "AGENTS_CONFIG_DIR=$R4" "ENFORCE_WORKTREE=off"
if [ "$RC" -ne 0 ]; then
    fail "W4: a missing checker must fail open per S2-7, got exit $RC" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -q 'check-on-demand-rules'; then
    fail "W4: failed open but said nothing — a dead gate must announce itself" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
else
    pass "W4: a missing checker fails open with a diagnostic"
fi

R5="$(mk_repo w5 noexec)"
stage_violation "$R5"
if [ -x "$R5/bin/check-on-demand-rules.sh" ]; then
    # chmod 000 is a no-op on this filesystem, so the case cannot be staged.
    skipped "W5: Skipped-Because: this filesystem ignores chmod 000, so a non-executable checker cannot be created (NTFS)"
else
    run_precommit "$R5" "AGENTS_CONFIG_DIR=$R5" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 0 ]; then
        pass "W5: a non-executable checker fails open per S2-7"
    else
        fail "W5: want fail-open for a non-executable checker, got exit $RC" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
    fi
fi

# --- W6: containment. The block is guarded by _pe_is_agents_repo; an unrelated repo
# that happens to have a rules/ directory must be untouched (CPR-UNV: no implicit
# environment branching). ---
CFG="$(mk_repo w6cfg real)"
OTHER="$TMPBASE/w6other"
init_repo "$OTHER"
echo init > "$OTHER/README.md"
git -C "$OTHER" add README.md >/dev/null 2>&1
git -C "$OTHER" commit -q -m initial >/dev/null 2>&1
stage_violation "$OTHER"
run_precommit "$OTHER" "AGENTS_CONFIG_DIR=$CFG" "ENFORCE_WORKTREE=off"
if [ "$RC" -eq 0 ]; then
    pass "W6: a foreign repo is not subjected to the on-demand check"
else
    fail "W6: the hook blocked a commit in an unrelated repo (exit $RC)" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
fi

# --- C10: hostile FILENAMES through the real hook path ----------------------------
# The staged file list travels from `git diff --cached --name-only` through the hook
# into the checker's argv. Every unquoted expansion on that route splits a name on
# whitespace, and the failure is silent in the worst way: the checker is handed two
# nonexistent paths, finds no violation in either, and the commit sails through. So a
# violating file whose name contains a space must still block, and the diagnostic must
# reproduce the name WHOLE — a report naming "rules/od" and "with" is not an
# identification, it is two wrong answers.
R7="$(mk_repo w7 real)"
SPACE_NAME='rules/bad rule with spaces.md'
stage_violation "$R7" "$SPACE_NAME"
run_precommit "$R7" "AGENTS_CONFIG_DIR=$R7" "ENFORCE_WORKTREE=off"
if [ "$RC" -ne 1 ]; then
    fail "C10-space: a violating file whose name contains spaces did not block the commit (exit $RC) — the staged list was almost certainly word-split" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
elif ! printf '%s' "$OUT" | grep -qF "$SPACE_NAME"; then
    fail "C10-space: blocked, but the output never reproduces the exact filename [$SPACE_NAME]" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
else
    pass "C10-space: a space-bearing violating filename blocks the commit and is reported whole"
fi

# Trailing and leading spaces are the same defect one step further: they survive git's
# index but are trimmed by most naive shell handling.
R8="$(mk_repo w8 real)"
EDGE_NAME='rules/ leading-and-trailing .md'
if ! (set -C; : > "$R8/$EDGE_NAME") 2>/dev/null; then
    skipped "C10-edge: Skipped-Because: this filesystem rejects leading/trailing spaces in filenames"
else
    stage_violation "$R8" "$EDGE_NAME"
    run_precommit "$R8" "AGENTS_CONFIG_DIR=$R8" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF "$EDGE_NAME"; then
        pass "C10-edge: a filename with leading and trailing spaces blocks and is reported whole"
    else
        fail "C10-edge: want exit 1 naming [$EDGE_NAME], got exit $RC" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
    fi
fi

# A newline in a filename is the strongest form of the same attack — it defeats
# line-oriented list handling, not just word splitting. NTFS forbids it outright, so
# the case is detected and recorded rather than faked with a substitute.
R9="$(mk_repo w9 real)"
NL_NAME="$(printf 'rules/bad\nname.md')"
if ! (mkdir -p "$R9/rules" && : > "$R9/$NL_NAME") 2>/dev/null; then
    skipped "C10-newline: Skipped-Because: this filesystem cannot create a filename containing a newline (NTFS forbids it); the space cases above cover the word-splitting half, and the line-splitting half remains uncovered on this host"
else
    stage_violation "$R9" "$NL_NAME"
    run_precommit "$R9" "AGENTS_CONFIG_DIR=$R9" "ENFORCE_WORKTREE=off"
    if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF "$(printf 'bad\nname.md')"; then
        pass "C10-newline: a newline-bearing violating filename blocks and is reported whole"
    else
        fail "C10-newline: want exit 1 naming the newline filename, got exit $RC" "$(printf '%s' "$OUT" | head -5 | tr '\n' ' ')"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIPPED skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

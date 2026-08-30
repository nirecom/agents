# tests/feature-2119-settings-allow-ssot/precommit.sh
# Tests: hooks/pre-commit, bin/review-settings-allow
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T8a-T8e: the hooks/pre-commit wiring, exercised the way its siblings are -- the REAL hook
# runs inside a throwaway repo that doubles as its own AGENTS_CONFIG_DIR, and the assertion
# is the hook's actual exit code.

init_fixture_repo() { # <dir>
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test"
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config core.autocrlf false
}

# An agents-like repo: identical git common-dirs make _is_agents_session_repo() treat it as
# the session repo, and the node helpers the hook loads through AGENTS_CONFIG_DIR are
# re-exported from the real checkout by one-line shims so the fixture stays tiny.
mk_hook_repo() { # <name> <review:none|real|noexec|rc0|rc3> <ssot:yes|no> <gen:yes|no> -> dir
    local dir="$TMPROOT/$1" review="$2" ssot="$3" gen="$4" n
    n="$(node_path "$AGENTS_DIR")"
    init_fixture_repo "$dir"
    mkdir -p "$dir/hooks/lib" "$dir/bin" "$dir/install"
    printf 'module.exports = require("%s/hooks/workflow-state.js");\n' "$n" > "$dir/hooks/workflow-state.js"
    printf 'module.exports = require("%s/hooks/lib/session-markers.js");\n' "$n" > "$dir/hooks/lib/session-markers.js"
    printf 'module.exports = require("%s/hooks/lib/precommit-exclude-check.js");\n' "$n" > "$dir/hooks/lib/precommit-exclude-check.js"
    printf 'module.exports = require("%s/hooks/lib/lint-commit-lang.js");\n' "$n" > "$dir/hooks/lib/lint-commit-lang.js"
    printf '%s\n' '// stub marker' > "$dir/hooks/enforce-worktree.js"
    install_review_script "$dir" "$review"
    [ "$ssot" = "yes" ] && [ -f "$SSOT" ] && cp "$SSOT" "$dir/install/settings-allow-commands.txt"
    [ "$gen" = "yes" ] && [ -f "$GEN" ] && cp "$GEN" "$dir/install/gen-settings-allow.js"
    printf '%s\n' 'init' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "initial" 2>/dev/null
    printf '%s\n' "$dir"
}

# The stub specs isolate the WIRING from the review script's own judgment (which is T9's
# subject): rc0 and rc3 pin what pre-commit does with an exit code, independent of why the
# review script produced it. `noexec` is the mode-100644 case: a reviewer that is present but
# cannot run. It is spelled as a non-executable file whose shebang also names no interpreter,
# so it fails under BOTH invocation styles -- 126/127 when the hook runs it directly, exit 3
# when the hook runs it through `bash`. `chmod 000` would be the narrower spelling, but it is
# unenforced on Windows and would break the fixture's own `git add -A`.
install_review_script() { # <dir> <spec>
    local dir="$1" f="$1/bin/review-settings-allow"
    case "$2" in
        none) return 0 ;;
        real) [ -f "$REVIEW" ] && { cp "$REVIEW" "$f"; chmod +x "$f" 2>/dev/null || true; } ;;
        noexec) printf '%s\n' '#!/nonexistent-interpreter-2119' 'exit 3' > "$f"
                chmod 644 "$f" 2>/dev/null || true ;;
        rc0) printf '%s\n' '#!/bin/bash' 'echo "## Settings Allow Review: PERFORMED"' 'exit 0' > "$f"
             chmod +x "$f" 2>/dev/null || true ;;
        *)   printf '%s\n%s\n%s%s\n' '#!/bin/bash' 'echo "## Settings Allow Review: FAIL" >&2' 'exit ' "${2#rc}" > "$f"
             chmod +x "$f" 2>/dev/null || true ;;
    esac
}

HOOK_OUT=""
HOOK_RC=0
run_precommit() { # <repo> [enforce-worktree:off|on]
    HOOK_RC=0
    HOOK_OUT="$( (cd "$1" && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID && \
        run_with_timeout 90 env "AGENTS_CONFIG_DIR=$1" "ENFORCE_WORKTREE=${2:-off}" bash "$PRECOMMIT") 2>&1 )" || HOOK_RC=$?
}

# One trivially safe staged change, so any block that appears is this gate's and not another
# scanner reacting to fixture content.
stage_trivial() { # <repo>
    printf '%s\n' 'one more line' >> "$1/README.md"
    git -C "$1" add README.md
}

# A block is only this gate's block when the hook says so. Without that distinction every row
# would also pass on a fixture that died for an unrelated reason -- which is exactly how a
# broken fixture turns a fail-closed test suite green.
hook_verdict() { # <name> <review> <ssot> <gen> -> blocked-by-gate|blocked-other|allowed|sentinel
    local repo
    if [ "$2" = "real" ] && ! have_review; then missing_review; return; fi
    repo="$(mk_hook_repo "$1" "$2" "$3" "$4")"
    stage_trivial "$repo"
    run_precommit "$repo"
    [ "$HOOK_RC" -eq 0 ] && { printf 'allowed'; return; }
    if printf '%s\n' "$HOOK_OUT" | grep -Eqi 'review-settings-allow|Settings Allow'; then
        printf 'blocked-by-gate'
    else
        printf 'blocked-other'
    fi
}

# The wiring itself, named once so that every red row below has an artifact to point at.
t8_wiring_present() {
    local got="absent"
    grep -q 'review-settings-allow' "$PRECOMMIT" 2>/dev/null && got="present"
    assert_eq "T8: hooks/pre-commit wires $REVIEW_REL (IMPLEMENTATION MISSING while absent)" \
        "present" "$got"
}

# T8e is the CONTRACT PIN. The same hooks/pre-commit hosts the on-demand-rules gate, which
# fails OPEN on an unexpected exit code on purpose (an old checkout must still commit). This
# gate is the opposite: its premise is that deleting or breaking the enforcement must not
# disable the enforcement, so every non-zero blocks. Implementing one from the other's model
# is the mistake T8e exists to catch, and T8d is the positive control that keeps "blocks
# everything" from passing as fail-closed.
t8_precommit_family() {
    local id review ssot gen want label
    while IFS='|' read -r id review ssot gen want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T8$id: $label" "$want" "$(hook_verdict "t8-$id" "$review" "$ssot" "$gen")"
    done <<'T8_CASES'
a|none|yes|yes|blocked-by-gate|the review script is absent -- a fail-closed gate cannot be disabled by deleting it
b|real|no|yes|blocked-by-gate|the SSOT is gone, so the real review script must fail and the commit must stop
c|real|yes|no|blocked-by-gate|the generator is gone -- the other way the gate's own inputs can break
d|rc0|yes|yes|allowed|exit 0 from the review script lets the commit through (positive control)
e|rc3|yes|yes|blocked-by-gate|an unexpected exit code still blocks: this gate is not the fail-open on-demand-rules gate
f|noexec|yes|yes|blocked-by-gate|the reviewer is present but cannot be executed -- the state a mode-100644 file lands in after a fresh clone
T8_CASES
}

# HARNESS CANARY. Until the gate exists every T8 row can only observe "allowed", which is
# also what a fixture that never reached the hook would report. This row proves the fixture
# really runs hooks/pre-commit and really sees a block: the same repo with ENFORCE_WORKTREE=on
# is a commit on the default branch of a main worktree, which the hook refuses.
t8_harness_canary() {
    local repo
    repo="$(mk_hook_repo t8-canary rc0 yes yes)"
    stage_trivial "$repo"
    run_precommit "$repo" on
    local got="allowed"
    [ "$HOOK_RC" -ne 0 ] && got="blocked"
    assert_eq "T8[harness-canary]: the fixture reaches the real hook and can observe a block (ENFORCE_WORKTREE=on)" \
        "blocked" "$got"
}

t8_wiring_present
t8_harness_canary
t8_precommit_family

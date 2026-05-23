#!/bin/bash
# Static grep-based checks for the confirm-flags feature wiring.
#
# Verifies that the 4 gated skills reference the helper script, the matching
# CONFIRM_* flag names exist in .env.example, both installer scripts wire
# `get-config-var` into ~/.local/bin (POSIX) / equivalent (PowerShell), and
# that legacy chat-emit / summary lines have been removed while load-bearing
# instructions are preserved.
#
# Pre-implementation: checks involving SKILL.md flag references, the helper
# command invocation, and the installer wiring are expected to FAIL.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# grep wrapper that returns 0/1 (no -q so we can suppress output uniformly)
has() {
    # has <pattern> <file>
    grep -E -- "$1" "$2" >/dev/null 2>&1
}
has_fixed() {
    grep -F -- "$1" "$2" >/dev/null 2>&1
}
count_fixed() {
    # count_fixed <fixed-string> <file>
    grep -F -c -- "$1" "$2" 2>/dev/null || echo 0
}

OUTLINE_SKILL="$REPO_ROOT/skills/make-outline-plan/SKILL.md"
DETAIL_SKILL="$REPO_ROOT/skills/make-detail-plan/SKILL.md"
WORKTREE_SKILL="$REPO_ROOT/skills/worktree-start/SKILL.md"
TESTS_SKILL="$REPO_ROOT/skills/write-tests/SKILL.md"
WRITE_CODE_SKILL="$REPO_ROOT/skills/write-code/SKILL.md"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
LINUX_LINKER="$REPO_ROOT/install/linux/dotfileslink.sh"
WIN_LINKER="$REPO_ROOT/install/win/dotfileslink.ps1"

require_file() {
    if [ ! -f "$1" ]; then
        fail "missing required file: $1"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 1. Each SKILL.md references its matching CONFIRM_* flag
# ---------------------------------------------------------------------------
echo "=== SKILL.md flag references ==="
declare -a SKILL_FLAG_PAIRS=(
    "$OUTLINE_SKILL|CONFIRM_OUTLINE"
    "$DETAIL_SKILL|CONFIRM_DETAIL"
    "$TESTS_SKILL|CONFIRM_TESTS"
    "$WORKTREE_SKILL|CONFIRM_WORKTREE"
    "$WRITE_CODE_SKILL|CONFIRM_CODE"
)
for pair in "${SKILL_FLAG_PAIRS[@]}"; do
    file="${pair%%|*}"
    flag="${pair##*|}"
    if require_file "$file"; then
        if has_fixed "$flag" "$file"; then
            pass "$flag referenced in $(basename "$(dirname "$file")")/SKILL.md"
        else
            fail "$flag missing from $file"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 2. Each gated SKILL.md invokes `get-config-var --is-off`
# ---------------------------------------------------------------------------
echo "=== SKILL.md invokes get-config-var --is-off ==="
for f in "$OUTLINE_SKILL" "$DETAIL_SKILL" "$TESTS_SKILL" "$WORKTREE_SKILL" "$WRITE_CODE_SKILL"; do
    if require_file "$f"; then
        if has_fixed "get-config-var --is-off" "$f"; then
            pass "get-config-var --is-off present in $(basename "$(dirname "$f")")/SKILL.md"
        else
            fail "get-config-var --is-off missing from $f"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 3. make-outline-plan / make-detail-plan: required new content
# ---------------------------------------------------------------------------
echo "=== make-outline-plan: required content ==="
if require_file "$OUTLINE_SKILL"; then
    for needle in "Round N: APPROVED" "outline-debug.log"; do
        if has_fixed "$needle" "$OUTLINE_SKILL"; then
            pass "outline SKILL.md contains '$needle'"
        else
            fail "outline SKILL.md missing '$needle'"
        fi
    done
fi

echo "=== make-detail-plan: required content ==="
if require_file "$DETAIL_SKILL"; then
    for needle in "Round N: APPROVED" "detail-debug.log"; do
        if has_fixed "$needle" "$DETAIL_SKILL"; then
            pass "detail SKILL.md contains '$needle'"
        else
            fail "detail SKILL.md missing '$needle'"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 4. Removed legacy content
# ---------------------------------------------------------------------------
echo "=== Removed legacy lines ==="
for f in "$OUTLINE_SKILL" "$DETAIL_SKILL"; do
    if require_file "$f"; then
        name="$(basename "$(dirname "$f")")"
        n=$(grep -F -c -- "summarizes each discussion round" "$f" 2>/dev/null | head -1)
        # Defensive: ensure n is numeric
        case "$n" in ''|*[!0-9]*) n=0;; esac
        if [ "$n" = "0" ]; then
            pass "'summarizes each discussion round' removed from $name/SKILL.md"
        else
            fail "'summarizes each discussion round' still present ($n hits) in $name/SKILL.md"
        fi
        # The legacy chat-emit was a markdown blockquote ending with "falling back
        # to Claude reviewer for this round." — that suffix is the unambiguous marker.
        for needle in "falling back to Claude reviewer for this round"; do
            if has_fixed "$needle" "$f"; then
                fail "legacy chat-emit '$needle' still present in $name/SKILL.md"
            else
                pass "legacy chat-emit '$needle' removed from $name/SKILL.md"
            fi
        done
    fi
done

# ---------------------------------------------------------------------------
# 5. Preserved instructions (outline)
# ---------------------------------------------------------------------------
echo "=== make-outline-plan: preserved instructions ==="
if require_file "$OUTLINE_SKILL"; then
    for needle in \
        "outline-planner and outline-reviewer are never shown implementation details" \
        "\`WORKFLOW_MARK_STEP_detail_complete\` is NOT emitted here" \
        "One \`AskUserQuestion\` per run"
    do
        if has_fixed "$needle" "$OUTLINE_SKILL"; then
            pass "outline SKILL.md preserves: '$needle'"
        else
            fail "outline SKILL.md MUST preserve: '$needle'"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 6. Preserved instructions (detail)
# ---------------------------------------------------------------------------
echo "=== make-detail-plan: preserved instructions ==="
if require_file "$DETAIL_SKILL"; then
    for needle in \
        "Read before planning" \
        "Follow \`rules/core-principles.md\`" \
        "One user-facing confirmation per run"
    do
        if has_fixed "$needle" "$DETAIL_SKILL"; then
            pass "detail SKILL.md preserves: '$needle'"
        else
            fail "detail SKILL.md MUST preserve: '$needle'"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 7. worktree-start step 2 still uses AskUserQuestion
# ---------------------------------------------------------------------------
echo "=== worktree-start: AskUserQuestion still present ==="
if require_file "$WORKTREE_SKILL"; then
    if has_fixed "AskUserQuestion" "$WORKTREE_SKILL"; then
        pass "worktree-start/SKILL.md still references AskUserQuestion"
    else
        fail "worktree-start/SKILL.md no longer references AskUserQuestion"
    fi
fi

# ---------------------------------------------------------------------------
# 8. .env.example has all 4 CONFIRM_* keys
# ---------------------------------------------------------------------------
echo "=== .env.example: all CONFIRM_* keys present ==="
if require_file "$ENV_EXAMPLE"; then
    for key in CONFIRM_OUTLINE CONFIRM_DETAIL CONFIRM_TESTS CONFIRM_WORKTREE CONFIRM_CODE; do
        # Match `KEY=` at start of line (allow leading whitespace)
        if grep -E "^[[:space:]]*${key}=" "$ENV_EXAMPLE" >/dev/null 2>&1; then
            pass ".env.example defines $key"
        else
            fail ".env.example missing $key (expected '$key=...')"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 9. Both installers reference get-config-var
# ---------------------------------------------------------------------------
echo "=== Installer scripts wire get-config-var ==="
if require_file "$LINUX_LINKER"; then
    if has_fixed "get-config-var" "$LINUX_LINKER"; then
        pass "install/linux/dotfileslink.sh references get-config-var"
    else
        fail "install/linux/dotfileslink.sh missing get-config-var reference"
    fi
fi
if require_file "$WIN_LINKER"; then
    if has_fixed "get-config-var" "$WIN_LINKER"; then
        pass "install/win/dotfileslink.ps1 references get-config-var"
    else
        fail "install/win/dotfileslink.ps1 missing get-config-var reference"
    fi
fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All static checks passed."
    exit 0
else
    echo "$ERRORS check(s) failed."
    exit 1
fi

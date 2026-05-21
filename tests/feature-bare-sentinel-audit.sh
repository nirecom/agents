#!/bin/bash
# tests/feature-bare-sentinel-audit.sh
#
# #404 Grep audit gate: bare-form sentinel references must only appear in files
# that are explicitly allowlisted (LOOKSLIKE handlers, negative-test fixtures,
# append-only history, etc.). Any new occurrence of a bare form anywhere else
# in the tracked repo is a regression.
#
# Bare patterns audited (no `: <reason>` suffix):
#   <<WORKFLOW_USER_VERIFIED>>
#   <<WORKFLOW_ENFORCE_WORKTREE_OFF>>
#   <<WORKFLOW_ENFORCE_WORKTREE_ON>>

set -uo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ALLOWLIST_FILE="$DOTFILES_DIR/tests/expected-bare-sentinel-allowlist.txt"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

if [ ! -f "$ALLOWLIST_FILE" ]; then
    echo "FATAL: allowlist not found at $ALLOWLIST_FILE"
    exit 2
fi

# Bare-form regex: name immediately followed by `>>` (no `: <reason>`).
PATTERN='<<WORKFLOW_(USER_VERIFIED|ENFORCE_WORKTREE_(OFF|ON))>>'

# Load allowlist into a normalized set (forward slashes, no CR).
declare -A ALLOWED
while IFS= read -r line || [ -n "$line" ]; do
    # Strip CR and surrounding whitespace.
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
        ''|'#'*) continue ;;
    esac
    ALLOWED["$line"]=1
done < "$ALLOWLIST_FILE"

# Enumerate tracked files; collect those that contain any bare form.
TRACKED_FILES=$(run_with_timeout git -C "$DOTFILES_DIR" ls-files)
if [ -z "$TRACKED_FILES" ]; then
    fail "audit: git ls-files returned no tracked files"
    exit 1
fi

HITS_FILE="$(mktemp)"
trap 'rm -f "$HITS_FILE"' EXIT

# Per-file grep so we get a clean list of file paths regardless of whitespace.
while IFS= read -r f || [ -n "$f" ]; do
    [ -z "$f" ] && continue
    [ -f "$DOTFILES_DIR/$f" ] || continue
    if grep -lE "$PATTERN" "$DOTFILES_DIR/$f" >/dev/null 2>&1; then
        # Normalize to forward slashes.
        printf '%s\n' "${f//\\//}" >> "$HITS_FILE"
    fi
done <<< "$TRACKED_FILES"

UNEXPECTED=0
while IFS= read -r hit || [ -n "$hit" ]; do
    [ -z "$hit" ] && continue
    if [ -z "${ALLOWED[$hit]+_}" ]; then
        fail "unexpected bare-sentinel occurrence: $hit"
        UNEXPECTED=$((UNEXPECTED + 1))
    fi
done < "$HITS_FILE"

if [ "$UNEXPECTED" -eq 0 ]; then
    pass "audit: every bare-sentinel occurrence is in the allowlist"
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "All audit checks passed!"
    exit 0
else
    echo "$ERRORS audit check(s) failed"
    exit 1
fi

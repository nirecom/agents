#!/usr/bin/env bash
# Tests for bin/convert-history-table.py generic column handling
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/convert-history-table.py"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass=0
fail=0

strip_trailing() {
    # Remove trailing whitespace/newlines (normalize for $() stripping)
    printf '%s' "$1" | sed -e 's/[[:space:]]*$//'
}

assert_eq() {
    local name="$1" expected actual
    expected="$(strip_trailing "$2")"
    actual="$(strip_trailing "$3")"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $name"
        ((pass++))
    else
        echo "FAIL: $name"
        echo "--- expected ---"
        echo "$expected"
        echo "--- actual ---"
        echo "$actual"
        echo "---"
        ((fail++))
    fi
}

run_convert() {
    local input_file="$1"
    # Script reads from docs/history.md relative to its own location,
    # so we create a temporary structure
    local fake_root="$TMPDIR_TEST/run_$$_$RANDOM"
    mkdir -p "$fake_root/bin" "$fake_root/docs"
    cp "$SCRIPT" "$fake_root/bin/convert-history-table.py"
    cp "$input_file" "$fake_root/docs/history.md"
    uv run python "$fake_root/bin/convert-history-table.py"
}

# -------------------------------------------------------
# Normal: 3-column table (Change | Description | Key Commits)
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_3col.md" << 'HEREDOC'
# Change History

This file tracks changes.

| Change | Description | Key Commits |
|:---|:---|:---|
| Initial migration | Moved specs from ai-prompts | b7ddb49 |
| Security policy | Added security-policy.md | a85903b |
HEREDOC

expected_3col='# Change History

This file tracks changes.

### Initial migration (b7ddb49)
Description: Moved specs from ai-prompts

### Security policy (a85903b)
Description: Added security-policy.md
'

actual_3col="$(run_convert "$TMPDIR_TEST/input_3col.md")"
assert_eq "3-column table" "$expected_3col" "$actual_3col"

# -------------------------------------------------------
# Normal: 4-column table (Phase | User Request | Implementation | Key Commits)
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_4col.md" << 'HEREDOC'
# Change History

## Change History

| Phase | User Request | Implementation | Key Commits |
|:---|:---|:---|:---|
| Phase 1 | Add auth | Implemented OAuth | abc1234 |
HEREDOC

expected_4col='# Change History

## Change History

### Phase 1 (abc1234)
User Request: Add auth
Implementation: Implemented OAuth
'

actual_4col="$(run_convert "$TMPDIR_TEST/input_4col.md")"
assert_eq "4-column table" "$expected_4col" "$actual_4col"

# -------------------------------------------------------
# Normal: 5-column incident table (# | Incident | Cause | Fix | Commit)
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_incident.md" << 'HEREDOC'
# History

## Incident History

| # | Incident | Cause | Fix | Commit |
|:---|:---|:---|:---|:---|
| 1 | Server crash | OOM | Added memory limit | def5678 |
| 2 | Slow query | Missing index | Added index | ghi9012 |
HEREDOC

expected_incident='# History

## Incident History

### #1: Server crash (def5678)
Cause: OOM
Fix: Added memory limit

### #2: Slow query (ghi9012)
Cause: Missing index
Fix: Added index
'

actual_incident="$(run_convert "$TMPDIR_TEST/input_incident.md")"
assert_eq "5-column incident table" "$expected_incident" "$actual_incident"

# -------------------------------------------------------
# Normal: Both Change History and Incident History
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_both.md" << 'HEREDOC'
# History

## Change History

| Change | Description | Key Commits |
|:---|:---|:---|
| Feature A | Added feature | aaa1111 |

## Incident History

| # | Incident | Cause | Fix | Commit |
|:---|:---|:---|:---|:---|
| 1 | Bug X | Race condition | Added lock | bbb2222 |
HEREDOC

expected_both='# History

## Change History

### Feature A (aaa1111)
Description: Added feature

## Incident History

### #1: Bug X (bbb2222)
Cause: Race condition
Fix: Added lock
'

actual_both="$(run_convert "$TMPDIR_TEST/input_both.md")"
assert_eq "Both change and incident tables" "$expected_both" "$actual_both"

# -------------------------------------------------------
# Edge: No commit column
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_nocommit.md" << 'HEREDOC'
# History

## Change History

| Change | Description |
|:---|:---|
| Refactor | Cleaned up code |
HEREDOC

expected_nocommit='# History

## Change History

### Refactor
Description: Cleaned up code
'

actual_nocommit="$(run_convert "$TMPDIR_TEST/input_nocommit.md")"
assert_eq "No commit column" "$expected_nocommit" "$actual_nocommit"

# -------------------------------------------------------
# Edge: # numbering column
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_numbered.md" << 'HEREDOC'
# History

## Change History

| # | Change | Details | Key Commits |
|:---|:---|:---|:---|
| 1 | Migration | Moved files | ccc3333 |
HEREDOC

expected_numbered='# History

## Change History

### #1: Migration (ccc3333)
Details: Moved files
'

actual_numbered="$(run_convert "$TMPDIR_TEST/input_numbered.md")"
assert_eq "# numbering column" "$expected_numbered" "$actual_numbered"

# -------------------------------------------------------
# Edge: 1 column only (title)
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_1col.md" << 'HEREDOC'
# History

## Change History

| Change |
|:---|
| Initial setup |
HEREDOC

expected_1col='# History

## Change History

### Initial setup
'

actual_1col="$(run_convert "$TMPDIR_TEST/input_1col.md")"
assert_eq "1 column only" "$expected_1col" "$actual_1col"

# -------------------------------------------------------
# Edge: Empty table (header + separator only)
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_empty.md" << 'HEREDOC'
# History

## Change History

| Change | Description | Key Commits |
|:---|:---|:---|
HEREDOC

expected_empty='# History

## Change History
'

actual_empty="$(run_convert "$TMPDIR_TEST/input_empty.md")"
assert_eq "Empty table" "$expected_empty" "$actual_empty"

# -------------------------------------------------------
# Edge: Non-table text preserved throughout
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_preserve.md" << 'HEREDOC'
# History

Intro paragraph here.

## Change History

Some context about changes.

| Change | Key Commits |
|:---|:---|
| Feature X | ddd4444 |

## Notes

This section has no table and should be preserved as-is.

More notes here.
HEREDOC

expected_preserve='# History

Intro paragraph here.

## Change History

Some context about changes.

### Feature X (ddd4444)

## Notes

This section has no table and should be preserved as-is.

More notes here.
'

actual_preserve="$(run_convert "$TMPDIR_TEST/input_preserve.md")"
assert_eq "Non-table text preserved" "$expected_preserve" "$actual_preserve"

# -------------------------------------------------------
# Idempotency: Already section format (no table)
# -------------------------------------------------------
cat > "$TMPDIR_TEST/input_already.md" << 'HEREDOC'
# History

## Change History

### Feature A (aaa1111)
Background: Needed feature
Changes: Added it
HEREDOC

expected_already='# History

## Change History

### Feature A (aaa1111)
Background: Needed feature
Changes: Added it
'

actual_already="$(run_convert "$TMPDIR_TEST/input_already.md")"
assert_eq "Already section format (idempotent)" "$expected_already" "$actual_already"

# -------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

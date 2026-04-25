#!/bin/bash
# Smoke tests for agents repo split step 2 changes.
# Verifies: AGENTS_CONFIG_DIR/AGENTS_DIR exports in .profile_common and profile.ps1,
#           settings.json hook path migration (old path gone, new path present).
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$DOTFILES_DIR/claude-global/settings.json"
PROFILE_COMMON="$DOTFILES_DIR/.profile_common"
PROFILE_PS1="$DOTFILES_DIR/install/win/profile.ps1"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

for f in "$SETTINGS" "$PROFILE_COMMON" "$PROFILE_PS1"; do
    if [ ! -f "$f" ]; then
        echo "FATAL: required file not found: $f"
        exit 2
    fi
done

# ---------------------------------------------------------------------------
# N1: settings.json has 0 occurrences of old path $DOTFILES_DIR/claude-global/hooks/
# ---------------------------------------------------------------------------
echo ""
echo "=== N1: settings.json — old path absent ==="

OLD_COUNT=$(grep -o '\$DOTFILES_DIR/claude-global/hooks/' "$SETTINGS" 2>/dev/null | wc -l || true)
if [ "$OLD_COUNT" -eq 0 ]; then
    pass "N1. settings.json contains 0 occurrences of \$DOTFILES_DIR/claude-global/hooks/"
else
    fail "N1. settings.json still contains $OLD_COUNT occurrence(s) of \$DOTFILES_DIR/claude-global/hooks/ (expected 0)"
fi

# ---------------------------------------------------------------------------
# N2: settings.json has exactly 11 occurrences of $AGENTS_CONFIG_DIR/hooks/
# ---------------------------------------------------------------------------
echo ""
echo "=== N2: settings.json — new path count ==="

NEW_COUNT=$(grep -o '\$AGENTS_CONFIG_DIR/hooks/' "$SETTINGS" 2>/dev/null | wc -l || true)
if [ "$NEW_COUNT" -eq 11 ]; then
    pass "N2. settings.json contains exactly 11 occurrences of \$AGENTS_CONFIG_DIR/hooks/"
else
    fail "N2. settings.json contains $NEW_COUNT occurrence(s) of \$AGENTS_CONFIG_DIR/hooks/ (expected 11)"
fi

# ---------------------------------------------------------------------------
# N3: .profile_common exports AGENTS_CONFIG_DIR with :-$DOTFILES_DIR/claude-global fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N3: .profile_common — export AGENTS_CONFIG_DIR ==="

if grep -qE 'export AGENTS_CONFIG_DIR=.*:-.*DOTFILES_DIR.*claude-global' "$PROFILE_COMMON"; then
    pass "N3. .profile_common exports AGENTS_CONFIG_DIR with :-\$DOTFILES_DIR/claude-global fallback"
else
    fail "N3. .profile_common does not export AGENTS_CONFIG_DIR with expected fallback"
fi

# ---------------------------------------------------------------------------
# N4: .profile_common exports AGENTS_DIR with :-$DOTFILES_DIR fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N4: .profile_common — export AGENTS_DIR ==="

if grep -qE 'export AGENTS_DIR=.*:-.*DOTFILES_DIR[^/]' "$PROFILE_COMMON"; then
    pass "N4. .profile_common exports AGENTS_DIR with :-\$DOTFILES_DIR fallback"
else
    fail "N4. .profile_common does not export AGENTS_DIR with expected fallback"
fi

# ---------------------------------------------------------------------------
# N5: profile.ps1 sets $env:AGENTS_CONFIG_DIR with $DotfilesDir\claude-global fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N5: profile.ps1 — \$env:AGENTS_CONFIG_DIR ==="

if grep -qE '\$env:AGENTS_CONFIG_DIR.*=.*DotfilesDir.*claude-global' "$PROFILE_PS1"; then
    pass "N5. profile.ps1 sets \$env:AGENTS_CONFIG_DIR with \$DotfilesDir\\claude-global fallback"
else
    fail "N5. profile.ps1 does not set \$env:AGENTS_CONFIG_DIR with expected fallback"
fi

# ---------------------------------------------------------------------------
# N6: profile.ps1 sets $env:AGENTS_DIR with $DotfilesDir fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N6: profile.ps1 — \$env:AGENTS_DIR ==="

if grep -qE '\$env:AGENTS_DIR[[:space:]]*=.*DotfilesDir' "$PROFILE_PS1"; then
    pass "N6. profile.ps1 sets \$env:AGENTS_DIR with \$DotfilesDir fallback"
else
    fail "N6. profile.ps1 does not set \$env:AGENTS_DIR with expected fallback"
fi

# ---------------------------------------------------------------------------
# E1: .profile_common compat block appears AFTER export DOTFILES_DIR line
# ---------------------------------------------------------------------------
echo ""
echo "=== E1: .profile_common — AGENTS_CONFIG_DIR defined after DOTFILES_DIR ==="

DOTFILES_DIR_LINE=$(grep -n 'export DOTFILES_DIR=' "$PROFILE_COMMON" | head -1 | cut -d: -f1)
AGENTS_CONFIG_LINE=$(grep -n 'export AGENTS_CONFIG_DIR=' "$PROFILE_COMMON" | head -1 | cut -d: -f1)

if [ -n "$DOTFILES_DIR_LINE" ] && [ -n "$AGENTS_CONFIG_LINE" ] && [ "$AGENTS_CONFIG_LINE" -gt "$DOTFILES_DIR_LINE" ]; then
    pass "E1. AGENTS_CONFIG_DIR (line $AGENTS_CONFIG_LINE) appears after DOTFILES_DIR (line $DOTFILES_DIR_LINE)"
else
    fail "E1. AGENTS_CONFIG_DIR (line ${AGENTS_CONFIG_LINE:-?}) does not appear after DOTFILES_DIR (line ${DOTFILES_DIR_LINE:-?})"
fi

# ---------------------------------------------------------------------------
# E2: profile.ps1 compat block appears AFTER $env:DOTFILES_DIR = $DotfilesDir line
# ---------------------------------------------------------------------------
echo ""
echo "=== E2: profile.ps1 — AGENTS_CONFIG_DIR defined after \$env:DOTFILES_DIR ==="

DOTFILES_ENV_LINE=$(grep -n '\$env:DOTFILES_DIR' "$PROFILE_PS1" | head -1 | cut -d: -f1)
AGENTS_PS1_LINE=$(grep -n '\$env:AGENTS_CONFIG_DIR' "$PROFILE_PS1" | head -1 | cut -d: -f1)

if [ -n "$DOTFILES_ENV_LINE" ] && [ -n "$AGENTS_PS1_LINE" ] && [ "$AGENTS_PS1_LINE" -gt "$DOTFILES_ENV_LINE" ]; then
    pass "E2. \$env:AGENTS_CONFIG_DIR (line $AGENTS_PS1_LINE) appears after \$env:DOTFILES_DIR (line $DOTFILES_ENV_LINE)"
else
    fail "E2. \$env:AGENTS_CONFIG_DIR (line ${AGENTS_PS1_LINE:-?}) does not appear after \$env:DOTFILES_DIR (line ${DOTFILES_ENV_LINE:-?})"
fi

# ---------------------------------------------------------------------------
# E3: settings.json is valid JSON
# ---------------------------------------------------------------------------
echo ""
echo "=== E3: settings.json — valid JSON ==="

if node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" -- "$SETTINGS" 2>/dev/null; then
    pass "E3. settings.json is valid JSON"
else
    fail "E3. settings.json failed JSON parse"
fi

# ---------------------------------------------------------------------------
# N7: pre-commit uses AGENTS_CONFIG_DIR to locate scanner (no old DOTFILES_DIR path)
# ---------------------------------------------------------------------------
echo ""
echo "=== N7: pre-commit — scanner path uses AGENTS_CONFIG_DIR ==="

PRE_COMMIT="$DOTFILES_DIR/claude-global/hooks/pre-commit"
if grep -q '_cfg_dir.*AGENTS_CONFIG_DIR' "$PRE_COMMIT" && grep -q 'SCANNER=.*_cfg_dir.*bin/scan-outbound' "$PRE_COMMIT"; then
    pass "N7. pre-commit uses AGENTS_CONFIG_DIR to locate scan-outbound.sh"
else
    fail "N7. pre-commit does not use AGENTS_CONFIG_DIR for scanner path"
fi

# ---------------------------------------------------------------------------
# N8: commit-msg uses AGENTS_CONFIG_DIR to locate scanner
# ---------------------------------------------------------------------------
echo ""
echo "=== N8: commit-msg — scanner path uses AGENTS_CONFIG_DIR ==="

COMMIT_MSG="$DOTFILES_DIR/claude-global/hooks/commit-msg"
if grep -q '_cfg_dir.*AGENTS_CONFIG_DIR' "$COMMIT_MSG" && grep -q 'SCANNER=.*_cfg_dir.*bin/scan-outbound' "$COMMIT_MSG"; then
    pass "N8. commit-msg uses AGENTS_CONFIG_DIR to locate scan-outbound.sh"
else
    fail "N8. commit-msg does not use AGENTS_CONFIG_DIR for scanner path"
fi

# ---------------------------------------------------------------------------
# N9: scan-outbound.sh uses DOTFILES_PRIVATE_DIR optional fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N9: scan-outbound.sh — dotfiles-private uses DOTFILES_PRIVATE_DIR fallback ==="

SCAN_OUTBOUND="$DOTFILES_DIR/bin/scan-outbound.sh"
if grep -q 'DOTFILES_PRIVATE_DIR:-' "$SCAN_OUTBOUND"; then
    pass "N9. scan-outbound.sh uses \${DOTFILES_PRIVATE_DIR:-...} fallback for private allowlist"
else
    fail "N9. scan-outbound.sh does not use DOTFILES_PRIVATE_DIR fallback"
fi

# ---------------------------------------------------------------------------
# N10: .profile_common session-sync uses AGENTS_DIR fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N10: .profile_common — session-sync uses AGENTS_DIR ==="

if grep -q 'AGENTS_DIR.*DOTFILES_DIR.*bin/session-sync' "$PROFILE_COMMON"; then
    pass "N10. .profile_common session-sync uses \${AGENTS_DIR:-\$DOTFILES_DIR}/bin/session-sync.sh"
else
    fail "N10. .profile_common session-sync does not use AGENTS_DIR fallback"
fi

# ===========================================================================
# split-history.py tests (N11–N15, E4–E6, I1, ER1–ER2)
# Each test creates its own isolated tmpdir and cleans up on exit.
# ===========================================================================

SPLIT_SCRIPT="$DOTFILES_DIR/bin/split-history.py"

if [ ! -f "$SPLIT_SCRIPT" ]; then
    echo "FATAL: bin/split-history.py not found: $SPLIT_SCRIPT"
    exit 2
fi

# Helper: set up a scratch repo tree under a given tmpdir
#   setup_split_tree <tmpdir> <history_content> <classification_content>
setup_split_tree() {
    local td="$1"
    local hist="$2"
    local cls="$3"
    mkdir -p "$td/bin" "$td/docs"
    cp "$SPLIT_SCRIPT" "$td/bin/split-history.py"
    printf '%s' "$hist" > "$td/docs/history.md"
    printf '%s' "$cls" > "$td/docs/history-classification.md"
}

# ---------------------------------------------------------------------------
# N11: 2 @claude + 1 @dotfiles → agents=2, dotfiles=1
# ---------------------------------------------------------------------------
echo ""
echo "=== N11: split-history.py — 2 @claude + 1 @dotfiles ==="

_n11_td=$(mktemp -d)
trap 'rm -rf "$_n11_td"' EXIT

_n11_hist="# History

### Alpha feature

Alpha body.

### Beta feature

Beta body.

### Gamma feature

Gamma body.
"
_n11_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Alpha feature | @claude |
| 2 | Beta feature | @claude |
| 3 | Gamma feature | @dotfiles |
"

setup_split_tree "$_n11_td" "$_n11_hist" "$_n11_cls"

if uv run "$_n11_td/bin/split-history.py" > /dev/null 2>&1; then
    _n11_agents=$(grep -c '^### ' "$_n11_td/docs/history-agents.md" 2>/dev/null || echo 0)
    _n11_dotfiles=$(grep -c '^### ' "$_n11_td/docs/history-dotfiles.md" 2>/dev/null || echo 0)
    if [ "$_n11_agents" -eq 2 ] && [ "$_n11_dotfiles" -eq 1 ]; then
        pass "N11. agents=2, dotfiles=1 for 2 @claude + 1 @dotfiles"
    else
        fail "N11. expected agents=2 dotfiles=1, got agents=$_n11_agents dotfiles=$_n11_dotfiles"
    fi
else
    fail "N11. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n11_td"

# ---------------------------------------------------------------------------
# N12: @both entry appears in both outputs
# ---------------------------------------------------------------------------
echo ""
echo "=== N12: split-history.py — @both appears in both outputs ==="

_n12_td=$(mktemp -d)
trap 'rm -rf "$_n12_td"' EXIT

_n12_hist="# History

### Shared work

Shared body.
"
_n12_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Shared work | @both |
"

setup_split_tree "$_n12_td" "$_n12_hist" "$_n12_cls"

if uv run "$_n12_td/bin/split-history.py" > /dev/null 2>&1; then
    _n12_agents=$(grep -c '^### ' "$_n12_td/docs/history-agents.md" 2>/dev/null || echo 0)
    _n12_dotfiles=$(grep -c '^### ' "$_n12_td/docs/history-dotfiles.md" 2>/dev/null || echo 0)
    if [ "$_n12_agents" -eq 1 ] && [ "$_n12_dotfiles" -eq 1 ]; then
        pass "N12. @both entry appears in both agents and dotfiles outputs"
    else
        fail "N12. expected agents=1 dotfiles=1, got agents=$_n12_agents dotfiles=$_n12_dotfiles"
    fi
else
    fail "N12. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n12_td"

# ---------------------------------------------------------------------------
# N13: INCIDENT: #N: in history matches INCIDENT #N: in classification
# ---------------------------------------------------------------------------
echo ""
echo "=== N13: split-history.py — INCIDENT: #N: normalized for matching ==="

_n13_td=$(mktemp -d)
trap 'rm -rf "$_n13_td"' EXIT

_n13_hist="# History

### INCIDENT: #1: Server outage

Outage details.
"
# Classification uses normalized form (without colon after INCIDENT)
_n13_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | INCIDENT #1: Server outage | @claude |
"

setup_split_tree "$_n13_td" "$_n13_hist" "$_n13_cls"

if uv run "$_n13_td/bin/split-history.py" > /dev/null 2>&1; then
    _n13_agents=$(grep -c '^### ' "$_n13_td/docs/history-agents.md" 2>/dev/null || echo 0)
    if [ "$_n13_agents" -eq 1 ]; then
        pass "N13. INCIDENT: #N: in history matched INCIDENT #N: in classification"
    else
        fail "N13. expected agents=1, got agents=$_n13_agents (INCIDENT normalization may have failed)"
    fi
else
    fail "N13. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n13_td"

# ---------------------------------------------------------------------------
# N14: Date suffix in history header stripped before matching
# ---------------------------------------------------------------------------
echo ""
echo "=== N14: split-history.py — date suffix stripped before matching ==="

_n14_td=$(mktemp -d)
trap 'rm -rf "$_n14_td"' EXIT

_n14_hist="# History

### Deploy pipeline (2026-04-12, abc1234)

Pipeline body.
"
# Classification key has no date suffix
_n14_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Deploy pipeline | @claude |
"

setup_split_tree "$_n14_td" "$_n14_hist" "$_n14_cls"

if uv run "$_n14_td/bin/split-history.py" > /dev/null 2>&1; then
    _n14_agents=$(grep -c '^### ' "$_n14_td/docs/history-agents.md" 2>/dev/null || echo 0)
    if [ "$_n14_agents" -eq 1 ]; then
        pass "N14. date suffix stripped; entry matched classification key without date"
    else
        fail "N14. expected agents=1, got agents=$_n14_agents (date suffix stripping may have failed)"
    fi
else
    fail "N14. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n14_td"

# ---------------------------------------------------------------------------
# N15: Multi-line body preserved in output
# ---------------------------------------------------------------------------
echo ""
echo "=== N15: split-history.py — multi-line body preserved ==="

_n15_td=$(mktemp -d)
trap 'rm -rf "$_n15_td"' EXIT

_n15_hist="# History

### Multi-line entry

Background: This has multiple lines.
Changes:
- Line one
- Line two
- Line three
"
_n15_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Multi-line entry | @claude |
"

setup_split_tree "$_n15_td" "$_n15_hist" "$_n15_cls"

if uv run "$_n15_td/bin/split-history.py" > /dev/null 2>&1; then
    # Check that specific body lines appear in the agents output
    if grep -q 'Line one' "$_n15_td/docs/history-agents.md" && \
       grep -q 'Line two' "$_n15_td/docs/history-agents.md" && \
       grep -q 'Line three' "$_n15_td/docs/history-agents.md"; then
        pass "N15. multi-line body fully preserved in agents output"
    else
        fail "N15. body lines missing from agents output"
    fi
else
    fail "N15. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n15_td"

# ---------------------------------------------------------------------------
# E4: Empty history → header-only output (no entries)
# ---------------------------------------------------------------------------
echo ""
echo "=== E4: split-history.py — empty history → header-only output ==="

_e4_td=$(mktemp -d)
trap 'rm -rf "$_e4_td"' EXIT

_e4_hist="# History

"
# Classification must be non-empty or script returns early with error
_e4_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Placeholder | @dotfiles |
"

setup_split_tree "$_e4_td" "$_e4_hist" "$_e4_cls"

if uv run "$_e4_td/bin/split-history.py" > /dev/null 2>&1; then
    _e4_agents_entries=$(grep -c '^### ' "$_e4_td/docs/history-agents.md" 2>/dev/null || true)
    _e4_dotfiles_entries=$(grep -c '^### ' "$_e4_td/docs/history-dotfiles.md" 2>/dev/null || true)
    _e4_agents_entries="${_e4_agents_entries:-0}"
    _e4_dotfiles_entries="${_e4_dotfiles_entries:-0}"
    if [ "$_e4_agents_entries" -eq 0 ] && [ "$_e4_dotfiles_entries" -eq 0 ]; then
        pass "E4. empty history produces header-only output (0 entries in both files)"
    else
        fail "E4. expected 0 entries, got agents=$_e4_agents_entries dotfiles=$_e4_dotfiles_entries"
    fi
else
    fail "E4. script exited non-zero on empty history"
fi

trap - EXIT
rm -rf "$_e4_td"

# ---------------------------------------------------------------------------
# E5: Single entry goes to the correct file
# ---------------------------------------------------------------------------
echo ""
echo "=== E5: split-history.py — single entry goes to correct file ==="

_e5_td=$(mktemp -d)
trap 'rm -rf "$_e5_td"' EXIT

_e5_hist="# History

### Solo entry

Solo body.
"
_e5_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Solo entry | @dotfiles |
"

setup_split_tree "$_e5_td" "$_e5_hist" "$_e5_cls"

if uv run "$_e5_td/bin/split-history.py" > /dev/null 2>&1; then
    _e5_agents=$(grep -c '^### ' "$_e5_td/docs/history-agents.md" 2>/dev/null || true)
    _e5_dotfiles=$(grep -c '^### ' "$_e5_td/docs/history-dotfiles.md" 2>/dev/null || true)
    _e5_agents="${_e5_agents:-0}"
    _e5_dotfiles="${_e5_dotfiles:-0}"
    if [ "$_e5_agents" -eq 0 ] && [ "$_e5_dotfiles" -eq 1 ]; then
        pass "E5. single @dotfiles entry goes only to dotfiles output (agents=0)"
    else
        fail "E5. expected agents=0 dotfiles=1, got agents=$_e5_agents dotfiles=$_e5_dotfiles"
    fi
else
    fail "E5. script exited non-zero"
fi

trap - EXIT
rm -rf "$_e5_td"

# ---------------------------------------------------------------------------
# E6: Unmatched entry → @dotfiles + warning to stderr
# ---------------------------------------------------------------------------
echo ""
echo "=== E6: split-history.py — unmatched entry → @dotfiles + stderr warning ==="

_e6_td=$(mktemp -d)
trap 'rm -rf "$_e6_td"' EXIT

_e6_hist="# History

### Unclassified work

Some body.
"
# Classification does NOT include "Unclassified work"
_e6_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Something else | @claude |
"

setup_split_tree "$_e6_td" "$_e6_hist" "$_e6_cls"

_e6_stderr=$(uv run "$_e6_td/bin/split-history.py" 2>&1 >/dev/null || true)
_e6_dotfiles=$(grep -c '^### ' "$_e6_td/docs/history-dotfiles.md" 2>/dev/null || true)
_e6_agents=$(grep -c '^### ' "$_e6_td/docs/history-agents.md" 2>/dev/null || true)
_e6_dotfiles="${_e6_dotfiles:-0}"
_e6_agents="${_e6_agents:-0}"

_e6_ok=1
if [ "$_e6_dotfiles" -ne 1 ]; then
    fail "E6. expected unmatched entry in dotfiles (count=1), got $_e6_dotfiles"
    _e6_ok=0
fi
if [ "$_e6_agents" -ne 0 ]; then
    fail "E6. expected unmatched entry NOT in agents (count=0), got $_e6_agents"
    _e6_ok=0
fi
if ! echo "$_e6_stderr" | grep -qi 'unmatched\|WARNING'; then
    fail "E6. expected WARNING on stderr for unmatched entry, got: $_e6_stderr"
    _e6_ok=0
fi
if [ "$_e6_ok" -eq 1 ]; then
    pass "E6. unmatched entry defaulted to @dotfiles and warning printed to stderr"
fi

trap - EXIT
rm -rf "$_e6_td"

# ---------------------------------------------------------------------------
# I1: Second run produces byte-identical output (idempotency)
# ---------------------------------------------------------------------------
echo ""
echo "=== I1: split-history.py — idempotent (second run identical output) ==="

_i1_td=$(mktemp -d)
trap 'rm -rf "$_i1_td"' EXIT

_i1_hist="# History

### Idempotent entry

Body text.
"
_i1_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Idempotent entry | @both |
"

setup_split_tree "$_i1_td" "$_i1_hist" "$_i1_cls"

# First run
uv run "$_i1_td/bin/split-history.py" > /dev/null 2>&1

# Capture checksums after first run
_i1_agents_sum1=$(md5sum "$_i1_td/docs/history-agents.md" 2>/dev/null | cut -d' ' -f1)
_i1_dotfiles_sum1=$(md5sum "$_i1_td/docs/history-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

# Second run
uv run "$_i1_td/bin/split-history.py" > /dev/null 2>&1

_i1_agents_sum2=$(md5sum "$_i1_td/docs/history-agents.md" 2>/dev/null | cut -d' ' -f1)
_i1_dotfiles_sum2=$(md5sum "$_i1_td/docs/history-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

if [ "$_i1_agents_sum1" = "$_i1_agents_sum2" ] && [ "$_i1_dotfiles_sum1" = "$_i1_dotfiles_sum2" ]; then
    pass "I1. second run produces byte-identical output (idempotent)"
else
    fail "I1. output differs between runs (not idempotent)"
fi

trap - EXIT
rm -rf "$_i1_td"

# ---------------------------------------------------------------------------
# ER1: Missing history.md → exit 1
# ---------------------------------------------------------------------------
echo ""
echo "=== ER1: split-history.py — missing history.md → exit 1 ==="

_er1_td=$(mktemp -d)
trap 'rm -rf "$_er1_td"' EXIT

_er1_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Something | @claude |
"

mkdir -p "$_er1_td/bin" "$_er1_td/docs"
cp "$SPLIT_SCRIPT" "$_er1_td/bin/split-history.py"
# Write only classification, no history.md
printf '%s' "$_er1_cls" > "$_er1_td/docs/history-classification.md"

if uv run "$_er1_td/bin/split-history.py" > /dev/null 2>&1; then
    fail "ER1. expected exit 1 when history.md is missing, but script succeeded"
else
    _er1_exit=$?
    if [ "$_er1_exit" -eq 1 ]; then
        pass "ER1. missing history.md causes exit 1"
    else
        fail "ER1. expected exit 1, got exit $_er1_exit"
    fi
fi

trap - EXIT
rm -rf "$_er1_td"

# ---------------------------------------------------------------------------
# ER2: Missing classification.md → exit 1
# ---------------------------------------------------------------------------
echo ""
echo "=== ER2: split-history.py — missing classification.md → exit 1 ==="

_er2_td=$(mktemp -d)
trap 'rm -rf "$_er2_td"' EXIT

_er2_hist="# History

### Some entry

Body.
"

mkdir -p "$_er2_td/bin" "$_er2_td/docs"
cp "$SPLIT_SCRIPT" "$_er2_td/bin/split-history.py"
# Write only history, no classification.md
printf '%s' "$_er2_hist" > "$_er2_td/docs/history.md"

if uv run "$_er2_td/bin/split-history.py" > /dev/null 2>&1; then
    fail "ER2. expected exit 1 when classification.md is missing, but script succeeded"
else
    _er2_exit=$?
    if [ "$_er2_exit" -eq 1 ]; then
        pass "ER2. missing classification.md causes exit 1"
    else
        fail "ER2. expected exit 1, got exit $_er2_exit"
    fi
fi

trap - EXIT
rm -rf "$_er2_td"

# ---------------------------------------------------------------------------
# N16: Archive source processed correctly
# ---------------------------------------------------------------------------
echo ""
echo "=== N16: split-history.py — archive source processed correctly ==="

_n16_td=$(mktemp -d)
trap 'rm -rf "$_n16_td"' EXIT

_n16_hist="# History

### Alpha feature

Alpha body.
"
_n16_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Alpha feature | @dotfiles |
"

_n16_archive="# History

### Archive only entry

Archive body.
"
_n16_archive_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Archive only entry | @claude |
"

setup_split_tree "$_n16_td" "$_n16_hist" "$_n16_cls"
mkdir -p "$_n16_td/docs/history"
printf '%s' "$_n16_archive" > "$_n16_td/docs/history/2026.md"
printf '%s' "$_n16_archive_cls" > "$_n16_td/docs/history-classification-2026.md"

if uv run "$_n16_td/bin/split-history.py" > /dev/null 2>&1; then
    _n16_agents=$(grep -c '^### ' "$_n16_td/docs/history/2026-agents.md" 2>/dev/null || true)
    _n16_dotfiles=$(grep -c '^### ' "$_n16_td/docs/history/2026-dotfiles.md" 2>/dev/null || true)
    _n16_agents="${_n16_agents:-0}"
    _n16_dotfiles="${_n16_dotfiles:-0}"
    if [ "$_n16_agents" -eq 1 ] && [ "$_n16_dotfiles" -eq 0 ]; then
        pass "N16. archive 2026.md: agents=1, dotfiles=0 for @claude entry"
    else
        fail "N16. expected archive agents=1 dotfiles=0, got agents=$_n16_agents dotfiles=$_n16_dotfiles"
    fi
else
    fail "N16. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n16_td"

# ---------------------------------------------------------------------------
# N17: All 3 source files processed in a single run
# ---------------------------------------------------------------------------
echo ""
echo "=== N17: split-history.py — all 3 source files processed in one run ==="

_n17_td=$(mktemp -d)
trap 'rm -rf "$_n17_td"' EXIT

# Main pair: 1 @dotfiles entry
_n17_hist="# History

### Main dotfiles entry

Main body.
"
_n17_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Main dotfiles entry | @dotfiles |
"

# Legacy archive: 1 @claude entry
_n17_legacy="# History

### Legacy claude entry

Legacy body.
"
_n17_legacy_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Legacy claude entry | @claude |
"

# 2026 archive: 1 @both entry
_n17_2026="# History

### Both entry 2026

Both body.
"
_n17_2026_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Both entry 2026 | @both |
"

setup_split_tree "$_n17_td" "$_n17_hist" "$_n17_cls"
mkdir -p "$_n17_td/docs/history"
printf '%s' "$_n17_legacy" > "$_n17_td/docs/history/legacy.md"
printf '%s' "$_n17_legacy_cls" > "$_n17_td/docs/history-classification-legacy.md"
printf '%s' "$_n17_2026" > "$_n17_td/docs/history/2026.md"
printf '%s' "$_n17_2026_cls" > "$_n17_td/docs/history-classification-2026.md"

if uv run "$_n17_td/bin/split-history.py" > /dev/null 2>&1; then
    _n17_ok=1

    # Main pair
    _n17_main_agents=$(grep -c '^### ' "$_n17_td/docs/history-agents.md" 2>/dev/null || true)
    _n17_main_dotfiles=$(grep -c '^### ' "$_n17_td/docs/history-dotfiles.md" 2>/dev/null || true)
    _n17_main_agents="${_n17_main_agents:-0}"
    _n17_main_dotfiles="${_n17_main_dotfiles:-0}"
    if [ "$_n17_main_agents" -ne 0 ] || [ "$_n17_main_dotfiles" -ne 1 ]; then
        fail "N17. main: expected agents=0 dotfiles=1, got agents=$_n17_main_agents dotfiles=$_n17_main_dotfiles"
        _n17_ok=0
    fi

    # Legacy archive
    _n17_leg_agents=$(grep -c '^### ' "$_n17_td/docs/history/legacy-agents.md" 2>/dev/null || true)
    _n17_leg_dotfiles=$(grep -c '^### ' "$_n17_td/docs/history/legacy-dotfiles.md" 2>/dev/null || true)
    _n17_leg_agents="${_n17_leg_agents:-0}"
    _n17_leg_dotfiles="${_n17_leg_dotfiles:-0}"
    if [ "$_n17_leg_agents" -ne 1 ] || [ "$_n17_leg_dotfiles" -ne 0 ]; then
        fail "N17. legacy: expected agents=1 dotfiles=0, got agents=$_n17_leg_agents dotfiles=$_n17_leg_dotfiles"
        _n17_ok=0
    fi

    # 2026 archive
    _n17_2026_agents=$(grep -c '^### ' "$_n17_td/docs/history/2026-agents.md" 2>/dev/null || true)
    _n17_2026_dotfiles=$(grep -c '^### ' "$_n17_td/docs/history/2026-dotfiles.md" 2>/dev/null || true)
    _n17_2026_agents="${_n17_2026_agents:-0}"
    _n17_2026_dotfiles="${_n17_2026_dotfiles:-0}"
    if [ "$_n17_2026_agents" -ne 1 ] || [ "$_n17_2026_dotfiles" -ne 1 ]; then
        fail "N17. 2026: expected agents=1 dotfiles=1, got agents=$_n17_2026_agents dotfiles=$_n17_2026_dotfiles"
        _n17_ok=0
    fi

    if [ "$_n17_ok" -eq 1 ]; then
        pass "N17. all 6 output files correct (main + legacy + 2026 archives)"
    fi
else
    fail "N17. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n17_td"

# ---------------------------------------------------------------------------
# I2: Archive pair idempotent (second run byte-identical)
# ---------------------------------------------------------------------------
echo ""
echo "=== I2: split-history.py — archive pair idempotent (second run byte-identical) ==="

_i2_td=$(mktemp -d)
trap 'rm -rf "$_i2_td"' EXIT

_i2_hist="# History

### Main entry

Main body.
"
_i2_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Main entry | @dotfiles |
"

_i2_archive="# History

### Idempotent archive entry

Archive body.
"
_i2_archive_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Idempotent archive entry | @both |
"

setup_split_tree "$_i2_td" "$_i2_hist" "$_i2_cls"
mkdir -p "$_i2_td/docs/history"
printf '%s' "$_i2_archive" > "$_i2_td/docs/history/2026.md"
printf '%s' "$_i2_archive_cls" > "$_i2_td/docs/history-classification-2026.md"

# First run
uv run "$_i2_td/bin/split-history.py" > /dev/null 2>&1

_i2_agents_sum1=$(md5sum "$_i2_td/docs/history/2026-agents.md" 2>/dev/null | cut -d' ' -f1)
_i2_dotfiles_sum1=$(md5sum "$_i2_td/docs/history/2026-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

# Second run
uv run "$_i2_td/bin/split-history.py" > /dev/null 2>&1

_i2_agents_sum2=$(md5sum "$_i2_td/docs/history/2026-agents.md" 2>/dev/null | cut -d' ' -f1)
_i2_dotfiles_sum2=$(md5sum "$_i2_td/docs/history/2026-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

if [ "$_i2_agents_sum1" = "$_i2_agents_sum2" ] && [ "$_i2_dotfiles_sum1" = "$_i2_dotfiles_sum2" ]; then
    pass "I2. second run produces byte-identical archive output (idempotent)"
else
    fail "I2. archive output differs between runs (not idempotent)"
fi

trap - EXIT
rm -rf "$_i2_td"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi

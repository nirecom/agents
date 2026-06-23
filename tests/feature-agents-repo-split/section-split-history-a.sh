
# ===========================================================================
# split-history.py tests (N11–N15, E4–E6, I1, ER1–ER2)
# Each test creates its own isolated tmpdir and cleans up on exit.
# ===========================================================================

SPLIT_SCRIPT="$AGENTS_ROOT/bin/split-history.py"

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

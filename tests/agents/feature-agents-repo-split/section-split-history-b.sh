
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

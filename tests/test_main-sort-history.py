"""Tests for bin/sort-history.py pure functions."""

import sys
from datetime import datetime, timezone
from pathlib import Path

# Add bin/ to path so we can import the module
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))

# Import from the module (filename has hyphens, use importlib)
import importlib

sort_history_mod = importlib.import_module("sort-history")

parse_sections = sort_history_mod.parse_sections
build_anchor_blocks = sort_history_mod.build_anchor_blocks
sort_section_entries = sort_history_mod.sort_section_entries
sort_history = sort_history_mod.sort_history
resolve_entry_date = sort_history_mod.resolve_entry_date


# --- Normal cases ---


class TestSingleSectionAlreadySorted:
    """1. Single section, already sorted (ascending dates) — output unchanged."""

    def test_already_sorted(self):
        content = (
            "## History\n"
            "### Entry A (2024-01-01, abc1234)\n"
            "Details A\n"
            "### Entry B (2024-02-01, def5678)\n"
            "Details B\n"
            "### Entry C (2024-03-01, ghi9012)\n"
            "Details C"
        )
        result = sort_history(content, repo_path=None)
        assert result == content


class TestSingleSectionDescendingToAscending:
    """2. Single section, descending dates → sorted ascending."""

    def test_descending_sorted_to_ascending(self):
        content = (
            "## History\n"
            "### Entry C (2024-03-01)\n"
            "Details C\n"
            "### Entry B (2024-02-01)\n"
            "Details B\n"
            "### Entry A (2024-01-01)\n"
            "Details A"
        )
        expected = (
            "## History\n"
            "### Entry A (2024-01-01)\n"
            "Details A\n"
            "### Entry B (2024-02-01)\n"
            "Details B\n"
            "### Entry C (2024-03-01)\n"
            "Details C"
        )
        result = sort_history(content, repo_path=None)
        assert result == expected


class TestMultipleSectionsSortedIndependently:
    """3. Multiple ## sections — each sorted independently."""

    def test_multiple_sections(self):
        content = (
            "## Section 1\n"
            "### B (2024-02-01)\n"
            "B body\n"
            "### A (2024-01-01)\n"
            "A body\n"
            "## Section 2\n"
            "### D (2024-04-01)\n"
            "D body\n"
            "### C (2024-03-01)\n"
            "C body"
        )
        expected = (
            "## Section 1\n"
            "### A (2024-01-01)\n"
            "A body\n"
            "### B (2024-02-01)\n"
            "B body\n"
            "## Section 2\n"
            "### C (2024-03-01)\n"
            "C body\n"
            "### D (2024-04-01)\n"
            "D body"
        )
        result = sort_history(content, repo_path=None)
        assert result == expected


class TestAnchorBlocks:
    """4. Anchor blocks — dateless entries attached to preceding anchor move together."""

    def test_dateless_follows_anchor(self):
        content = (
            "## History\n"
            "### Anchor B (2024-02-01)\n"
            "B body\n"
            "### Dateless after B\n"
            "No date here\n"
            "### Anchor A (2024-01-01)\n"
            "A body"
        )
        # Anchor A (Jan) should come first, then Anchor B (Feb) + its dateless follower
        expected = (
            "## History\n"
            "### Anchor A (2024-01-01)\n"
            "A body\n"
            "### Anchor B (2024-02-01)\n"
            "B body\n"
            "### Dateless after B\n"
            "No date here"
        )
        result = sort_history(content, repo_path=None)
        assert result == expected


# --- Edge cases ---


class TestNoEntriesUnderSection:
    """5. No ### entries under a ## header — returned as-is."""

    def test_no_entries(self):
        content = "## History\nSome preamble text"
        result = sort_history(content, repo_path=None)
        assert result == content


class TestSingleEntry:
    """6. Single entry — returned as-is."""

    def test_single_entry(self):
        content = (
            "## History\n"
            "### Only Entry (2024-01-01)\n"
            "Details"
        )
        result = sort_history(content, repo_path=None)
        assert result == content


class TestLeadingFloatingBlock:
    """7. Leading floating block (dateless entries before any anchor) — placed at end."""

    def test_leading_dateless_placed_at_end(self):
        content = (
            "## History\n"
            "### Floating entry\n"
            "No date\n"
            "### Anchor A (2024-01-01)\n"
            "A body\n"
            "### Anchor B (2024-02-01)\n"
            "B body"
        )
        expected = (
            "## History\n"
            "### Anchor A (2024-01-01)\n"
            "A body\n"
            "### Anchor B (2024-02-01)\n"
            "B body\n"
            "### Floating entry\n"
            "No date"
        )
        result = sort_history(content, repo_path=None)
        assert result == expected


class TestSameDateStableSort:
    """8. Multiple entries with same date — original relative order preserved."""

    def test_stable_sort_same_date(self):
        content = (
            "## History\n"
            "### Entry X (2024-01-01)\n"
            "X body\n"
            "### Entry Y (2024-01-01)\n"
            "Y body\n"
            "### Entry Z (2024-01-01)\n"
            "Z body"
        )
        result = sort_history(content, repo_path=None)
        assert result == content


class TestEmptyStringInput:
    """9. Empty string input — no crash."""

    def test_empty_string(self):
        result = sort_history("", repo_path=None)
        assert result == ""


# --- Error cases ---


class TestAllDateless:
    """10. All entries dateless — all floating, order preserved."""

    def test_all_dateless(self):
        content = (
            "## History\n"
            "### Entry A\n"
            "A body\n"
            "### Entry B\n"
            "B body\n"
            "### Entry C\n"
            "C body"
        )
        # All are floating (no dates), should preserve original order
        result = sort_history(content, repo_path=None)
        assert result == content


# --- Idempotency ---


class TestIdempotency:
    """11. sort_history(sort_history(x)) == sort_history(x)."""

    def test_idempotent(self):
        content = (
            "## History\n"
            "### Entry C (2024-03-01)\n"
            "C body\n"
            "### Dateless\n"
            "No date\n"
            "### Entry A (2024-01-01)\n"
            "A body\n"
            "### Entry B (2024-02-01)\n"
            "B body"
        )
        once = sort_history(content, repo_path=None)
        twice = sort_history(once, repo_path=None)
        assert once == twice


# --- Unit tests for resolve_entry_date ---


class TestResolveEntryDate:
    """Test resolve_entry_date with repo_path=None (inline date parsing only)."""

    def test_inline_date(self):
        result = resolve_entry_date("### Something (2024-06-15, abc1234)", None)
        assert result == datetime(2024, 6, 15, tzinfo=timezone.utc)

    def test_no_date_no_repo(self):
        result = resolve_entry_date("### Something with no date", None)
        assert result is None

    def test_invalid_date_format(self):
        result = resolve_entry_date("### Something (not-a-date)", None)
        assert result is None


# --- Unit tests for parse_sections ---


class TestParseSections:
    """Test parse_sections splitting."""

    def test_basic_split(self):
        content = (
            "## Section\n"
            "### Entry 1\n"
            "Body 1\n"
            "### Entry 2\n"
            "Body 2"
        )
        sections = parse_sections(content)
        assert len(sections) == 1
        header, entries = sections[0]
        assert header == "## Section"
        assert len(entries) == 2
        assert entries[0] == "### Entry 1\nBody 1"
        assert entries[1] == "### Entry 2\nBody 2"

    def test_preamble_before_section(self):
        content = (
            "# Title\n"
            "Preamble\n"
            "## Section\n"
            "### Entry\n"
            "Body"
        )
        sections = parse_sections(content)
        assert len(sections) == 2
        # First section is the preamble (no ## header)
        assert sections[0][0] == "# Title\nPreamble"
        assert sections[0][1] == []
        # Second section has the ## header
        assert sections[1][0] == "## Section"
        assert len(sections[1][1]) == 1


# --- Unit tests for build_anchor_blocks ---


class TestBuildAnchorBlocks:
    """Test build_anchor_blocks grouping."""

    def test_all_dated(self):
        entries = [
            "### A (2024-01-01)\nA body",
            "### B (2024-02-01)\nB body",
        ]
        blocks = build_anchor_blocks(entries, repo_path=None)
        assert len(blocks) == 2
        assert blocks[0][0] is not None  # has date
        assert blocks[1][0] is not None

    def test_dateless_attaches_to_anchor(self):
        entries = [
            "### Anchor (2024-01-01)\nBody",
            "### Dateless\nNo date",
        ]
        blocks = build_anchor_blocks(entries, repo_path=None)
        assert len(blocks) == 1
        assert len(blocks[0][1]) == 2  # anchor + dateless in same block

    def test_leading_dateless_is_floating(self):
        entries = [
            "### Dateless\nNo date",
            "### Anchor (2024-01-01)\nBody",
        ]
        blocks = build_anchor_blocks(entries, repo_path=None)
        assert len(blocks) == 2
        assert blocks[0][0] is None  # floating block
        assert blocks[1][0] is not None  # anchor block

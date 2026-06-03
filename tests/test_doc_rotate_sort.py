"""Tests for issue #733 Refactor 2 — doc-rotate.py sort extraction.

Covers the behavior of `bin/doc-rotate.py`'s entry ordering during rotation:
  - Entries should be archived in ascending date order (oldest -> newest)
  - Undated entries are treated as oldest and appear before dated entries
  - The retained tail (floor) should also be in ascending date order

These tests target observable rotation behavior — they do not import the
helper `_sort_by_inline_date` directly so they remain valid both before and
after the refactor lands (the refactor only extracts the existing sort into
a named helper; behavior is preserved).
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DOC_ROTATE_PATH = REPO_ROOT / "bin" / "doc-rotate.py"

DATE_RE = re.compile(r"\((\d{4}-\d{2}-\d{2})")


def _run_rotate(history_path: Path, *extra_args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(DOC_ROTATE_PATH), str(history_path), *extra_args],
        capture_output=True,
        text=True,
    )


def _make_entry(category: str, subject: str, date: str | None, commit: str) -> str:
    if date is not None:
        header = f"### {category}: {subject} ({date}, {commit})"
    else:
        header = f"### {category}: {subject}"
    return f"{header}\nBackground: x\nChanges: y\n"


def _extract_dates_in_order(text: str) -> list[str]:
    """Return ISO date strings in the order they appear in the text (one per entry header)."""
    dates: list[str] = []
    for line in text.splitlines():
        if line.startswith("### "):
            m = DATE_RE.search(line)
            dates.append(m.group(1) if m else "")
    return dates


class TestDocRotateSort:
    def test_rotate_sorts_descending_input_to_ascending(self, tmp_path):
        """Input in DESCENDING order → after rotation, body and archive are ASCENDING."""
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"

        # Build 30 entries in DESCENDING date order.
        # We need 500+ lines to trigger --threshold-warn 500.
        # Each entry is 3 lines + 1 blank separator → ~4 lines. 30 entries → ~120 lines.
        # Pad with a long preamble (many comment lines) to clear the 500-line gate.
        entry_count = 30
        entries_desc: list[str] = []
        for i in range(entry_count, 0, -1):
            # Dates from 2026-01-01..2026-01-30, but produced in descending order
            day = f"{i:02d}"
            entries_desc.append(
                _make_entry("FEATURE", f"S{i:02d}", f"2026-01-{day}", f"hash{i:03d}")
            )

        preamble_lines = "\n".join(f"<!-- pad {n} -->" for n in range(450))
        body = preamble_lines + "\n\n" + "\n".join(entries_desc)
        hist.write_text(body, encoding="utf-8")

        result = _run_rotate(hist, "--threshold-warn", "500", "--floor", "5")
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"

        # Retained body: floor=5 entries — should be the 5 LATEST in ascending order
        new_body = hist.read_text(encoding="utf-8")
        body_dates = _extract_dates_in_order(new_body)
        assert body_dates, "expected at least one entry remaining in history.md"
        # All retained must be ascending (sorted == itself)
        assert body_dates == sorted(body_dates), (
            f"retained body not ascending: {body_dates}"
        )
        # And they must be the latest 5 (Jan 26..30)
        assert body_dates == [
            "2026-01-26",
            "2026-01-27",
            "2026-01-28",
            "2026-01-29",
            "2026-01-30",
        ]

        # Archive: history/2026.md should contain the older entries in ascending order
        archive_path = docs / "history" / "2026.md"
        assert archive_path.exists(), "expected history/2026.md to be created"
        archive_text = archive_path.read_text(encoding="utf-8")
        archive_dates = _extract_dates_in_order(archive_text)
        assert archive_dates == sorted(archive_dates), (
            f"archive not ascending: {archive_dates}"
        )
        # First archive date is the oldest input date
        assert archive_dates[0] == "2026-01-01"
        # Last archive date is just before the retained window
        assert archive_dates[-1] == "2026-01-25"

    def test_rotate_undated_entries_appear_first(self, tmp_path):
        """Mixed undated + dated → undated entries archived before dated entries."""
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"

        # 2 undated + 20 dated entries, with enough total lines to trigger rotation.
        undated_entries = [
            _make_entry("FEATURE", "Legacy1", None, ""),
            _make_entry("FEATURE", "Legacy2", None, ""),
        ]
        dated_entries = [
            _make_entry("FEATURE", f"D{i:02d}", f"2026-02-{i:02d}", f"hash{i:03d}")
            for i in range(1, 21)
        ]

        # Place undated AFTER dated in the input — rotation must still archive
        # undated FIRST in the legacy.md file (and dated by year in 2026.md).
        preamble_lines = "\n".join(f"<!-- pad {n} -->" for n in range(450))
        body = (
            preamble_lines
            + "\n\n"
            + "\n".join(dated_entries)
            + "\n"
            + "\n".join(undated_entries)
        )
        hist.write_text(body, encoding="utf-8")

        result = _run_rotate(hist, "--threshold-warn", "500", "--floor", "5")
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"

        # legacy.md holds undated entries
        legacy_path = docs / "history" / "legacy.md"
        archive_path = docs / "history" / "2026.md"
        assert legacy_path.exists(), "expected history/legacy.md to be created"
        assert archive_path.exists(), "expected history/2026.md to be created"

        legacy_text = legacy_path.read_text(encoding="utf-8")
        archive_text = archive_path.read_text(encoding="utf-8")

        # Both undated subjects ended up in legacy.md
        assert "Legacy1" in legacy_text
        assert "Legacy2" in legacy_text
        # Dated entries went into 2026.md
        assert "D01" in archive_text
        # Dated archive in ascending date order
        archive_dates = _extract_dates_in_order(archive_text)
        assert archive_dates == sorted(archive_dates), (
            f"dated archive not ascending: {archive_dates}"
        )

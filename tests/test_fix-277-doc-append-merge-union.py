"""Tests for issue #277 — doc-append rebase conflict fix (Approach C).

Covers:
- R2: parser (_split_entries) correctness across normal/empty/preamble/single/BOM/CRLF
- R3: idempotency (_sort_entries) — sorted input is byte-stable
- R5: same-date and missing-date stability
- Integration: CLI append-to-disordered, same-date OK, older-date fails

Tests target the FUTURE shape of bin/doc-append.py (after #277 fix lands).
Helpers that do not yet exist are imported lazily and the corresponding tests
are skipped so the file remains green pre-fix.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DOC_APPEND_PATH = REPO_ROOT / "bin" / "doc-append.py"


def _load_module():
    """Load bin/doc-append.py as a Python module via importlib."""
    spec = importlib.util.spec_from_file_location("doc_append_mod", DOC_APPEND_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


doc_append_mod = _load_module()


def _get(name):
    """Return the helper function or None if not yet implemented."""
    return getattr(doc_append_mod, name, None)


_split_entries = _get("_split_entries")
_sort_entries = _get("_sort_entries")
_join_entries = _get("_join_entries")

requires_split = pytest.mark.skipif(
    _split_entries is None,
    reason="_split_entries not yet implemented — will pass after #277 fix",
)
requires_sort = pytest.mark.skipif(
    _sort_entries is None,
    reason="_sort_entries not yet implemented — will pass after #277 fix",
)


# -------- R2: parser --------


class TestSplitEntries:
    @requires_split
    def test_split_entries_normal(self):
        data = (
            b"### FEATURE: A (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n\n"
            b"### BUGFIX: B (2026-01-02, bbb2222)\n"
            b"Background: x\nChanges: y\n\n"
            b"### REFACTOR: C (2026-01-03, ccc3333)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _split_entries(data)
        # Expect 3 entries (preamble may or may not be a separate element if empty)
        entries = [seg for seg in result if seg.lstrip().startswith(b"### ") or seg.lstrip().startswith("### ".encode())]
        assert len(entries) == 3

    @requires_split
    def test_split_entries_empty(self):
        result = _split_entries(b"")
        # Empty input -> empty list OR list of one empty preamble
        assert result == [] or all(not seg.strip() for seg in result)

    @requires_split
    def test_split_entries_preamble_only(self):
        data = b"# Header\n\nSome intro text without any entry header.\n"
        result = _split_entries(data)
        entries = [seg for seg in result if seg.lstrip().startswith(b"### ")]
        assert len(entries) == 0

    @requires_split
    def test_split_entries_single(self):
        data = (
            b"### FEATURE: Only (2026-01-01, abc1234)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _split_entries(data)
        entries = [seg for seg in result if seg.lstrip().startswith(b"### ")]
        assert len(entries) == 1

    @requires_split
    def test_split_entries_bom(self):
        data = (
            b"\xef\xbb\xbf"
            b"### FEATURE: A (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: B (2026-01-02, bbb2222)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _split_entries(data)
        entries = [seg for seg in result if seg.lstrip().startswith(b"### ")]
        assert len(entries) == 2

    @requires_split
    def test_split_entries_crlf(self):
        data = (
            b"### FEATURE: A (2026-01-01, aaa1111)\r\n"
            b"Background: x\r\nChanges: y\r\n\r\n"
            b"### FEATURE: B (2026-01-02, bbb2222)\r\n"
            b"Background: x\r\nChanges: y\r\n"
        )
        result = _split_entries(data)
        entries = [seg for seg in result if seg.lstrip().startswith(b"### ")]
        assert len(entries) == 2


# -------- R3 + R5: sort --------


class TestSortEntries:
    @requires_sort
    @requires_split
    def test_sort_entries_already_sorted(self):
        data = (
            b"### FEATURE: A (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: B (2026-02-01, bbb2222)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: C (2026-03-01, ccc3333)\n"
            b"Background: x\nChanges: y\n"
        )
        entries = _split_entries(data)
        sorted_entries = _sort_entries(entries)
        # Already sorted: order preserved
        assert sorted_entries == entries

    @requires_sort
    @requires_split
    def test_sort_entries_unsorted(self):
        data = (
            b"### FEATURE: Later (2026-03-01, ccc3333)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: Earlier (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n"
        )
        entries = _split_entries(data)
        sorted_entries = _sort_entries(entries)
        # First entry after sort should be the earlier-dated one
        joined = b"".join(sorted_entries)
        idx_earlier = joined.find(b"Earlier")
        idx_later = joined.find(b"Later")
        assert idx_earlier >= 0 and idx_later >= 0
        assert idx_earlier < idx_later

    @requires_sort
    @requires_split
    def test_sort_entries_same_date(self):
        data = (
            b"### FEATURE: First (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: Second (2026-01-01, bbb2222)\n"
            b"Background: x\nChanges: y\n"
        )
        entries = _split_entries(data)
        sorted_entries = _sort_entries(entries)
        joined = b"".join(sorted_entries)
        assert b"First" in joined and b"Second" in joined
        # Stable: First stays before Second
        assert joined.find(b"First") < joined.find(b"Second")

    @requires_sort
    @requires_split
    def test_sort_entries_no_date(self):
        data = (
            b"### FEATURE: Dated (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: Undated (no parens here)\n"
            b"Background: x\nChanges: y\n"
        )
        entries = _split_entries(data)
        # Must not raise: dateless entries fall back stably
        sorted_entries = _sort_entries(entries)
        joined = b"".join(sorted_entries)
        assert b"Dated" in joined and b"Undated" in joined


# -------- Integration: CLI --------


def _run_cli(*args, cwd=None):
    return subprocess.run(
        [sys.executable, str(DOC_APPEND_PATH), *args],
        cwd=cwd,
        capture_output=True,
        text=True,
    )


class TestCLIAppendIntegration:
    def test_append_to_disordered_file(self, tmp_path):
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        # Out-of-order: later date first, earlier date second
        hist.write_bytes(
            b"### FEATURE: Later (2026-03-01, ccc3333)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: Earlier (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _run_cli(
            str(hist),
            "--category", "FEATURE",
            "--subject", "NewOne",
            "--date", "2026-04-01",
            "--commits", "ddd4444",
            "--background", "bg",
            "--changes", "ch",
            "--no-auto-rotate",
        )
        if _sort_entries is None:
            # Pre-fix behavior: tail-seek may either accept (if last entry date is OK)
            # or reject. Either way we just verify the new entry was written when exit==0.
            if result.returncode == 0:
                assert b"NewOne" in hist.read_bytes()
            pytest.skip("sort refactor not yet applied — accepting current tail-seek behavior")
        # Post-fix expected behavior:
        assert result.returncode == 0, f"stderr: {result.stderr}"
        body = hist.read_bytes()
        assert b"NewOne" in body
        # File should now be sorted: Earlier < Later < NewOne
        i_earlier = body.find(b"Earlier")
        i_later = body.find(b"Later")
        i_new = body.find(b"NewOne")
        assert i_earlier < i_later < i_new

    def test_append_same_date_ok(self, tmp_path):
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        hist.write_bytes(
            b"### FEATURE: First (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _run_cli(
            str(hist),
            "--category", "FEATURE",
            "--subject", "Second",
            "--date", "2026-01-01",
            "--commits", "bbb2222",
            "--background", "bg",
            "--changes", "ch",
            "--no-auto-rotate",
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        assert b"Second" in hist.read_bytes()

    def test_append_older_date_fails(self, tmp_path):
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        # Sorted file with last entry at 2026-06-01
        hist.write_bytes(
            b"### FEATURE: A (2026-01-01, aaa1111)\n"
            b"Background: x\nChanges: y\n\n"
            b"### FEATURE: B (2026-06-01, bbb2222)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _run_cli(
            str(hist),
            "--category", "FEATURE",
            "--subject", "Older",
            "--date", "2026-03-01",  # older than last (2026-06-01)
            "--commits", "ccc3333",
            "--background", "bg",
            "--changes", "ch",
            "--no-auto-rotate",
        )
        # After sort, last entry remains 2026-06-01; 2026-03-01 must be rejected
        assert result.returncode != 0
        assert b"Older" not in hist.read_bytes()

    # -------- Issue #733 Fix 1: DATE_ORDER_TOLERANCE_DAYS = 7 --------

    def test_append_within_tolerance_window_succeeds(self, tmp_path):
        """1 day older than last entry → accepted (within 7-day tolerance)."""
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        hist.write_bytes(
            b"### FEATURE: A (2026-06-03, aaa1111)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _run_cli(
            str(hist),
            "--category", "FEATURE",
            "--subject", "WithinTolerance",
            "--date", "2026-06-02",  # 1 day older than last
            "--commits", "bbb2222",
            "--background", "bg",
            "--changes", "ch",
            "--no-auto-rotate",
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        assert b"WithinTolerance" in hist.read_bytes()

    def test_append_exact_tolerance_boundary_succeeds(self, tmp_path):
        """Exactly 7 days older than last entry → accepted (boundary)."""
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        hist.write_bytes(
            b"### FEATURE: A (2026-06-10, aaa1111)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _run_cli(
            str(hist),
            "--category", "FEATURE",
            "--subject", "ExactBoundary",
            "--date", "2026-06-03",  # exactly 7 days older
            "--commits", "bbb2222",
            "--background", "bg",
            "--changes", "ch",
            "--no-auto-rotate",
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        assert b"ExactBoundary" in hist.read_bytes()

    def test_append_just_outside_tolerance_window_fails(self, tmp_path):
        """8 days older than last entry → rejected (just outside tolerance)."""
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        hist.write_bytes(
            b"### FEATURE: A (2026-06-10, aaa1111)\n"
            b"Background: x\nChanges: y\n"
        )
        result = _run_cli(
            str(hist),
            "--category", "FEATURE",
            "--subject", "JustOutside",
            "--date", "2026-06-02",  # 8 days older
            "--commits", "bbb2222",
            "--background", "bg",
            "--changes", "ch",
            "--no-auto-rotate",
        )
        assert result.returncode != 0
        assert b"JustOutside" not in hist.read_bytes()

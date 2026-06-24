# Tests: bin/doc-rotate.py, bin/doc-append.py, install/linux/dotfileslink.sh
# Tags: scope:issue-specific
#
# Regression tests for issue #1073: doc-rotate.py / doc-append.py CHANGELOG.md
# rotation must use a CHANGELOG-specific archive (changelog/<year>.md), NOT the
# history/<year>.md stream. history/index.md must NOT be generated. The ## Archived
# block must not be duplicated on repeated rotation.
#
# L3 gap (what this test does NOT catch):
# - Real MSYS/Git Bash environment: MSYS_NO_PATHCONV=1 actually suppressing path conversion
# - Real dotfileslink.sh execution creating ~/.local/bin/doc-append with the correct content
# - doc-append CLI invocation via the actual installed bash wrapper (T1 uses doc-append.py directly)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer
#
# Expected behavior (post-fix):
#   - doc-rotate.py on CHANGELOG.md writes to changelog/<year>.md, not history/<year>.md
#   - history/index.md is NOT generated when rotating CHANGELOG.md
#   - Archive file header is "# Changelog <year>", not "# History <year>"
#   - Re-rotating a CHANGELOG.md that already has ## Archived does NOT duplicate the header
#   - doc-append CHANGELOG.md auto-rotation follows the same CHANGELOG-specific rules
#   - doc-rotate.py CHANGELOG.md --rebuild-index exits 0 with a warning (no index for CHANGELOG)
#   - doc-rotate.py history.md --rebuild-index still works (guard does not affect history)
#   - T9: dotfileslink.sh source contains MSYS_NO_PATHCONV=1 (static check)
#
# Expected to fail until source is fixed (doc-rotate.py / doc-append.py).

from __future__ import annotations

import datetime
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DOC_ROTATE_PATH = REPO_ROOT / "bin" / "doc-rotate.py"
DOC_APPEND_PATH = REPO_ROOT / "bin" / "doc-append.py"
DOTFILESLINK_PATH = REPO_ROOT / "install" / "linux" / "dotfileslink.sh"

THIS_YEAR = datetime.date.today().year
TODAY_ISO = datetime.date.today().isoformat()


def _run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        list(args),
        capture_output=True,
        text=True,
        cwd=str(cwd) if cwd else None,
    )


def _run_rotate(path: Path, *extra_args: str) -> subprocess.CompletedProcess:
    return _run(sys.executable, str(DOC_ROTATE_PATH), str(path), *extra_args)


def _run_append(cwd: Path, *extra_args: str) -> subprocess.CompletedProcess:
    return _run(
        sys.executable,
        str(DOC_APPEND_PATH),
        *extra_args,
        cwd=cwd,
    )


def _make_changelog_fixture(path: Path, n_entries: int = 520) -> None:
    """Write a CHANGELOG.md with n_entries ### entries (each ~2 lines) so auto-rotation fires."""
    lines = ["# Changelog\n\n"]
    for i in range(1, n_entries + 1):
        # Use dates within the current year so all entries land in one archive file.
        entry_date = f"{THIS_YEAR}-01-{(i % 28) + 1:02d}"
        lines.append(f"### FEATURE: Entry {i} ({entry_date})\n")
        lines.append(f"Background: bg {i}\nChanges: ch {i}\n\n")
    path.write_text("".join(lines), encoding="utf-8")


def _make_history_fixture(path: Path, n_entries: int = 30) -> None:
    """Write a history.md with n_entries ### entries plus large preamble for threshold."""
    preamble = "\n".join(f"<!-- pad {n} -->" for n in range(480))
    lines = [preamble + "\n\n"]
    for i in range(1, n_entries + 1):
        entry_date = f"{THIS_YEAR}-02-{(i % 28) + 1:02d}"
        lines.append(f"### FEATURE: Hist {i} ({entry_date})\n")
        lines.append(f"Background: bg {i}\nChanges: ch {i}\n\n")
    path.write_text("".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# T1: doc-append CHANGELOG.md via CLI → changelog/<year>.md generated, history/ untouched
# ---------------------------------------------------------------------------

class TestT1DocAppendChangelogRotation:
    """T1: doc-append CHANGELOG.md CLI → changelog/<year>.md generated, history/ NOT created."""

    def test_changelog_archive_goes_to_changelog_dir(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        result = _run_append(
            docs,
            "CHANGELOG.md",
            "--category", "BUGFIX",
            "--subject", "T1 regression test entry",
            "--date", TODAY_ISO,
            "--background", "regression test background",
            "--changes", "regression test changes",
        )
        assert result.returncode == 0, f"doc-append failed: stderr={result.stderr}"

        # Post-fix: changelog/<year>.md should exist
        changelog_archive = docs / "changelog" / f"{THIS_YEAR}.md"
        assert changelog_archive.exists(), (
            f"Expected changelog/{THIS_YEAR}.md but it does not exist. "
            f"(Bug: doc-append may have written to history/{THIS_YEAR}.md instead)"
        )

    def test_history_dir_not_created_by_changelog_rotation(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        _run_append(
            docs,
            "CHANGELOG.md",
            "--category", "BUGFIX",
            "--subject", "T1b history-dir absence",
            "--date", TODAY_ISO,
            "--background", "bg",
            "--changes", "ch",
        )

        history_dir = docs / "history"
        assert not history_dir.exists(), (
            f"history/ directory was created during CHANGELOG rotation — must not happen. "
            f"Contents: {list(history_dir.iterdir()) if history_dir.exists() else 'N/A'}"
        )

    def test_history_index_not_generated_by_changelog_rotation(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        _run_append(
            docs,
            "CHANGELOG.md",
            "--category", "BUGFIX",
            "--subject", "T1c history-index absence",
            "--date", TODAY_ISO,
            "--background", "bg",
            "--changes", "ch",
        )

        history_index = docs / "history" / "index.md"
        assert not history_index.exists(), (
            "history/index.md was generated during CHANGELOG rotation — must not happen."
        )


# ---------------------------------------------------------------------------
# T2: doc-rotate.py CHANGELOG.md directly → changelog/<year>.md written
# ---------------------------------------------------------------------------

class TestT2DocRotateChangelogDirect:
    """T2: direct doc-rotate.py invocation on CHANGELOG.md writes to changelog/<year>.md."""

    def test_rotate_creates_changelog_archive(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        result = _run_rotate(changelog, "--floor", "5")
        assert result.returncode == 0, f"doc-rotate failed: stderr={result.stderr}"

        changelog_archive = docs / "changelog" / f"{THIS_YEAR}.md"
        assert changelog_archive.exists(), (
            f"Expected docs/changelog/{THIS_YEAR}.md after rotating CHANGELOG.md. "
            f"(Bug: wrote to history/{THIS_YEAR}.md instead)"
        )

    def test_rotate_does_not_create_history_year_file(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        _run_rotate(changelog, "--floor", "5")

        history_year = docs / "history" / f"{THIS_YEAR}.md"
        assert not history_year.exists(), (
            f"history/{THIS_YEAR}.md was created during CHANGELOG rotation — wrong archive target."
        )


# ---------------------------------------------------------------------------
# T3: history.md rotation → history/index.md generated (regression guard)
# ---------------------------------------------------------------------------

class TestT3HistoryRotationIndexGenerated:
    """T3: doc-rotate.py on history.md still generates history/index.md (regression guard)."""

    def test_history_rotation_creates_index(self, tmp_path: Path):
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        _make_history_fixture(hist, n_entries=30)

        result = _run_rotate(hist, "--threshold-warn", "500", "--floor", "5")
        assert result.returncode == 0, f"doc-rotate failed: stderr={result.stderr}"

        index_path = docs / "history" / "index.md"
        assert index_path.exists(), (
            "history/index.md was NOT generated after rotating history.md — regression."
        )

    def test_history_rotation_creates_year_archive(self, tmp_path: Path):
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        _make_history_fixture(hist, n_entries=30)

        _run_rotate(hist, "--threshold-warn", "500", "--floor", "5")

        history_year = docs / "history" / f"{THIS_YEAR}.md"
        assert history_year.exists(), (
            f"history/{THIS_YEAR}.md was not created during history.md rotation."
        )


# ---------------------------------------------------------------------------
# T4: CHANGELOG rotation → history/index.md NOT generated
# ---------------------------------------------------------------------------

class TestT4ChangelogRotationNoHistoryIndex:
    """T4: rotating CHANGELOG.md must NOT create history/index.md."""

    def test_no_history_index_from_changelog_rotation(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        _run_rotate(changelog, "--floor", "5")

        history_index = docs / "history" / "index.md"
        assert not history_index.exists(), (
            "history/index.md was created when rotating CHANGELOG.md — must not happen."
        )


# ---------------------------------------------------------------------------
# T5: changelog/<year>.md header is "# Changelog <year>"
# ---------------------------------------------------------------------------

class TestT5ChangelogArchiveHeader:
    """T5: the archive file header for CHANGELOG rotation must be # Changelog <year>."""

    def test_changelog_archive_header(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        _run_rotate(changelog, "--floor", "5")

        archive = docs / "changelog" / f"{THIS_YEAR}.md"
        if not archive.exists():
            pytest.skip(
                f"changelog/{THIS_YEAR}.md not created — T2 already captures this failure"
            )

        content = archive.read_text(encoding="utf-8")
        assert content.startswith(f"# Changelog {THIS_YEAR}"), (
            f"Archive header mismatch. Expected '# Changelog {THIS_YEAR}', "
            f"got: {content[:60]!r}"
        )

    def test_changelog_archive_header_not_history(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog)

        _run_rotate(changelog, "--floor", "5")

        # If the bug is present, history/<year>.md will exist with wrong header
        history_year = docs / "history" / f"{THIS_YEAR}.md"
        if history_year.exists():
            content = history_year.read_text(encoding="utf-8")
            assert not content.startswith(f"# History {THIS_YEAR}"), (
                "CHANGELOG entries were written to history/<year>.md with '# History' header — wrong."
            )


# ---------------------------------------------------------------------------
# T6: Re-rotation of CHANGELOG.md that already has ## Archived → no duplicate
# ---------------------------------------------------------------------------

class TestT6NoArchivedDuplication:
    """T6: rotating a CHANGELOG.md that already has ## Archived does not duplicate the block."""

    def _make_changelog_with_archived(self, path: Path, n_entries: int = 520) -> None:
        """Write a CHANGELOG.md that already has an ## Archived section."""
        preamble = (
            "# Changelog\n\n"
            "## Archived\n"
            f"- [2025](changelog/2025.md) — 5 entries\n\n"
        )
        lines = [preamble]
        for i in range(1, n_entries + 1):
            entry_date = f"{THIS_YEAR}-03-{(i % 28) + 1:02d}"
            lines.append(f"### FEATURE: Entry {i} ({entry_date})\n")
            lines.append(f"Background: bg {i}\nChanges: ch {i}\n\n")
        path.write_text("".join(lines), encoding="utf-8")

    def test_no_duplicate_archived_header(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        self._make_changelog_with_archived(changelog)

        result = _run_rotate(changelog, "--floor", "5")
        assert result.returncode == 0, f"doc-rotate failed: stderr={result.stderr}"

        content = changelog.read_text(encoding="utf-8")
        archived_count = content.count("## Archived")
        assert archived_count <= 1, (
            f"## Archived appears {archived_count} times in CHANGELOG.md after rotation — "
            f"duplicate header bug."
        )


# ---------------------------------------------------------------------------
# T7: doc-rotate.py CHANGELOG.md --rebuild-index → exit 0, warning on stderr
# ---------------------------------------------------------------------------

class TestT7ChangelogRebuildIndex:
    """T7: CHANGELOG.md --rebuild-index exits 0 and emits a warning (no index for CHANGELOG)."""

    def test_rebuild_index_exits_zero(self, tmp_path: Path):
        # Expected to fail until source is fixed (currently may error or produce history/index.md).
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog, n_entries=10)

        result = _run_rotate(changelog, "--rebuild-index")
        assert result.returncode == 0, (
            f"doc-rotate CHANGELOG.md --rebuild-index exited {result.returncode}: "
            f"stderr={result.stderr}"
        )

    def test_rebuild_index_emits_warning(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog, n_entries=10)

        result = _run_rotate(changelog, "--rebuild-index")

        combined = (result.stdout + result.stderr).lower()
        assert "warning" in combined or "warn" in combined or "no index" in combined, (
            f"Expected a warning on CHANGELOG.md --rebuild-index. "
            f"stdout={result.stdout!r} stderr={result.stderr!r}"
        )

    def test_rebuild_index_does_not_create_history_index(self, tmp_path: Path):
        # Expected to fail until source is fixed.
        docs = tmp_path / "docs"
        docs.mkdir()
        changelog = docs / "CHANGELOG.md"
        _make_changelog_fixture(changelog, n_entries=10)

        _run_rotate(changelog, "--rebuild-index")

        history_index = docs / "history" / "index.md"
        assert not history_index.exists(), (
            "history/index.md was created by CHANGELOG.md --rebuild-index — must not happen."
        )


# ---------------------------------------------------------------------------
# T8: history.md --rebuild-index still works (guard does not affect history)
# ---------------------------------------------------------------------------

class TestT8HistoryRebuildIndexUnaffected:
    """T8: doc-rotate.py history.md --rebuild-index still works after the fix."""

    def test_history_rebuild_index_exits_zero(self, tmp_path: Path):
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        _make_history_fixture(hist, n_entries=5)

        # First rotate to create archive files
        _run_rotate(hist, "--floor", "3")

        history_dir = docs / "history"
        if not history_dir.exists():
            history_dir.mkdir()
            # Write a minimal archive so rebuild-index has something to scan
            (history_dir / f"{THIS_YEAR}.md").write_text(
                f"# History {THIS_YEAR}\n\n"
                f"### FEATURE: Hist 1 ({THIS_YEAR}-02-01)\nBackground: b\nChanges: c\n",
                encoding="utf-8",
            )

        result = _run_rotate(hist, "--rebuild-index")
        assert result.returncode == 0, (
            f"history.md --rebuild-index exited {result.returncode}: stderr={result.stderr}"
        )

    def test_history_rebuild_index_creates_index(self, tmp_path: Path):
        docs = tmp_path / "docs"
        docs.mkdir()
        hist = docs / "history.md"
        _make_history_fixture(hist, n_entries=5)

        # Create history dir with a minimal archive
        history_dir = docs / "history"
        history_dir.mkdir()
        (history_dir / f"{THIS_YEAR}.md").write_text(
            f"# History {THIS_YEAR}\n\n"
            f"### FEATURE: Hist 1 ({THIS_YEAR}-02-01)\nBackground: b\nChanges: c\n",
            encoding="utf-8",
        )

        result = _run_rotate(hist, "--rebuild-index")
        assert result.returncode == 0, (
            f"history.md --rebuild-index exited {result.returncode}: stderr={result.stderr}"
        )

        index_path = history_dir / "index.md"
        assert index_path.exists(), (
            "history/index.md was NOT created by history.md --rebuild-index."
        )


# ---------------------------------------------------------------------------
# T9: dotfileslink.sh source contains MSYS_NO_PATHCONV=1 (static check)
# ---------------------------------------------------------------------------

class TestT9DotfileslinkMsysPathconv:
    """T9: static check — install/linux/dotfileslink.sh references MSYS_NO_PATHCONV=1."""

    def test_dotfileslink_contains_msys_no_pathconv(self):
        assert DOTFILESLINK_PATH.exists(), (
            f"dotfileslink.sh not found at {DOTFILESLINK_PATH}"
        )
        content = DOTFILESLINK_PATH.read_text(encoding="utf-8")
        # The doc-append launcher generated by dotfileslink.sh must set MSYS_NO_PATHCONV=1
        # to prevent MSYS/Git Bash from mangling Unix-style paths in uv run invocations.
        assert "MSYS_NO_PATHCONV=1" in content, (
            "MSYS_NO_PATHCONV=1 not found in install/linux/dotfileslink.sh. "
            "The generated doc-append launcher must export this to prevent MSYS path conversion."
        )

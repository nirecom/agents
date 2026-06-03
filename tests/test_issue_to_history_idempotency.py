"""Tests for issue #733 Fix 3 — issue-to-history.sh idempotency grep.

Covers the idempotency check at L139 of bin/github-issues/issue-to-history.sh.
The current ERE pattern recognizes two formats:
  (a) ^### #N: ...                    (INCIDENT-style heading prefix)
  (b) ^### ... ( ..., #N)              (legacy trailing-paren format)

Fix 3 adds a third alternative using PCRE (-P) with word boundaries to detect:
  (c) ^### <subject containing #N>: ... (subject-line embedded #N)
  (d) ^### ... ( ..., #N, ... )         (mid-parens, not just trailing)

Tests exercise the PCRE alternatives added by Fix 3.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "bin" / "github-issues" / "issue-to-history.sh"


def _find_posix_bash() -> str | None:
    """Find a POSIX-style bash (Git Bash / MSYS), not WSL's bash.exe.

    WSL's bash on Windows mangles Win32 paths (drops backslashes), so we
    must explicitly prefer Git Bash when running shell scripts that take
    a Windows path as argv.
    """
    # Try common Git Bash install locations first.
    candidates = [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ]
    for c in candidates:
        if Path(c).exists():
            return c
    # Fall back to shutil.which but only if it isn't System32 (WSL).
    found = shutil.which("bash")
    if found and "system32" not in found.lower():
        return found
    return None


BASH = _find_posix_bash()

requires_bash = pytest.mark.skipif(
    BASH is None,
    reason="Git Bash (POSIX bash) not found; WSL bash mangles Win32 paths",
)


def _run_script(agents_dir: Path, issue_num: str) -> subprocess.CompletedProcess:
    """Run issue-to-history.sh under bash with AGENTS_CONFIG_DIR=agents_dir.

    The script will:
      1. cd into AGENTS_CONFIG_DIR
      2. Check docs/history.md + docs/history/ for the idempotency pattern
      3. If found → print "Already in history..." and exit 0
      4. If NOT found → continue to `gh issue view`, which fails outside CI →
         exit non-zero, and "Already in history" is NOT in stdout

    Returns the CompletedProcess. Callers should assert on
    `"Already in history" in result.stdout` (not on returncode for non-detect
    cases — gh failure produces a non-zero exit that's expected).
    """
    env = {
        "AGENTS_CONFIG_DIR": str(agents_dir),
        "PATH": os.environ.get("PATH", ""),
    }
    # Inherit SYSTEMROOT/USERPROFILE/etc. on Windows for bash to function
    for key in ("SYSTEMROOT", "USERPROFILE", "HOME", "TMP", "TEMP", "LANG", "LC_ALL"):
        if key in os.environ:
            env[key] = os.environ[key]
    return subprocess.run(
        [BASH, str(SCRIPT_PATH), issue_num],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _write_history(agents_dir: Path, history_content: str) -> None:
    docs = agents_dir / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    (docs / "history.md").write_text(history_content, encoding="utf-8")


@requires_bash
class TestIssueToHistoryIdempotency:
    def test_detect_subject_line_issue_number(self, tmp_path):
        """(a) Subject line contains #733 → detected as already-in-history."""
        _write_history(
            tmp_path,
            "### Fix #733: foo (2026-06-03, abc1234)\n"
            "Background: x\n"
            "Changes: y\n",
        )
        result = _run_script(tmp_path, "733")
        assert "Already in history" in result.stdout, (
            f"expected idempotency hit; stdout={result.stdout!r} stderr={result.stderr!r}"
        )

    def test_no_false_positive_word_boundary(self, tmp_path):
        """(b) #7330 must NOT match issue #733 (word boundary)."""
        _write_history(
            tmp_path,
            "### FEATURE: bar (2026-06-03, #7330, abc1234)\n"
            "Background: x\n"
            "Changes: y\n",
        )
        result = _run_script(tmp_path, "733")
        # No idempotency hit — script proceeds to gh (which fails). We only
        # care that the wrong-match message is absent.
        assert "Already in history" not in result.stdout, (
            f"unexpected false-positive match; stdout={result.stdout!r}"
        )

    def test_detect_mid_parens_issue_number(self, tmp_path):
        """(c) #733 appears mid-parens (followed by comma, not closing paren) → detected."""
        _write_history(
            tmp_path,
            "### FEATURE: baz (2026-06-03, #733, abc1234)\n"
            "Background: x\n"
            "Changes: y\n",
        )
        result = _run_script(tmp_path, "733")
        assert "Already in history" in result.stdout, (
            f"expected idempotency hit; stdout={result.stdout!r} stderr={result.stderr!r}"
        )

    def test_detect_trailing_parens_legacy_format(self, tmp_path):
        """(d) #733 at end of parens → detected (existing pattern handles this)."""
        _write_history(
            tmp_path,
            "### FEATURE: qux (2026-06-03, abc1234, #733)\n"
            "Background: x\n"
            "Changes: y\n",
        )
        result = _run_script(tmp_path, "733")
        assert "Already in history" in result.stdout, (
            f"expected idempotency hit; stdout={result.stdout!r} stderr={result.stderr!r}"
        )

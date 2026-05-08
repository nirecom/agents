"""Tests for bin/doc-append-plain.py.

Runs the script as a subprocess (the script's argparse + sys.exit boundary is
part of what we want to verify). All filesystem state lives under pytest's
``tmp_path`` fixture for isolation.

Skips gracefully when bin/doc-append-plain.py is not yet implemented.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "bin" / "doc-append-plain.py"


def _skip_if_source_missing() -> None:
    """Function-level skip — keeps pytest exit code at 0 (vs module-level
    skip which yields exit code 5 = "no tests collected")."""
    if not SCRIPT.is_file():
        pytest.skip(f"bin/doc-append-plain.py not yet implemented at {SCRIPT}")


@pytest.fixture(autouse=True)
def _source_present_or_skip():
    """Auto-skip every test in this module when the source script is absent."""
    _skip_if_source_missing()


def test_source_implementation_marker():
    """Sentinel test so pytest always collects at least one item — when the
    source is missing, the autouse fixture skips this and every other test,
    yielding exit code 0 instead of pytest's "nothing collected" exit 5."""
    assert SCRIPT.is_file()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run(
    *args: str,
    cwd: Path | None = None,
    env_overrides: dict[str, str] | None = None,
    extra_env: dict[str, str] | None = None,
    timeout: float = 30.0,
) -> subprocess.CompletedProcess[str]:
    """Invoke the script via `python` with explicit cwd/env."""
    env = os.environ.copy()
    if env_overrides is not None:
        env = env_overrides
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        cwd=str(cwd) if cwd else None,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _isolated_env(tmp_path: Path) -> dict[str, str]:
    """Build a near-empty env. Keep PATH (for python) and HOME/SYSTEMROOT.

    Strips CLAUDE_PROJECT_DIR and any GIT_* variables that could influence
    default-path resolution.
    """
    keep = {"PATH", "PATHEXT", "PYTHONPATH", "PYTHONHOME", "PYTHONIOENCODING",
            "HOME", "USERPROFILE", "SYSTEMROOT", "TEMP", "TMP", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE", "APPDATA", "LOCALAPPDATA"}
    return {k: v for k, v in os.environ.items() if k in keep}


# ---------------------------------------------------------------------------
# Normal cases
# ---------------------------------------------------------------------------


class TestOneArgFormUsesClaudeProjectDir:
    """1-arg form → default path resolved from CLAUDE_PROJECT_DIR."""

    def test_one_arg_appends_to_default_todo(self, tmp_path: Path):
        proj = tmp_path / "proj"
        (proj / "docs").mkdir(parents=True)
        env = _isolated_env(tmp_path)
        env["CLAUDE_PROJECT_DIR"] = str(proj)
        # Run from tmp_path so any git-repo fallback would not coincidentally
        # resolve to a real repo.
        r = _run("hello world", env_overrides=env, cwd=tmp_path)
        assert r.returncode == 0, f"stderr={r.stderr}"
        target = proj / "docs" / "todo.md"
        assert target.is_file()
        assert "hello world" in target.read_text(encoding="utf-8")


class TestTwoArgFormWritesToGivenPath:
    """2-arg `(path, text)` → text appended to specified file."""

    def test_two_arg_explicit_path(self, tmp_path: Path):
        target = tmp_path / "notes.md"
        r = _run(str(target), "the line",
                 env_overrides=_isolated_env(tmp_path), cwd=tmp_path)
        assert r.returncode == 0, f"stderr={r.stderr}"
        assert target.read_text(encoding="utf-8").rstrip("\r\n") == "the line"


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


class TestMissingFileCreatedWithParentDir:
    """Missing target file → created; missing parent dir → also created."""

    def test_missing_file_and_parent_created(self, tmp_path: Path):
        target = tmp_path / "deep" / "nested" / "path" / "todo.md"
        assert not target.parent.exists()
        r = _run(str(target), "first line",
                 env_overrides=_isolated_env(tmp_path), cwd=tmp_path)
        assert r.returncode == 0, f"stderr={r.stderr}"
        assert target.is_file()
        assert target.parent.is_dir()
        assert "first line" in target.read_text(encoding="utf-8")


class TestExistingFileWithoutTrailingNewline:
    """File without trailing newline → leading newline added before text."""

    def test_no_trailing_newline_gets_leading_newline(self, tmp_path: Path):
        target = tmp_path / "f.md"
        target.write_bytes(b"existing")  # no trailing newline
        r = _run(str(target), "appended",
                 env_overrides=_isolated_env(tmp_path), cwd=tmp_path)
        assert r.returncode == 0, f"stderr={r.stderr}"
        # We expect a separator newline between "existing" and "appended".
        data = target.read_bytes()
        assert data.startswith(b"existing")
        # There must be at least one newline between the original and the
        # appended text.
        idx = data.find(b"appended")
        assert idx > 0
        assert data[idx - 1:idx] in (b"\n",)


class TestCRLFFilePreservesCRLF:
    """CRLF file → CRLF preserved when appending."""

    def test_crlf_preserved(self, tmp_path: Path):
        target = tmp_path / "crlf.md"
        target.write_bytes(b"line1\r\nline2\r\n")
        r = _run(str(target), "appended",
                 env_overrides=_isolated_env(tmp_path), cwd=tmp_path)
        assert r.returncode == 0, f"stderr={r.stderr}"
        data = target.read_bytes()
        # Original CRLF lines preserved.
        assert b"line1\r\nline2\r\n" in data
        # The appended text should be terminated with CRLF too (matching the
        # detected file convention).
        assert data.rstrip().endswith(b"appended")
        assert b"appended\r\n" in data or data.endswith(b"appended\r\n")


# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------


class TestZeroArgsExits2:
    """0 args → exit 2."""

    def test_zero_args(self, tmp_path: Path):
        r = _run(env_overrides=_isolated_env(tmp_path), cwd=tmp_path)
        assert r.returncode == 2, f"expected 2, got {r.returncode}; stderr={r.stderr}"


class TestNoDefaultPathResolvableExits2:
    """CLAUDE_PROJECT_DIR unset and not inside a git repo → exit 2."""

    def test_no_default_path(self, tmp_path: Path):
        # Use an empty dir guaranteed not to be inside any git repo.
        # Strip any inherited CLAUDE_PROJECT_DIR.
        non_git = tmp_path / "non-git"
        non_git.mkdir()
        env = _isolated_env(tmp_path)
        env.pop("CLAUDE_PROJECT_DIR", None)
        # On most CI hosts tmp_path is outside any git repo. If git is on PATH
        # and somehow finds a repo above tmp_path, this test cannot run
        # meaningfully. Detect and skip in that case.
        gitexe = shutil.which("git")
        if gitexe:
            probe = subprocess.run(
                [gitexe, "rev-parse", "--show-toplevel"],
                cwd=str(non_git), capture_output=True, text=True, timeout=10,
            )
            if probe.returncode == 0 and probe.stdout.strip():
                pytest.skip(
                    "tmp_path appears to be inside a git repo "
                    f"({probe.stdout.strip()}); cannot test 'outside repo' path"
                )
        r = _run("just text", env_overrides=env, cwd=non_git)
        assert r.returncode == 2, (
            f"expected 2, got {r.returncode}; "
            f"stdout={r.stdout!r} stderr={r.stderr!r}"
        )


class TestThreeOrMoreArgsExits2:
    """3+ args → exit 2."""

    def test_three_args(self, tmp_path: Path):
        target = tmp_path / "f.md"
        r = _run(str(target), "text", "extra",
                 env_overrides=_isolated_env(tmp_path), cwd=tmp_path)
        assert r.returncode == 2, f"expected 2, got {r.returncode}; stderr={r.stderr}"

    def test_four_args(self, tmp_path: Path):
        target = tmp_path / "f.md"
        r = _run(str(target), "a", "b", "c",
                 env_overrides=_isolated_env(tmp_path), cwd=tmp_path)
        assert r.returncode == 2, f"expected 2, got {r.returncode}; stderr={r.stderr}"


# ---------------------------------------------------------------------------
# Idempotency: stream-append by design
# ---------------------------------------------------------------------------


class TestIdempotencyStreamAppend:
    """Running with the same line twice produces two lines (append-only)."""

    def test_same_line_twice_two_lines(self, tmp_path: Path):
        target = tmp_path / "stream.md"
        env = _isolated_env(tmp_path)
        for _ in range(2):
            r = _run(str(target), "duplicate line",
                     env_overrides=env, cwd=tmp_path)
            assert r.returncode == 0, f"stderr={r.stderr}"
        text = target.read_text(encoding="utf-8")
        # Two occurrences expected.
        assert text.count("duplicate line") == 2, f"got: {text!r}"


# ---------------------------------------------------------------------------
# Security: shell metacharacters / null byte / unicode preserved verbatim
# ---------------------------------------------------------------------------


class TestSecurityVerbatimContent:
    """No os.system / shell exec — content is preserved verbatim."""

    def test_shell_metacharacters_preserved(self, tmp_path: Path):
        target = tmp_path / "meta.md"
        sentinel = tmp_path / "PWNED"
        # Construct a payload that, if exec'd via a shell, would create the
        # sentinel. Different metachars to cover ;, $(...), backtick, |, &&.
        payloads = [
            f"; mkdir {sentinel}-a",
            f"$(mkdir {sentinel}-b)",
            f"`mkdir {sentinel}-c`",
            f"| mkdir {sentinel}-d",
            f"&& mkdir {sentinel}-e",
        ]
        env = _isolated_env(tmp_path)
        for p in payloads:
            r = _run(str(target), p, env_overrides=env, cwd=tmp_path)
            assert r.returncode == 0, f"payload={p!r} stderr={r.stderr}"
        # No sentinel directory should exist.
        for suffix in ("a", "b", "c", "d", "e"):
            assert not (tmp_path / f"PWNED-{suffix}").exists(), \
                f"injection executed for suffix {suffix}"
        # All payloads should be present verbatim in the file.
        text = target.read_text(encoding="utf-8")
        for p in payloads:
            assert p in text, f"payload not preserved verbatim: {p!r}"

    def test_unicode_preserved(self, tmp_path: Path):
        target = tmp_path / "uni.md"
        env = _isolated_env(tmp_path)
        # A mix of CJK + emoji-free symbols (avoid emoji per project rules).
        line = "テスト 文字列 — αβγ"
        r = _run(str(target), line, env_overrides=env, cwd=tmp_path)
        assert r.returncode == 0, f"stderr={r.stderr}"
        text = target.read_text(encoding="utf-8")
        assert line in text


# ---------------------------------------------------------------------------
# Integration: append into existing file with newline already present
# ---------------------------------------------------------------------------


class TestExistingFileWithTrailingNewlineNoExtraNewline:
    """File already ends with a newline → no double-newline introduced."""

    def test_no_double_newline(self, tmp_path: Path):
        target = tmp_path / "f.md"
        target.write_bytes(b"existing\n")
        env = _isolated_env(tmp_path)
        r = _run(str(target), "appended", env_overrides=env, cwd=tmp_path)
        assert r.returncode == 0, f"stderr={r.stderr}"
        data = target.read_bytes()
        # Should be exactly: existing\nappended\n (no blank line between).
        assert data == b"existing\nappended\n", f"got: {data!r}"

"""Shared test helpers. A test file puts `tests/lib` on `sys.path`, then writes `import harness`.

Importing this module registers the `target` mark, so `@pytest.mark.target("<path>")` raises
no unknown-mark warning. A known failure is written `@pytest.mark.xfail(strict=True)`; this
module adds no helper for it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

_PINNED = {"WORKFLOW_STATE_DIR": "workflow-state", "WORKFLOW_PLANS_DIR": "plans"}
_REMOVED = ("CLAUDE_CODE_SESSION_ID",)

# `_config` is private: without it (no run in progress, or a later release) the mark stays
# unregistered and only the warning comes back.
_config = getattr(pytest.mark, "_config", None)
if _config is not None:
    _config.addinivalue_line("markers", "target(path): the source file this case guards")


class _Isolation:
    def __init__(self) -> None:
        self._saved: dict[str, str | None] | None = None
        self._root: Path | None = None

    def __enter__(self) -> _Isolation:
        self._saved = {name: os.environ.get(name) for name in (*_PINNED, *_REMOVED)}
        self._root = Path(tempfile.mkdtemp(prefix="harness-"))
        for name, leaf in _PINNED.items():
            (self._root / leaf).mkdir()
            os.environ[name] = str(self._root / leaf)
        for name in _REMOVED:
            os.environ.pop(name, None)
        return self

    def __exit__(self, *_exc: object) -> None:
        saved, self._saved = self._saved, None
        if saved is None:
            return
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        shutil.rmtree(self._root, ignore_errors=True)


def isolate() -> _Isolation:
    """`with isolate():` re-points the workflow dirs into a fresh temp directory and removes
    the session variables; leaving the block puts every value back."""
    return _Isolation()


def git_init(path: str) -> None:
    """A fixture repo where no installed hook fires and no ignore file of the developer applies."""
    excludes = (Path(path).resolve() / ".git" / "info" / "exclude").as_posix()
    for args in (
        ["init", "-q", path],
        ["-C", path, "config", "core.hooksPath", "/dev/null"],
        ["-C", path, "config", "core.excludesFile", excludes],
    ):
        subprocess.run(["git", *args], check=True, capture_output=True)


def _tl3_value() -> str:
    value = os.environ.get("RUN_TL3", "")
    if value:
        return value
    reader = Path(__file__).resolve().parents[2] / "bin" / "get-config-var"
    # Windows process creation searches the system directory before PATH, so a bare "bash"
    # can start a different shell than the one on PATH; resolve it here.
    shell = shutil.which("bash")
    if shell is None:
        return ""
    try:
        done = subprocess.run(
            [shell, reader.as_posix(), "RUN_TL3", "off"],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip()


def require_tl3() -> None:
    """Skips the calling test unless RUN_TL3 is on. The process value wins; without one,
    bin/get-config-var answers. A lookup that fails reads as off."""
    if _tl3_value().lower() != "on":
        pytest.skip("RUN_TL3 is off")

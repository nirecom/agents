# Tests: bin/normalize-harness-position.py
# Tags: scope:issue-specific, TL2, bin, normalize-harness-position, harness, python
"""#2413: per-file statuses of bin/normalize-harness-position.py and the files it writes.

Each case runs the script as a subprocess on one temp file (no --all-multi-path, so the
registry CLI is never reached) and checks the printed status line and the file bytes.
"""

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: F401

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bin" / "normalize-harness-position.py"
HARNESS_SCR = '. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"'
HARNESS_REPO = '. "$REPO_ROOT/tests/lib/harness.sh"'
SCR_ROOT = 'SCRIPT_CHECKOUT_ROOT="$(pwd)"'

MISPLACED = f"#!/bin/bash\n# Tests: hooks/lib/x.js, bin/y.sh\n{HARNESS_SCR}\n{SCR_ROOT}\npass() {{ echo ok; }}\nPASS=0; FAIL=0\necho body\n"
PLACED = f"#!/bin/bash\n{SCR_ROOT}\n{HARNESS_SCR}\necho body\n"
NO_HARNESS = f"#!/bin/bash\n{SCR_ROOT}\necho body\n"


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        check=False, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
    )


def fixture(tmp_path: Path, text: str, name: str = "t.sh") -> Path:
    f = tmp_path / name
    f.write_bytes(text.encode("utf-8"))
    return f


def lines_of(f: Path) -> list[str]:
    return f.read_text(encoding="utf-8").splitlines()


@pytest.mark.target("bin/normalize-harness-position.py")
def test_dry_run_reports_and_leaves_file(tmp_path: Path) -> None:
    f = fixture(tmp_path, MISPLACED)
    done = run("--dry-run", str(f))
    assert done.returncode == 0, done.stderr
    assert f"DRY-RUN: {f}" in done.stdout.splitlines()
    assert "(dry-run: no files written)" in done.stdout
    assert f.read_bytes() == MISPLACED.encode("utf-8")


@pytest.mark.target("bin/normalize-harness-position.py")
def test_modified_moves_harness_after_root_var(tmp_path: Path) -> None:
    f = fixture(tmp_path, MISPLACED)
    done = run(str(f))
    assert done.returncode == 0, done.stderr
    assert f"MODIFIED: {f}" in done.stdout.splitlines()
    got = lines_of(f)
    root = got.index(SCR_ROOT)
    assert got[root + 1] == HARNESS_SCR
    assert got.count(HARNESS_SCR) == 1
    assert "pass() { echo ok; }" not in got
    assert "PASS=0; FAIL=0" not in got
    assert "echo body" in got


@pytest.mark.target("bin/normalize-harness-position.py")
def test_rerun_after_modified_is_already_ok(tmp_path: Path) -> None:
    f = fixture(tmp_path, MISPLACED)
    assert run(str(f)).returncode == 0
    after_first = f.read_bytes()
    done = run(str(f))
    assert done.returncode == 0, done.stderr
    assert f"ALREADY-OK: {f}" in done.stdout.splitlines()
    assert f.read_bytes() == after_first


@pytest.mark.target("bin/normalize-harness-position.py")
@pytest.mark.parametrize("text", [
    PLACED,
    f'#!/bin/bash\nREPO_ROOT="$(pwd)"\n\n{HARNESS_REPO}\necho body\n',
], ids=["directly-after", "one-blank-between"])
def test_already_ok_leaves_file(tmp_path: Path, text: str) -> None:
    f = fixture(tmp_path, text)
    done = run(str(f))
    assert done.returncode == 0, done.stderr
    assert f"ALREADY-OK: {f}" in done.stdout.splitlines()
    assert f.read_bytes() == text.encode("utf-8")


@pytest.mark.target("bin/normalize-harness-position.py")
def test_no_harness_without_flag_leaves_file(tmp_path: Path) -> None:
    f = fixture(tmp_path, NO_HARNESS)
    done = run(str(f))
    assert done.returncode == 0, done.stderr
    assert f"NO-HARNESS: {f}" in done.stdout.splitlines()
    assert "skipped=1" in done.stdout
    assert f.read_bytes() == NO_HARNESS.encode("utf-8")


@pytest.mark.target("bin/normalize-harness-position.py")
@pytest.mark.parametrize("root_line,want", [
    ('SCRIPT_CHECKOUT_ROOT="$(pwd)"', HARNESS_SCR),
    ('REPO_ROOT="$(pwd)"', HARNESS_REPO),
], ids=["script-checkout-root", "repo-root"])
def test_add_harness_inserts_line_after_root_var(tmp_path: Path, root_line: str, want: str) -> None:
    text = f"#!/bin/bash\n{root_line}\necho body\n"
    f = fixture(tmp_path, text)
    dry = run("--dry-run", "--add-harness", str(f))
    assert dry.returncode == 0, dry.stderr
    assert f"DRY-RUN: {f}" in dry.stdout.splitlines()
    assert f.read_bytes() == text.encode("utf-8")
    done = run("--add-harness", str(f))
    assert done.returncode == 0, done.stderr
    assert f"MODIFIED: {f}" in done.stdout.splitlines()
    got = lines_of(f)
    assert got[got.index(root_line) + 1] == want


@pytest.mark.target("bin/normalize-harness-position.py")
@pytest.mark.parametrize("extra", [[], ["--add-harness"]], ids=["plain", "add-harness"])
def test_no_root_var_leaves_file(tmp_path: Path, extra: list[str]) -> None:
    text = f"#!/bin/bash\n{HARNESS_SCR}\necho body\n"
    f = fixture(tmp_path, text)
    done = run(*extra, str(f))
    assert done.returncode == 0, done.stderr
    assert f"NO-ROOT-VAR: {f}" in done.stdout.splitlines()
    assert f.read_bytes() == text.encode("utf-8")


@pytest.mark.target("bin/normalize-harness-position.py")
@pytest.mark.parametrize("args", [[], ["--dry-run"], ["--add-harness"]], ids=["none", "dry-run-only", "add-harness-only"])
def test_no_target_prints_usage_rc1(args: list[str]) -> None:
    done = run(*args)
    assert done.returncode == 1
    assert "Usage:" in done.stderr
    assert done.stdout == ""


@pytest.mark.target("bin/normalize-harness-position.py")
def test_unreadable_file_is_error_rc1(tmp_path: Path) -> None:
    missing = tmp_path / "absent.sh"
    done = run(str(missing))
    assert done.returncode == 1
    assert "ERROR:" in done.stdout
    assert "errors=1" in done.stdout
    assert not missing.exists()

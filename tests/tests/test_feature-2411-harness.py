# Tests: tests/lib/harness.py
# Tags: test-infra, pytest, harness, TL2, scope:issue-specific
# TL3 gap (what this test does NOT catch):
# - a tests/run-all.sh run, where the command guard git and the run-root pin are active
# - the registry's own `uv run --with pytest>=<min>` resolution (children reuse sys.executable)
# Closest-to-action mitigation: the full tests/run-all.sh run of the release gate;
# no bin/check-verification-gate.sh category covers a test helper library.
"""harness.py contract (#2411): isolate(), git_init(), require_tl3(), the `target` marker,
and loading through the real pytest wrapper from a copied tree."""

from __future__ import annotations

import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "tests" / "lib" / "harness.py"
WRAPPER_REL = "bin/lib/test-wrappers/pytest.py"
REGISTRY = json.loads((REPO_ROOT / "hooks" / "lib" / "test-language-registry.json").read_text(encoding="utf-8"))
LOAD_LINES = 'import sys\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))\n'
PIN_NAMES = ("WORKFLOW_STATE_DIR", "WORKFLOW_PLANS_DIR")
REMOVED_NAMES = ("CLAUDE_CODE_SESSION_ID",)
ISO_NAMES = PIN_NAMES + REMOVED_NAMES
SENTINEL = {name: f"h2411-secret-{uuid.uuid4().hex}" for name in ISO_NAMES}
PRESETS = {
    "all-set": {name: f"h2411-{name.lower()}" for name in ISO_NAMES},
    "all-unset": {},
    "mixed": {"WORKFLOW_PLANS_DIR": "h2411-plans", "CLAUDE_CODE_SESSION_ID": "h2411-ccsid"},
}


def apply_preset(monkeypatch, preset: dict[str, str]) -> dict[str, str | None]:
    for name in ISO_NAMES:
        if name in preset:
            monkeypatch.setenv(name, preset[name])
        else:
            monkeypatch.delenv(name, raising=False)
    return {name: preset.get(name) for name in ISO_NAMES}


def snapshot() -> dict[str, str | None]:
    return {name: os.environ.get(name) for name in ISO_NAMES}


def make_tree(tmp_path: Path, category: str) -> Path:
    """A temp tree shaped like the repo's tests/: tests/<category>/ and tests/lib/ with the real helper."""
    root = tmp_path / f"tree-{uuid.uuid4().hex}"
    (root / "tests" / category).mkdir(parents=True)
    (root / "tests" / "lib").mkdir()
    shutil.copyfile(HELPER, root / "tests" / "lib" / "harness.py")
    return root


def run_wrapper(test_file: Path, cwd: Path, tmp_path: Path, env_extra: dict[str, str] | None = None):
    """One file through the real wrapper, with the registry launch.command from {wrapper} on."""
    launch = next(e["launch"] for e in REGISTRY["entries"] if e.get("launch", {}).get("wrapper") == WRAPPER_REL)
    values = {"{wrapper}": str(REPO_ROOT / WRAPPER_REL), "{nativePath}": str(test_file), "{minVersion}": launch["minVersion"]["version"]}
    tail = launch["command"][launch["command"].index("{wrapper}"):]
    result_dir = tmp_path / f"result-{uuid.uuid4().hex}"
    env = dict(os.environ, RUN_ALL_RESULT_DIR=str(result_dir), **(env_extra or {}))
    proc = subprocess.run(
        [sys.executable] + [values.get(arg, arg) for arg in tail],
        cwd=cwd, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=100, check=False,
    )
    cases = result_dir / "cases.tsv"
    return proc.returncode, proc.stdout + proc.stderr, cases.read_text(encoding="utf-8") if cases.exists() else ""


def has_case(cases: str, state: str, name: str) -> bool:
    return re.search(rf"\t{state}\t[^\t\n]*{re.escape(name)}\t", cases) is not None


# --- isolation ---


@pytest.mark.parametrize("label", sorted(PRESETS))
def test_isolate_pins_removes_and_restores(monkeypatch, label):
    preset = PRESETS[label]
    before = apply_preset(monkeypatch, preset)
    temp_root = Path(tempfile.gettempdir()).resolve()
    with harness.isolate():
        for name in PIN_NAMES:
            value = os.environ.get(name)
            assert value and value != preset.get(name)
            assert Path(value).is_dir()
            assert temp_root in Path(value).resolve().parents
        for name in REMOVED_NAMES:
            assert name not in os.environ, name
    assert snapshot() == {name: before[name] for name in ISO_NAMES}


def test_isolate_gives_each_entry_its_own_directory(monkeypatch):
    apply_preset(monkeypatch, {})
    with harness.isolate():
        first = os.environ["WORKFLOW_STATE_DIR"]
    with harness.isolate():
        assert os.environ["WORKFLOW_STATE_DIR"] != first


def test_isolate_restores_after_exception(monkeypatch):
    before = apply_preset(monkeypatch, PRESETS["mixed"])
    with pytest.raises(RuntimeError, match="body failed"):
        with harness.isolate():
            assert os.environ.get("WORKFLOW_PLANS_DIR") != "h2411-plans"
            raise RuntimeError("body failed")
    assert snapshot() == before


def test_isolate_second_exit_is_harmless(monkeypatch):
    before = apply_preset(monkeypatch, PRESETS["mixed"])
    context = harness.isolate()
    context.__enter__()
    context.__exit__(None, None, None)
    context.__exit__(None, None, None)
    assert snapshot() == before


# --- fixture git repo ---


@pytest.fixture
def global_excludes(monkeypatch, tmp_path):
    """A global config whose excludes file would hide ignored.txt, and no system config."""
    git_home = tmp_path / "githome"
    git_home.mkdir()
    ignore_file = git_home / "global-ignore"
    ignore_file.write_text("ignored.txt\n", encoding="utf-8")
    config = git_home / "gitconfig"
    config.write_text(f"[core]\n\texcludesFile = {ignore_file.as_posix()}\n", encoding="utf-8")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(config))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False, timeout=60)


def fixture_commit(repo: Path) -> dict:
    """Plants a failing pre-commit hook, then commits one file. Reports what the repo did."""
    hook = repo / ".git" / "hooks" / "pre-commit"
    hook.parent.mkdir(parents=True, exist_ok=True)
    hook.write_bytes(b"#!/bin/sh\necho ran > hook-ran.marker\nexit 1\n")
    hook.chmod(0o755)
    (repo / "tracked.txt").write_text("x\n", encoding="utf-8")
    (repo / "ignored.txt").write_text("x\n", encoding="utf-8")
    status = git(repo, "status", "--porcelain", "--untracked-files=all").stdout
    git(repo, "add", "tracked.txt")
    commit = git(repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init")
    return {"commit_rc": commit.returncode, "hook_ran": (repo / "hook-ran.marker").exists(), "status": status}


def test_git_control_plain_init_runs_hook_and_global_excludes(global_excludes, tmp_path):
    repo = tmp_path / "control"
    subprocess.run(["git", "init", "-q", str(repo)], check=True, capture_output=True, timeout=60)
    result = fixture_commit(repo)
    assert result["hook_ran"] and result["commit_rc"] != 0
    assert "ignored.txt" not in result["status"]


@pytest.mark.parametrize("dirname", ["plain", "with space dir"])
def test_git_init_fixture_repo(global_excludes, tmp_path, dirname):
    repo = tmp_path / dirname
    repo.mkdir()
    harness.git_init(str(repo))
    assert (repo / ".git").exists()
    result = fixture_commit(repo)
    assert result["commit_rc"] == 0 and not result["hook_ran"]
    assert "?? ignored.txt" in result["status"]
    excludes = git(repo, "config", "--local", "--get", "core.excludesFile").stdout.strip()
    assert excludes
    assert repo.resolve() in (repo / excludes).resolve().parents

    harness.git_init(str(repo))  # re-init of an existing repo: no error, history kept
    assert git(repo, "rev-list", "--count", "HEAD").stdout.strip() == "1"
    (repo / "second.txt").write_text("y\n", encoding="utf-8")
    git(repo, "add", "second.txt")
    assert git(repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "second").returncode == 0


# --- RUN_TL3 gate, known failure ---


def test_require_tl3_off_skips_and_on_returns(monkeypatch):
    monkeypatch.setenv("RUN_TL3", "off")
    with pytest.raises(pytest.skip.Exception):
        harness.require_tl3()
    monkeypatch.setenv("RUN_TL3", "on")
    harness.require_tl3()


TL3_BODY = LOAD_LINES + '''import harness


def test_tl3_gated():
    harness.require_tl3()
    Path(__file__).with_name("tl3.marker").write_text("ok", encoding="utf-8")
'''


def write_tl3_reader(root: Path, value: str, exit_code: int) -> None:
    """<root>/bin/get-config-var: answers value with exit_code, and only to `RUN_TL3 off`."""
    (root / "bin").mkdir()
    script = f"#!/usr/bin/env bash\n[ \"$1\" = RUN_TL3 ] && [ \"$2\" = off ] || exit 9\nprintf '%s\\n' '{value}'\nexit {exit_code}\n"
    (root / "bin" / "get-config-var").write_bytes(script.encode("utf-8"))


@pytest.mark.parametrize(
    ("label", "reader", "process_value", "gated"),
    [
        ("reader-on", ("on", 0), None, "PASS"),
        ("reader-off", ("off", 0), None, "SKIP"),
        ("no-reader", None, None, "SKIP"),
        ("reader-fails-after-on", ("on", 3), None, "SKIP"),
        ("reader-padded-mixed-case", (" On ", 0), None, "PASS"),
        ("process-off-over-reader-on", ("on", 0), "off", "SKIP"),
        ("process-on-over-reader-off", ("off", 0), "on", "PASS"),
    ],
)
def test_tl3_resolution(monkeypatch, tmp_path, label, reader, process_value, gated):
    """The reader is found from the helper file, not the working directory, and the
    developer's own RUN_TL3 never reaches the child."""
    monkeypatch.delenv("RUN_TL3", raising=False)
    root = make_tree(tmp_path, "tests")
    if reader is not None:
        write_tl3_reader(root, *reader)
    test_file = root / "tests" / "tests" / "test_tl3.py"
    test_file.write_text(TL3_BODY, encoding="utf-8")
    outside = tmp_path / "outside"
    outside.mkdir()
    rc, output, cases = run_wrapper(test_file, outside, tmp_path, {} if process_value is None else {"RUN_TL3": process_value})
    # The gated case is the child's only case, so a skip makes the wrapper answer 77.
    assert rc == (0 if gated == "PASS" else 77), f"{label}: {output}"
    assert has_case(cases, gated, "test_tl3_gated"), f"{label}: {cases}"
    assert test_file.with_name("tl3.marker").exists() == (gated == "PASS")


def test_known_failure_convention_strict_xfail(tmp_path):
    root = make_tree(tmp_path, "tests")
    body = LOAD_LINES + "import harness\nimport pytest\n\n"
    still = '@pytest.mark.xfail(strict=True, reason="open")\ndef test_still_fails():\n    assert False\n\n'
    stopped = '@pytest.mark.xfail(strict=True, reason="closed")\ndef test_stopped_failing():\n    assert True\n'
    open_file = root / "tests" / "tests" / "test_open.py"
    open_file.write_text(body + still, encoding="utf-8")
    rc, _, cases = run_wrapper(open_file, root, tmp_path)
    assert rc == 0 and has_case(cases, "XFAIL", "test_still_fails")

    closed_file = root / "tests" / "tests" / "test_closed.py"
    closed_file.write_text(body + still + stopped, encoding="utf-8")
    rc, _, cases = run_wrapper(closed_file, root, tmp_path)
    assert rc != 0
    assert has_case(cases, "XFAIL", "test_still_fails") and has_case(cases, "FAIL", "test_stopped_failing")


# --- loading through the real wrapper ---

LOAD_BODY = LOAD_LINES + '''import harness
import os
import pytest


@pytest.mark.target("tests/lib/harness.py")
def test_calls_helper():
    with harness.isolate():
        assert os.environ.get("WORKFLOW_STATE_DIR")
        assert "CLAUDE_CODE_SESSION_ID" not in os.environ
    Path(__file__).with_name("helper.marker").write_text("ok", encoding="utf-8")


def test_marker_registered(request):
    assert any(line.startswith("target(") for line in request.config.getini("markers"))


def test_tl3_gated():
    harness.require_tl3()
    Path(__file__).with_name("tl3.marker").write_text("ok", encoding="utf-8")
'''


@pytest.mark.parametrize(
    ("category", "cwd_kind", "tl3", "gated"),
    [("bin", "inside", "off", "SKIP"), ("tests", "inside", "on", "PASS"), ("bin", "outside", "on", "PASS"), ("tests", "outside", "off", "SKIP")],
)
def test_load_by_canonical_line(tmp_path, category, cwd_kind, tl3, gated):
    root = make_tree(tmp_path, category)
    test_file = root / "tests" / category / "test_load.py"
    test_file.write_text(LOAD_BODY, encoding="utf-8")
    cwd = root
    if cwd_kind == "outside":
        cwd = tmp_path / "outside"
        cwd.mkdir()
    rc, output, cases = run_wrapper(test_file, cwd, tmp_path, dict(SENTINEL, RUN_TL3=tl3))
    assert rc == 0, output
    assert has_case(cases, "PASS", "test_calls_helper") and has_case(cases, "PASS", "test_marker_registered")
    assert has_case(cases, gated, "test_tl3_gated")
    assert test_file.with_name("helper.marker").exists()
    assert test_file.with_name("tl3.marker").exists() == (tl3 == "on")
    assert "PytestUnknownMarkWarning" not in output
    # Security: the removed and restored values never reach the output.
    assert not [name for name in ISO_NAMES if SENTINEL[name] in output]


def test_target_marker_without_helper_warns_and_passes(tmp_path):
    root = make_tree(tmp_path, "tests")
    test_file = root / "tests" / "tests" / "test_no_helper.py"
    body = (
        'import pytest\n'
        '\n'
        '\n'
        '@pytest.mark.target("x")\n'
        'def test_plain():\n'
        '    assert True\n'
    )
    test_file.write_text(body, encoding="utf-8")
    rc, output, cases = run_wrapper(test_file, root, tmp_path)
    assert rc == 0 and has_case(cases, "PASS", "test_plain")
    assert "PytestUnknownMarkWarning" in output and "pytest.mark.target" in output


def test_other_unregistered_marker_still_warns_with_helper(tmp_path):
    root = make_tree(tmp_path, "tests")
    test_file = root / "tests" / "tests" / "test_other_marker.py"
    body = (
        '@pytest.mark.target("x")\n'
        '@pytest.mark.h2411_other\n'
        'def test_plain():\n'
        '    assert True\n'
    )
    test_file.write_text(LOAD_LINES + "import harness\nimport pytest\n\n\n" + body, encoding="utf-8")
    rc, output, cases = run_wrapper(test_file, root, tmp_path)
    assert rc == 0 and has_case(cases, "PASS", "test_plain")
    assert "PytestUnknownMarkWarning" in output and "pytest.mark.h2411_other" in output
    assert "pytest.mark.target" not in output


def test_import_without_sys_path_line_exits_1(tmp_path):
    root = make_tree(tmp_path, "tests")
    test_file = root / "tests" / "tests" / "test_no_path.py"
    test_file.write_text("import harness\n\n\ndef test_plain():\n    assert True\n", encoding="utf-8")
    rc, output, cases = run_wrapper(test_file, root, tmp_path)
    assert rc == 1
    assert "ModuleNotFoundError" in output and not has_case(cases, "PASS", "test_plain")


def test_helper_is_not_picked_up_as_a_test():
    assert HELPER.is_file()
    supported = [e for e in REGISTRY["entries"] if e["status"] == "supported"]
    assert supported

    def matching(name: str) -> list[str]:
        return [e["id"] for e in supported if any(fnmatch.fnmatchcase(name, p) for p in e["patterns"])]

    assert matching("harness.py") == []
    assert matching(Path(__file__).name)

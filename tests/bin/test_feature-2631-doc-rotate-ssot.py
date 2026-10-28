# Tests: bin/doc-rotate.py, hooks/lib/size-limits.js
# Tags: bin, python, size-limits, history, rotation, boundary, scope:issue-specific, layer:TL2, ssot
# TL3 gap (what this test does NOT catch):
# - the real /update-docs skill flow invoking doc-rotate.py with --threshold-warn-ssot
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
"""#2631 stage 2: `doc-rotate.py --threshold-warn-ssot` takes the rotation threshold from the
size-limit SSOT (history WARN = 500) instead of a number on the command line.

A history.md of exactly 500 lines rotates (archives beyond --floor); one of 499 lines is left
untouched. The explicit `--threshold-warn 500` run is the control: it already rotates at 500
today, so the SSOT flag must reproduce it exactly.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
DOC_ROTATE = REPO_ROOT / "bin" / "doc-rotate.py"
ENTRIES = 30
FLOOR = "5"


def _history(n_lines: int) -> str:
    """A history.md of exactly n_lines lines (splitlines count): title, padding, 30 dated entries."""
    entries = []
    for i in range(1, ENTRIES + 1):
        entries += [f"### FEATURE: S{i:02d} (2026-01-{i:02d}, hash{i:03d})", "Background: x.", "Changes: y."]
    pad = n_lines - 1 - len(entries)
    assert pad > 0, "fixture premise: room for the padding"
    lines = ["# History", *(f"<!-- pad {k} -->" for k in range(pad)), *entries]
    return "\n".join(lines) + "\n"


def _rotate(cwd: Path, hist: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(DOC_ROTATE), str(hist), *args, "--floor", FLOOR],
        capture_output=True,
        text=True,
        cwd=cwd,
        timeout=60,
    )


def _fixture(tmp_path: Path, n_lines: int, name: str = "repo") -> tuple[Path, Path]:
    repo = tmp_path / name
    repo.mkdir()
    harness.git_init(str(repo))
    docs = repo / "docs"
    docs.mkdir()
    hist = docs / "history.md"
    hist.write_text(_history(n_lines), encoding="utf-8", newline="\n")
    assert len(hist.read_text(encoding="utf-8").splitlines()) == n_lines, "fixture premise: exact line count"
    return repo, hist


@pytest.mark.target("bin/doc-rotate.py")
def test_explicit_threshold_rotates_at_500_control(tmp_path):
    with harness.isolate():
        repo, hist = _fixture(tmp_path, 500)
        r = _rotate(repo, hist, "--threshold-warn", "500")
        assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"
        assert (hist.parent / "history" / "2026.md").exists(), "control: 500 lines rotate at --threshold-warn 500"


@pytest.mark.target("hooks/lib/size-limits.js")
def test_ssot_threshold_rotates_at_exactly_500(tmp_path):
    with harness.isolate():
        repo, hist = _fixture(tmp_path, 500)
        r = _rotate(repo, hist, "--threshold-warn-ssot")
        assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"
        archive = hist.parent / "history" / "2026.md"
        assert archive.exists(), "500 lines (= the SSOT history WARN) must rotate"
        kept = [ln for ln in hist.read_text(encoding="utf-8").splitlines() if ln.startswith("### ")]
        assert len(kept) == int(FLOOR), f"the --floor newest entries stay: {kept}"


@pytest.mark.target("bin/doc-rotate.py")
def test_ssot_threshold_leaves_499_untouched(tmp_path):
    with harness.isolate():
        repo, hist = _fixture(tmp_path, 499)
        before = hist.read_text(encoding="utf-8")
        r = _rotate(repo, hist, "--threshold-warn-ssot")
        assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"
        assert hist.read_text(encoding="utf-8") == before, "499 lines are under the SSOT WARN: no rewrite"
        assert not (hist.parent / "history").exists(), "499 lines: no archive directory"


MUTATE_LIMITS = REPO_ROOT / "tests" / "hooks" / "feature-2631-size-limits" / "mutate-limits.js"
# doc-rotate.py reaches the SSOT through ../bin/print-size-limits -> ../hooks/lib/size-limits.js.
TREE_FILES = ("bin/doc-rotate.py", "bin/print-size-limits", "hooks/lib/size-limits.js")


def _limits_tree(tmp_path: Path, warn: int, hard: int) -> Path:
    """A checkout layout holding doc-rotate.py and its SSOT, the history limits rewritten."""
    tree = tmp_path / "tree"
    for rel in TREE_FILES:
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes((REPO_ROOT / rel).read_bytes())
    r = subprocess.run(
        ["node", str(MUTATE_LIMITS), str(tree), "history", str(warn), str(hard)],
        capture_output=True, text=True, timeout=60,
    )
    assert r.returncode == 0, f"fixture premise: the tree's SSOT says history {warn}/{hard}: {r.stderr}"
    return tree


def _rotate_with(tree: Path, cwd: Path, hist: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(tree / "bin" / "doc-rotate.py"), str(hist), "--threshold-warn-ssot", "--floor", FLOOR],
        capture_output=True, text=True, cwd=cwd, timeout=60,
    )


@pytest.mark.target("hooks/lib/size-limits.js")
def test_changed_ssot_history_warn_moves_the_rotation_boundary(tmp_path):
    """The SSOT history WARN lowered to 400: 450 lines rotate and 399 do not; the unmodified
    SSOT leaves the same 450 lines alone. A doc-rotate.py holding its own 500 fails here."""
    with harness.isolate():
        tree = _limits_tree(tmp_path, 400, 800)
        repo, hist = _fixture(tmp_path, 450, "lowered")
        r = _rotate_with(tree, repo, hist)
        assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"
        assert (hist.parent / "history" / "2026.md").exists(), "450 lines >= the changed SSOT WARN 400 must rotate"

        repo, hist = _fixture(tmp_path, 399, "under-lowered")
        before = hist.read_text(encoding="utf-8")
        r = _rotate_with(tree, repo, hist)
        assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"
        assert hist.read_text(encoding="utf-8") == before, "399 lines are under the changed WARN 400: no rewrite"

        repo, hist = _fixture(tmp_path, 450, "control")
        before = hist.read_text(encoding="utf-8")
        r = _rotate(repo, hist, "--threshold-warn-ssot")
        assert r.returncode == 0, f"stderr: {r.stderr}\nstdout: {r.stdout}"
        assert hist.read_text(encoding="utf-8") == before, "control: the repo SSOT (WARN 500) leaves 450 lines alone"
        assert not (hist.parent / "history").exists(), "control: no archive directory under the repo SSOT"

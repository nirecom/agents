# Tests: bin/doc-append.py, bin/compose-doc-append-entry, bin/doc-rotate.py
# Tags: bin, python, size-limits, history, rotation, boundary, idempotency, compose, scope:issue-specific, layer:TL2, ssot
# TL3 gap (what this test does NOT catch):
# - the real GitHub Contents / Git Data API round trip (the two writers are recording stubs here)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
"""#2631: the history append path reaches the size-limit SSOT (history WARN = 500) through
doc-append.py's auto-rotate and through compose-doc-append-entry's own rotation branch.

doc-append.py adds 4 lines per entry (blank separator + 3-line entry), so a 496-line history
reaches exactly 500 and rotates, while 495 -> 499 stays whole. compose-doc-append-entry runs
in a checkout copy whose GitHub writers are recording stubs, so the files it would upload are
observable on disk.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
DOC_APPEND = REPO_ROOT / "bin" / "doc-append.py"
ENTRIES = 30
KEPT_FLOOR = 20  # doc-append.py ROTATE_FLOOR
BASH = shutil.which("bash")
TREE_FILES = (
    "bin/compose-doc-append-entry", "bin/doc-append.py", "bin/doc-rotate.py", "bin/print-size-limits",
    "bin/workflow-plans-dir", "bin/lib/github-contents-validate.sh", "hooks/lib/size-limits.js",
    "hooks/lib/workflow-plans-dir.js",
)


def _history(n_lines: int) -> str:
    entries = []
    for i in range(1, ENTRIES + 1):
        entries += [f"### FEATURE: S{i:02d} (2026-01-{i:02d}, hash{i:03d})", "Background: x.", "Changes: y."]
    pad = n_lines - 1 - len(entries)
    assert pad > 0, "fixture premise: room for the padding"
    return "\n".join(["# History", *(f"<!-- pad {k} -->" for k in range(pad)), *entries]) + "\n"


def _headers(text: str) -> list[str]:
    return [ln for ln in text.splitlines() if ln.startswith("### ")]


def _seed(path: Path, n_lines: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_history(n_lines), encoding="utf-8", newline="\n")
    assert len(path.read_text(encoding="utf-8").splitlines()) == n_lines, "fixture premise: exact line count"


def _append(hist: Path, subject: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(DOC_APPEND), str(hist), "--category", "FEATURE", "--subject", subject,
         "--date", "2026-02-01", "--background", "b.", "--changes", "c."],
        capture_output=True, text=True, cwd=hist.parent, timeout=60,
    )


@pytest.mark.target("bin/doc-append.py")
def test_append_reaching_warn_rotates_into_archive(tmp_path):
    with harness.isolate():
        hist = tmp_path / "docs" / "history.md"
        _seed(hist, 496)
        r = _append(hist, "NEW")
        assert r.returncode == 0, f"stderr: {r.stderr}"
        archive = hist.parent / "history" / "2026.md"
        assert archive.exists(), "496 + 4 = 500 lines (= SSOT history WARN) must rotate"
        kept, archived = _headers(hist.read_text(encoding="utf-8")), _headers(archive.read_text(encoding="utf-8"))
        assert len(kept) == KEPT_FLOOR, f"the {KEPT_FLOOR} newest entries stay: {kept}"
        assert kept[-1].startswith("### FEATURE: NEW "), "the appended entry is kept in history.md"
        assert len(kept) + len(archived) == ENTRIES + 1, "every entry lands exactly once across the two files"


@pytest.mark.target("bin/doc-append.py")
def test_append_below_warn_leaves_history_whole(tmp_path):
    with harness.isolate():
        hist = tmp_path / "docs" / "history.md"
        _seed(hist, 495)
        r = _append(hist, "NEW")
        assert r.returncode == 0, f"stderr: {r.stderr}"
        text = hist.read_text(encoding="utf-8")
        assert len(text.splitlines()) == 499, "495 + 4 = 499 lines"
        assert len(_headers(text)) == ENTRIES + 1, "no entry moved out below the WARN"
        assert not (hist.parent / "history").exists(), "499 lines: no archive directory"


@pytest.mark.target("bin/doc-append.py")
def test_append_into_missing_directory_fails_without_writing(tmp_path):
    with harness.isolate():
        hist = tmp_path / "absent" / "history.md"
        r = subprocess.run(
            [sys.executable, str(DOC_APPEND), str(hist), "--category", "FEATURE", "--subject", "S",
             "--date", "2026-02-01", "--background", "b.", "--changes", "c."],
            capture_output=True, text=True, cwd=tmp_path, timeout=60,
        )
        assert r.returncode == 1, f"rc={r.returncode} stderr: {r.stderr}"
        assert "parent directory does not exist" in r.stderr
        assert not hist.parent.exists(), "a refused append creates nothing"


@pytest.mark.target("bin/doc-rotate.py")
def test_second_append_after_rotation_does_not_rearchive(tmp_path):
    with harness.isolate():
        hist = tmp_path / "docs" / "history.md"
        _seed(hist, 496)
        assert _append(hist, "FIRST").returncode == 0
        archive = hist.parent / "history" / "2026.md"
        archive_before = archive.read_bytes()
        r = _append(hist, "SECOND")
        assert r.returncode == 0, f"stderr: {r.stderr}"
        assert archive.read_bytes() == archive_before, "a history back under the WARN leaves the archive untouched"
        assert len(_headers(hist.read_text(encoding="utf-8"))) == KEPT_FLOOR + 1, "no entry duplicated or lost"


# --- compose-doc-append-entry through a checkout copy with recording GitHub writers ---

_GH_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GH_STUB_LOG"
case "$*" in
  "api repos/o/r --jq .default_branch") echo main ;;
  "api repos/o/r/contents/docs/history.md?ref=main")
    [[ -f "$GH_STUB_HISTORY" ]] || exit 1
    printf '{"content":"%s"}' "$(base64 -w0 "$GH_STUB_HISTORY")" ;;
  *) exit 1 ;;
esac
"""

# Each writer copies every repo-path=local-file pair it is handed into $UPLOAD_DIR/<repo-path>.
_WRITER_STUB = """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$(basename "$0") $*" >> "$GH_STUB_LOG"
repo_path="" pairs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) if [[ "$2" == *=* ]]; then pairs+=("$2"); else pairs+=("${repo_path}=$2"); fi; shift 2 ;;
    --path) repo_path="$2"; shift 2 ;;
    *) shift 2 ;;
  esac
done
for p in "${pairs[@]}"; do
  mkdir -p "$(dirname "$UPLOAD_DIR/${p%%=*}")"
  cp "${p#*=}" "$UPLOAD_DIR/${p%%=*}"
done
"""


def _tree(tmp_path: Path) -> Path:
    tree = tmp_path / "tree"
    for rel in TREE_FILES:
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes((REPO_ROOT / rel).read_bytes())
    for name in ("github-contents-write.sh", "github-git-data-write.sh"):
        (tree / "bin" / "lib" / name).write_text(_WRITER_STUB, encoding="utf-8", newline="\n")
    stub_bin = tmp_path / "stub-bin"
    stub_bin.mkdir()
    (stub_bin / "gh").write_text(_GH_STUB, encoding="utf-8", newline="\n")
    return tree


def _compose(tmp_path: Path, tree: Path, remote_lines: int | None) -> subprocess.CompletedProcess:
    remote = tmp_path / "remote-history.md"
    if remote_lines is not None and not remote.exists():
        _seed(remote, remote_lines)
    notes = tmp_path / "WORKTREE_NOTES.md"
    notes.write_text("## History Notes\n- feat: the change\n\n## Changelog Notes\n- (none)\n",
                     encoding="utf-8", newline="\n")
    (tmp_path / "upload").mkdir(exist_ok=True)
    env = dict(os.environ, GH_STUB_LOG=str(tmp_path / "gh.log"), GH_STUB_HISTORY=str(remote),
               UPLOAD_DIR=str(tmp_path / "upload"))
    env["PATH"] = str(tmp_path / "stub-bin") + os.pathsep + env["PATH"]
    return subprocess.run(
        [BASH, str(tree / "bin" / "compose-doc-append-entry"), "--notes", str(notes), "--branch", "feature/x",
         "--pr", "7", "--repo", "o/r", "--background", "bg.", "--history"],
        capture_output=True, text=True, cwd=tmp_path, env=env, timeout=110,
    )


def _uploaded(tmp_path: Path) -> list[str]:
    root = tmp_path / "upload"
    return sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file())


@pytest.mark.skipif(BASH is None, reason="bash is not on PATH")
@pytest.mark.target("bin/compose-doc-append-entry")
def test_compose_below_warn_uploads_history_only(tmp_path):
    with harness.isolate():
        tree = _tree(tmp_path)
        r = _compose(tmp_path, tree, 400)
        assert r.returncode == 0, f"stderr: {r.stderr}"
        assert _uploaded(tmp_path) == ["docs/history.md"], "below the WARN only history.md is written"
        text = (tmp_path / "upload" / "docs" / "history.md").read_text(encoding="utf-8")
        assert len(_headers(text)) == ENTRIES + 1, "the new entry is appended to the whole history"


@pytest.mark.skipif(BASH is None, reason="bash is not on PATH")
@pytest.mark.target("bin/compose-doc-append-entry")
def test_compose_reaching_warn_uploads_history_and_archive(tmp_path):
    with harness.isolate():
        tree = _tree(tmp_path)
        r = _compose(tmp_path, tree, 496)
        assert r.returncode == 0, f"stderr: {r.stderr}"
        uploaded = _uploaded(tmp_path)
        assert "docs/history.md" in uploaded and "docs/history/2026.md" in uploaded, (
            f"a rotation at the WARN must upload history.md together with its archive: {uploaded}")
        kept = _headers((tmp_path / "upload" / "docs" / "history.md").read_text(encoding="utf-8"))
        archived = _headers((tmp_path / "upload" / "docs" / "history" / "2026.md").read_text(encoding="utf-8"))
        assert len(kept) + len(archived) == ENTRIES + 1, "no entry is lost between history.md and the archive"


@pytest.mark.skipif(BASH is None, reason="bash is not on PATH")
@pytest.mark.target("bin/compose-doc-append-entry")
def test_compose_rerun_for_the_same_pr_writes_nothing(tmp_path):
    with harness.isolate():
        tree = _tree(tmp_path)
        assert _compose(tmp_path, tree, 400).returncode == 0
        shutil.rmtree(tmp_path / "upload")
        r = _compose(tmp_path, tree, 400)
        assert r.returncode == 0, f"stderr: {r.stderr}"
        assert _uploaded(tmp_path) == [], "the per-PR marker suppresses a duplicate history write"


@pytest.mark.skipif(BASH is None, reason="bash is not on PATH")
@pytest.mark.target("bin/compose-doc-append-entry")
def test_compose_without_remote_history_fails_without_writing(tmp_path):
    with harness.isolate():
        tree = _tree(tmp_path)
        r = _compose(tmp_path, tree, None)
        assert r.returncode == 1, f"rc={r.returncode} stderr: {r.stderr}"
        assert "docs/history.md missing on remote" in r.stderr
        assert _uploaded(tmp_path) == [], "an aborted append uploads nothing"


# --- rotation dependency failure: the size-limit CLI doc-rotate.py reads is broken ---

_FAILING_SIZE_LIMITS = "#!/usr/bin/env node\nprocess.stderr.write('size-limits stub: boom\\n');\nprocess.exit(3);\n"


@pytest.mark.target("bin/doc-append.py")
def test_append_with_failing_size_limit_cli_reports_rotate_failure(tmp_path):
    with harness.isolate():
        tree = tmp_path / "tree" / "bin"
        tree.mkdir(parents=True)
        for name in ("doc-append.py", "doc-rotate.py"):
            (tree / name).write_bytes((REPO_ROOT / "bin" / name).read_bytes())
        (tree / "print-size-limits").write_text(_FAILING_SIZE_LIMITS, encoding="utf-8", newline="\n")
        hist = tmp_path / "docs" / "history.md"
        _seed(hist, 496)
        r = subprocess.run(
            [sys.executable, str(tree / "doc-append.py"), str(hist), "--category", "FEATURE", "--subject", "NEW",
             "--date", "2026-02-01", "--background", "b.", "--changes", "c."],
            capture_output=True, text=True, cwd=hist.parent, timeout=60,
        )
        assert r.returncode == 0, f"the append itself succeeded; rc={r.returncode} stderr: {r.stderr}"
        assert "doc-rotate failed" in r.stderr, f"the rotation failure must be reported: {r.stderr}"
        assert "cannot read the history size limits" in r.stderr, "doc-rotate names the broken SSOT read"
        kept = _headers(hist.read_text(encoding="utf-8"))
        assert kept[-1].startswith("### FEATURE: NEW "), "the appended entry is kept"
        assert len(kept) == ENTRIES + 1, "nothing was moved out"
        assert not (hist.parent / "history").exists(), "a failed rotation writes no archive"

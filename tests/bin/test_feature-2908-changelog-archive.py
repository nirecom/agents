# Tests: bin/doc-rotate.py, hooks/lib/append-only-record-path.js
# Tags: TL2, bin, python, changelog, doc-rotate, migration, append-only, test-lang-exception:symmetry, scope:issue-specific
"""#2890: doc-rotate moves a root CHANGELOG's retired changelog/ archive dir into docs/changelog/.

Rename keeps bytes, a name present on both sides is merged (old file first, then the new file's
entries the old one lacks), the move runs below the rotation threshold, a non-.md leftover keeps
the old dir with a stderr warning, and the ## Archived links (only inside that block) follow.
The symmetry case feeds the archive paths rotation writes to the JS predicate the checks share.
TL3 gap (what this test does NOT catch):
- the API path (compose-doc-append-entry) that rotates without doc-rotate.py; a follow-up issue owns it.
Closest-to-action mitigation: doc-append runs doc-rotate.py on every local append, so the move happens there.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import harness  # noqa: E402,F401

REPO_ROOT = Path(__file__).resolve().parents[2]
DOC_ROTATE = REPO_ROOT / "bin" / "doc-rotate.py"
PREDICATE = REPO_ROOT / "hooks" / "lib" / "append-only-record-path.js"
HIGH = ["--threshold-warn", "100000"]  # below every threshold: rotation itself never runs

PREAMBLE = "# Changelog\n\nOlder notes: see [notes](changelog/2025-notes.md) and changelog/ itself.\n\n"
ARCHIVED = "## Archived\n- [2026](changelog/2026.md) — 2 entries\n- [legacy](changelog/legacy.md) — 1 entries\n"
KEPT = "\n### FEATURE: Kept (2026-05-01, k001)\nBackground: the changelog/2026.md file moved.\nChanges: y\n"
CHANGELOG = PREAMBLE + ARCHIVED + KEPT


def entry(subject: str, date: str | None) -> str:
    head = f"### FEATURE: {subject} ({date}, {subject.lower()}1)" if date else f"### FEATURE: {subject}"
    return f"{head}\nBackground: x\nChanges: y\n"


def year_file(*subjects: str) -> str:
    return "# Changelog 2026\n\n" + "\n".join(entry(s, f"2026-01-0{i + 1}") for i, s in enumerate(subjects))


def legacy_file(*subjects: str) -> str:
    return "# Changelog (legacy — pre-dating convention)\n\n" + "\n".join(entry(s, None) for s in subjects)


def write(path: Path, data: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


def fixture(root: Path, old: dict, new: dict | None = None) -> Path:
    write(root / "CHANGELOG.md", CHANGELOG)
    for name, data in old.items():
        write(root / "changelog" / name, data)
    for name, data in (new or {}).items():
        write(root / "docs" / "changelog" / name, data)
    return root / "CHANGELOG.md"


def rotate(path: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(DOC_ROTATE), str(path), *args],
        capture_output=True, text=True, timeout=120,
    )


def tree(root: Path) -> dict[str, tuple[bytes, int]]:
    return {p.relative_to(root).as_posix(): (p.read_bytes(), p.stat().st_mtime_ns) for p in root.rglob("*") if p.is_file()}


def subjects(text: str) -> list[str]:
    return re.findall(r"^### FEATURE: (\w+)", text.replace("\r\n", "\n"), re.M)


@pytest.mark.target("bin/doc-rotate.py")
def test_rename_keeps_bytes_for_year_and_legacy_files(tmp_path):
    year = b"\xef\xbb\xbf" + year_file("A", "B").replace("\n", "\r\n").encode("utf-8")
    legacy = legacy_file("L").encode("utf-8")
    path = fixture(tmp_path, {"2026.md": year, "legacy.md": legacy})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    assert (tmp_path / "docs" / "changelog" / "2026.md").read_bytes() == year
    assert (tmp_path / "docs" / "changelog" / "legacy.md").read_bytes() == legacy
    assert not (tmp_path / "changelog").exists(), "the emptied old dir was kept"


@pytest.mark.target("bin/doc-rotate.py")
@pytest.mark.parametrize("name, old_text, new_text", [
    ("2026.md", year_file("A", "B"), year_file("B", "C")),
    ("legacy.md", legacy_file("L1", "L2"), legacy_file("L2", "L3")),
])
def test_merge_puts_old_entries_first_then_new_only_entries(tmp_path, name, old_text, new_text):
    path = fixture(tmp_path, {name: old_text}, {name: new_text})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    merged = (tmp_path / "docs" / "changelog" / name).read_text(encoding="utf-8")
    want = subjects(old_text) + [s for s in subjects(new_text) if s not in subjects(old_text)]
    assert subjects(merged) == want
    assert not (tmp_path / "changelog").exists()


@pytest.mark.target("bin/doc-rotate.py")
def test_merge_with_bom_crlf_old_file_follows_the_lf_new_file(tmp_path):
    """Reverse of the CRLF/BOM case below: the old file carries BOM + CRLF, the new one neither."""
    old = b"\xef\xbb\xbf" + year_file("A", "B").replace("\n", "\r\n").encode("utf-8")
    path = fixture(tmp_path, {"2026.md": old}, {"2026.md": year_file("B", "C")})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    merged = (tmp_path / "docs" / "changelog" / "2026.md").read_bytes()
    assert subjects(merged.decode("utf-8-sig")) == ["A", "B", "C"], "an entry differing only in EOL/BOM was duplicated"
    assert not merged.startswith(b"\xef\xbb\xbf") and b"\r\n" not in merged, "the merged file does not follow the new file's EOL/BOM"


@pytest.mark.target("bin/doc-rotate.py")
def test_merge_with_identical_entries_adds_nothing_and_keeps_new_bom_crlf(tmp_path):
    """Every new-side entry already exists in the old file: nothing is appended, the new file's BOM/CRLF stay."""
    new = b"\xef\xbb\xbf" + year_file("A", "B").replace("\n", "\r\n").encode("utf-8")
    path = fixture(tmp_path, {"2026.md": year_file("A", "B")}, {"2026.md": new})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    merged = (tmp_path / "docs" / "changelog" / "2026.md").read_bytes()
    assert subjects(merged.decode("utf-8-sig")) == ["A", "B"], "an identical entry was duplicated"
    assert merged.startswith(b"\xef\xbb\xbf") and b"\r\n" in merged, "the merged file does not keep the new file's EOL/BOM"
    assert not (tmp_path / "changelog").exists(), "the emptied old dir was kept"


@pytest.mark.target("bin/doc-rotate.py")
def test_merge_matches_entries_across_crlf_and_bom(tmp_path):
    new = b"\xef\xbb\xbf" + year_file("B", "C").replace("\n", "\r\n").encode("utf-8")
    path = fixture(tmp_path, {"2026.md": year_file("A", "B")}, {"2026.md": new})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    merged = (tmp_path / "docs" / "changelog" / "2026.md").read_bytes()
    assert subjects(merged.decode("utf-8-sig")) == ["A", "B", "C"], "an entry differing only in EOL/BOM was duplicated"
    assert merged.startswith(b"\xef\xbb\xbf") and b"\r\n" in merged, "the merged file does not follow the new file's EOL/BOM"


@pytest.mark.target("bin/doc-rotate.py")
def test_merge_keeps_both_bodies_when_same_header_has_different_bodies(tmp_path):
    """_entry_key = header sans trailing (...) + body: a differing body is a different entry."""
    head = "### FEATURE: A (2026-01-01, a1)\n"
    old = "# Changelog 2026\n\n" + head + "Background: x\nChanges: OLDBODY\n"
    new = "# Changelog 2026\n\n" + head + "Background: x\nChanges: NEWBODY\n"
    path = fixture(tmp_path, {"2026.md": old}, {"2026.md": new})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    merged = (tmp_path / "docs" / "changelog" / "2026.md").read_text(encoding="utf-8")
    assert "OLDBODY" in merged and "NEWBODY" in merged, "an entry with a differing body was dropped"
    assert subjects(merged) == ["A", "A"]


@pytest.mark.target("bin/doc-rotate.py")
def test_merge_dedupes_same_body_when_headers_differ_only_by_date_suffix(tmp_path):
    """The trailing (date, id) is left out of the key: the same entry with another date merges into one."""
    body = "Background: x\nChanges: SAME\n"
    old = "# Changelog 2026\n\n### FEATURE: A (2026-01-01, a1)\n" + body
    new = "# Changelog 2026\n\n### FEATURE: A (2026-03-09, a9)\n" + body
    path = fixture(tmp_path, {"2026.md": old}, {"2026.md": new})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    merged = (tmp_path / "docs" / "changelog" / "2026.md").read_text(encoding="utf-8")
    assert subjects(merged) == ["A"], "entries differing only by the date suffix were not merged"
    assert "2026-01-01" in merged and "2026-03-09" not in merged, "the old side's header must win"


@pytest.mark.target("bin/doc-rotate.py")
def test_move_runs_below_the_rotation_threshold(tmp_path):
    path = fixture(tmp_path, {"2026.md": year_file("A")})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    assert (tmp_path / "docs" / "changelog" / "2026.md").is_file()
    assert subjects(path.read_text(encoding="utf-8")) == ["Kept"], "the body was rotated below the threshold"


@pytest.mark.target("bin/doc-rotate.py")
def test_non_md_leftovers_keep_the_old_dir_and_warn(tmp_path):
    path = fixture(tmp_path, {"2026.md": year_file("A"), "legacy.md": legacy_file("L"), "notes.txt": "keep\n"})
    write(tmp_path / "changelog" / "sub" / "x.md", "nested\n")
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    old = tmp_path / "changelog"
    assert old.is_dir() and (old / "notes.txt").is_file() and (old / "sub" / "x.md").is_file()
    assert sorted(p.name for p in old.glob("*.md")) == [], "a top-level .md stayed in the old dir"
    assert (tmp_path / "docs" / "changelog" / "2026.md").is_file() and (tmp_path / "docs" / "changelog" / "legacy.md").is_file()
    assert str(old) in r.stderr or old.as_posix() in r.stderr, f"the warning does not name the kept old dir {old}: {r.stderr!r}"

@pytest.mark.target("bin/doc-rotate.py")
def test_archived_links_are_rewritten_inside_the_block_only(tmp_path):
    path = fixture(tmp_path, {"2026.md": year_file("A", "B"), "legacy.md": legacy_file("L")})
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    want = PREAMBLE + ARCHIVED.replace("](changelog/", "](docs/changelog/") + KEPT
    assert path.read_text(encoding="utf-8") == want


@pytest.mark.target("bin/doc-rotate.py")
def test_archived_links_resolve_after_the_move(tmp_path):
    path = fixture(tmp_path, {"2026.md": year_file("A", "B"), "legacy.md": legacy_file("L")})
    assert rotate(path, *HIGH).returncode == 0
    block = path.read_text(encoding="utf-8").split("## Archived", 1)[1].split("\n### ", 1)[0]
    links = re.findall(r"\]\(([^)]+)\)", block)
    assert sorted(links) == ["docs/changelog/2026.md", "docs/changelog/legacy.md"], links
    for link in links:
        assert (path.parent / link).is_file(), f"{link} does not resolve from {path.parent}"


@pytest.mark.target("bin/doc-rotate.py")
def test_migration_and_rotation_in_one_run(tmp_path):
    """Old dir moved and an over-threshold body rotated together: one ## Archived, every link resolves."""
    path = tmp_path / "CHANGELOG.md"
    body = "\n".join(entry(f"C{i}", f"2026-02-0{i}") for i in range(1, 4))
    write(path, "# Changelog\n\n## Archived\n- [2026](changelog/2026.md) — 2 entries\n\n" + body)
    write(tmp_path / "changelog" / "2026.md", year_file("A", "B"))
    r = rotate(path, "--floor", "1")
    assert r.returncode == 0, r.stderr
    archive = tmp_path / "docs" / "changelog" / "2026.md"
    assert subjects(archive.read_text(encoding="utf-8")) == ["A", "B", "C1", "C2"]
    text = path.read_text(encoding="utf-8")
    assert subjects(text) == ["C3"], "the newest entry did not stay in the body"
    assert len(re.findall(r"^## Archived\s*$", text, re.M)) == 1, text
    links = re.findall(r"\]\(([^)]+)\)", text.split("## Archived", 1)[1].split("\n### ", 1)[0])
    assert links and all(link.startswith("docs/changelog/") for link in links), links
    for link in links:
        assert (tmp_path / link).is_file(), f"{link} does not resolve"
    assert not (tmp_path / "changelog").exists(), "the emptied old dir was kept"


@pytest.mark.target("bin/doc-rotate.py")
def test_second_run_writes_nothing(tmp_path):
    path = fixture(tmp_path, {"2026.md": year_file("A", "B")}, {"legacy.md": legacy_file("L")})
    assert rotate(path, *HIGH).returncode == 0
    for p in tmp_path.rglob("*"):
        if p.is_file():
            os.utime(p, ns=(1_000_000_000, 1_000_000_000))
    before = tree(tmp_path)
    r = rotate(path, *HIGH)
    assert r.returncode == 0, r.stderr
    assert tree(tmp_path) == before


@pytest.mark.target("bin/doc-rotate.py")
def test_dry_run_writes_nothing(tmp_path):
    path = fixture(tmp_path, {"2026.md": year_file("A", "B"), "legacy.md": legacy_file("L")}, {"2026.md": year_file("C")})
    before = tree(tmp_path)
    r = rotate(path, "--dry-run")
    assert r.returncode == 0, r.stderr
    assert tree(tmp_path) == before
    assert sorted(p.relative_to(tmp_path).as_posix() for p in tmp_path.rglob("*")) == sorted(
        ["CHANGELOG.md", "changelog", "changelog/2026.md", "changelog/legacy.md", "docs", "docs/changelog", "docs/changelog/2026.md"]
    )
    old, new = tmp_path / "changelog", tmp_path / "docs" / "changelog"
    lines = r.stdout.splitlines()
    for want in (
        f"Would merge {old / '2026.md'} into {new / '2026.md'}",
        f"Would move {old / 'legacy.md'} into {new / 'legacy.md'}",
        f"Would rewrite the ## Archived links of {path} to docs/changelog/",
    ):
        assert want in lines, f"dry-run did not announce {want!r}: stdout={r.stdout!r} stderr={r.stderr!r}"


@pytest.mark.target("bin/doc-rotate.py")
def test_docs_changelog_and_history_never_move_anything(tmp_path):
    """Control: the move is only for a CHANGELOG whose old dir differs from docs/changelog/."""
    docs_cl = tmp_path / "a" / "docs" / "CHANGELOG.md"
    write(docs_cl, CHANGELOG)
    write(tmp_path / "a" / "docs" / "changelog" / "2026.md", year_file("A"))
    hist = tmp_path / "b" / "history.md"
    write(hist, "# History\n\n" + entry("H", "2026-01-01"))
    write(tmp_path / "b" / "changelog" / "2026.md", year_file("Z"))
    before = tree(tmp_path)
    for p in (docs_cl, hist):
        r = rotate(p, *HIGH)
        assert r.returncode == 0 and r.stderr == "", f"{p}: {r.stderr}"
    assert tree(tmp_path) == before


@pytest.mark.target("hooks/lib/append-only-record-path.js")
@pytest.mark.parametrize("rel", ["CHANGELOG.md", "docs/CHANGELOG.md"])
def test_rotation_archive_paths_are_append_only_records(tmp_path, rel):
    """Symmetry: the Python writer's archive paths are what the JS predicate calls records."""
    path = tmp_path / rel
    write(path, "# Changelog\n\n" + entry("U", None) + "\n" + "\n".join(entry(f"C{i}", f"2026-02-0{i}") for i in range(1, 4)))
    r = rotate(path, "--floor", "1")
    assert r.returncode == 0, r.stderr
    written = sorted(p.relative_to(tmp_path).as_posix() for p in tmp_path.rglob("*.md") if p != path)
    assert written == ["docs/changelog/2026.md", "docs/changelog/legacy.md"], written
    script = "const f=require(process.argv[1]).isAppendOnlyRecordPath;console.log(JSON.stringify(process.argv.slice(2).map(f)))"
    done = subprocess.run(["node", "-e", script, str(PREDICATE), *written, rel], capture_output=True, text=True, timeout=60)
    assert done.returncode == 0, done.stderr
    assert json.loads(done.stdout) == [True, True, rel == "CHANGELOG.md"]

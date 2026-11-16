"""Where bin/doc-rotate.py archives a document, and the move of a retired changelog/ archive dir.

A CHANGELOG archives to docs/changelog/ (#2908): <parent>/changelog when the file already sits
in a docs/ dir, <parent>/docs/changelog otherwise. Every other document keeps <parent>/<stem>.
A root CHANGELOG whose old <parent>/changelog/ still exists has every top-level .md moved
(renamed byte for byte, or merged into a same-named file) and its ## Archived links rewritten.
"""

import os
import re
import sys
from collections.abc import Callable
from pathlib import Path

BOM = b"\xef\xbb\xbf"
ARCHIVED_BLOCK_RE = re.compile(rb"^## Archived.*?(?=^##|\Z)", re.M | re.S)
TRAILING_PAREN_RE = re.compile(r"\s*\([^()]*\)\s*$")


def archive_dir_for(path: Path) -> Path:
    if path.stem.lower() != "changelog":
        return path.parent / path.stem.lower()
    if path.absolute().parent.name == "docs":
        return path.parent / "changelog"
    return path.parent / "docs" / "changelog"


def link_prefix(path: Path) -> str:
    """The archive dir as a posix path relative to the document's own dir."""
    return Path(os.path.relpath(archive_dir_for(path), path.parent)).as_posix()


def _normalized(data: bytes) -> str:
    return data.removeprefix(BOM).decode("utf-8").replace("\r\n", "\n")


def _entry_key(entry: dict) -> str:
    # The trailing "(date, id)" is left out: the same entry may carry another date on each side.
    body = "\n".join(entry["body_lines"]).strip("\n")
    return TRAILING_PAREN_RE.sub("", entry["header"]) + "\n" + body


def _entry_out(entry: dict) -> str:
    return "\n".join([entry["header"], *entry["body_lines"]]).rstrip("\n")


def merged_bytes(old: bytes, new: bytes, parse_entries: Callable) -> bytes:
    """The old file, then the new file's entries the old one lacks, in the new file's EOL/BOM."""
    old_text = _normalized(old)
    have = {_entry_key(e) for e in parse_entries(old_text)[0]}
    extra = [e for e in parse_entries(_normalized(new))[0] if _entry_key(e) not in have]
    text = old_text
    if extra:
        text = old_text.rstrip("\n") + "\n\n" + "\n\n".join(_entry_out(e) for e in extra) + "\n"
    if b"\r\n" in new:
        text = text.replace("\n", "\r\n")
    return (BOM if new.startswith(BOM) else b"") + text.encode("utf-8")


def _rewrite_archived_links(path: Path, dry_run: bool) -> None:
    data = path.read_bytes()
    target = b"](" + link_prefix(path).encode("utf-8") + b"/"
    out = ARCHIVED_BLOCK_RE.sub(lambda m: m.group(0).replace(b"](changelog/", target), data, count=1)
    if out == data:
        return
    if dry_run:
        print(f"Would rewrite the ## Archived links of {path} to {link_prefix(path)}/")
    else:
        path.write_bytes(out)


def migrate(path: Path, dry_run: bool, parse_entries: Callable) -> None:
    """Move <parent>/changelog/*.md of a CHANGELOG into its archive dir; idempotent."""
    old = path.parent / "changelog"
    new = archive_dir_for(path)
    if path.stem.lower() != "changelog" or old == new or not old.is_dir():
        return
    moves = sorted(p for p in old.iterdir() if p.is_file() and p.suffix.lower() == ".md")
    if dry_run:
        for src in moves:
            print(f"Would {'merge' if (new / src.name).exists() else 'move'} {src} into {new / src.name}")
        _rewrite_archived_links(path, dry_run)
        return
    new.mkdir(parents=True, exist_ok=True)
    for src in moves:
        dst = new / src.name
        if dst.exists():
            dst.write_bytes(merged_bytes(src.read_bytes(), dst.read_bytes(), parse_entries))
            src.unlink()
        else:
            src.replace(dst)
    _rewrite_archived_links(path, dry_run)
    if any(old.iterdir()):
        print(f"Warning: {old.absolute()} still holds non-.md entries; move them by hand", file=sys.stderr)
    else:
        old.rmdir()

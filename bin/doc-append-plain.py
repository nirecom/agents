#!/usr/bin/env python3
"""Append a plain text line to a document file.

Usage:
    doc-append-plain "line text"          # append to default docs/todo.md
    doc-append-plain /path/to/file.md "line text"

Default path resolution:
    1. $CLAUDE_PROJECT_DIR/docs/todo.md (if CLAUDE_PROJECT_DIR is set)
    2. <git-repo-root>/docs/todo.md (git rev-parse --show-toplevel from CWD)
    Exit 2 if neither resolves.

Newline handling:
    - If the file exists and does not end with a newline, a newline is written
      first (to avoid `existingcontentNEWLINE` concatenation on the same line).
    - The appended text always ends with a newline.
    - CRLF is preserved if the existing file uses CRLF.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path


def _detect_crlf(data: bytes) -> bool:
    return b"\r\n" in data[-min(len(data), 512):]


def _resolve_default_path():
    cpd = os.environ.get("CLAUDE_PROJECT_DIR")
    if cpd:
        p = Path(cpd)
        if p.is_dir():
            return p / "docs" / "todo.md"
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if r.returncode == 0 and r.stdout.strip():
            return Path(r.stdout.strip()) / "docs" / "todo.md"
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Append a plain text line to a doc file.",
        usage="doc-append-plain [path] text",
    )
    parser.add_argument("args", nargs="+", metavar="ARG",
                        help="[path] text — one arg = text (default path); two args = path text")
    ns = parser.parse_args()

    if len(ns.args) == 1:
        text = ns.args[0]
        target = _resolve_default_path()
        if target is None:
            print("Error: cannot resolve default path; set CLAUDE_PROJECT_DIR or run inside a git repo", file=sys.stderr)
            return 2
    elif len(ns.args) == 2:
        target = Path(ns.args[0])
        text = ns.args[1]
        if not target.is_absolute():
            target = Path.cwd() / target
    else:
        print(f"Error: expected 1 or 2 arguments, got {len(ns.args)}", file=sys.stderr)
        parser.print_usage(sys.stderr)
        return 2

    target.parent.mkdir(parents=True, exist_ok=True)

    if target.exists() and target.stat().st_size > 0:
        existing = target.read_bytes()
        crlf = _detect_crlf(existing)
        eol = b"\r\n" if crlf else b"\n"
        needs_leading_newline = not (existing.endswith(b"\n") or existing.endswith(b"\r\n"))
    else:
        eol = b"\n"
        needs_leading_newline = False

    payload = text.encode("utf-8")
    with open(target, "ab") as f:
        if needs_leading_newline:
            f.write(eol)
        f.write(payload)
        if not (payload.endswith(b"\n") or payload.endswith(b"\r\n")):
            f.write(eol)
    return 0


if __name__ == "__main__":
    sys.exit(main())

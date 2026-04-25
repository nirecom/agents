#!/usr/bin/env python3
"""Append a new entry to a stream document (append-only markdown log).

Uses tail-seek to check invariants, then appends via open('ab').

Usage:
    doc-append [path] --category FEATURE --subject S --date YYYY-MM-DD --commits C
        --background TEXT --changes TEXT
    doc-append [path] --category INCIDENT --subject S --date YYYY-MM-DD --commits C
        --cause TEXT --fix TEXT

Categories: INCIDENT, BUGFIX, FEATURE, REFACTOR, CONFIG, SECURITY
If [path] is omitted, defaults to docs/history.md relative to CWD.
"""

import argparse
import re
import subprocess
import sys
from datetime import date as Date
from pathlib import Path

DATE_RE = re.compile(r"\((\d{4}-\d{2}-\d{2}),")
INCIDENT_RE = re.compile(r"^### (?:INCIDENT: )?#(\d+):", re.MULTILINE)
ENTRY_RE = re.compile(r"^### ", re.MULTILINE)

TAIL_SIZES = [4096, 16384]
WARN_LINES = 500


def _detect_line_ending(data: bytes) -> bytes:
    """Return b'\r\n' if CRLF detected, else b'\n'."""
    if b"\r\n" in data[-min(len(data), 512):][:512]:
        return b"\r\n"
    return b"\n"


def _detect_bom(data: bytes) -> bool:
    return data[:3] == b"\xef\xbb\xbf"


def _read_tail(path: Path, size: int) -> bytes:
    with open(path, "rb") as f:
        f.seek(0, 2)
        file_size = f.tell()
        if file_size == 0:
            return b""
        seek_pos = max(0, file_size - size)
        f.seek(seek_pos)
        return f.read()


def _find_last_date_in_tail(tail_text: str) -> Date | None:
    """Return the date from the last ### header found in tail_text."""
    matches = list(DATE_RE.finditer(tail_text))
    if not matches:
        return None
    last = matches[-1]
    try:
        return Date.fromisoformat(last.group(1))
    except ValueError:
        return None


def _find_last_incident_in_text(text: str) -> int | None:
    matches = list(INCIDENT_RE.finditer(text))
    if not matches:
        return None
    return max(int(m.group(1)) for m in matches)


def _count_lines(path: Path) -> int:
    with open(path, "rb") as f:
        return f.read().count(b"\n")


def _build_entry(args, incident_num: int | None, eol: bytes) -> bytes:
    e = eol.decode()
    if args.category == "INCIDENT":
        header = f"### INCIDENT: #{incident_num}: {args.subject} ({args.date}, {args.commits})"
        body = f"Cause: {args.cause}{e}Fix: {args.fix}"
    else:
        header = f"### {args.category}: {args.subject} ({args.date}, {args.commits})"
        body = f"Background: {args.background}{e}Changes: {args.changes}"
    return (f"{header}{e}{body}{e}").encode("utf-8").replace(b"\n", eol)


def main():
    parser = argparse.ArgumentParser(description="Append entry to history.md")
    parser.add_argument("path", help="Path to history.md")
    parser.add_argument("--subject", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--commits", required=True)
    parser.add_argument(
        "--category",
        required=True,
        choices=["INCIDENT", "BUGFIX", "FEATURE", "REFACTOR", "CONFIG", "SECURITY"],
    )
    parser.add_argument("--background")
    parser.add_argument("--changes")
    parser.add_argument("--cause")
    parser.add_argument("--fix")
    args = parser.parse_args()

    # Validate date
    try:
        new_date = Date.fromisoformat(args.date)
    except ValueError:
        print(f"Error: invalid date '{args.date}'", file=sys.stderr)
        sys.exit(1)

    # Validate required fields
    if args.category == "INCIDENT":
        if not args.cause or not args.fix:
            print("Error: INCIDENT requires --cause and --fix", file=sys.stderr)
            sys.exit(1)
    else:
        if not args.background or not args.changes:
            print("Error: requires --background and --changes", file=sys.stderr)
            sys.exit(1)

    path = Path(args.path)
    if not path.parent.exists():
        print(f"Error: parent directory does not exist: {path.parent}", file=sys.stderr)
        sys.exit(1)

    # Handle empty / new file
    if not path.exists() or path.stat().st_size == 0:
        eol = b"\n"
        bom = False
        last_date = None
        last_incident = None
    else:
        # Read tail to check invariants
        tail_bytes = None
        has_entry = False
        for size in TAIL_SIZES:
            tail_bytes = _read_tail(path, size)
            tail_text = tail_bytes.decode("utf-8", errors="replace")
            if ENTRY_RE.search(tail_text):
                has_entry = True
                break

        if not has_entry:
            # Full-file fallback
            tail_bytes = path.read_bytes()
            tail_text = tail_bytes.decode("utf-8", errors="replace")
            print("Warning: no ### header in tail, using full-file scan", file=sys.stderr)

        eol = _detect_line_ending(path.read_bytes())
        bom = _detect_bom(path.read_bytes())
        last_date = _find_last_date_in_tail(tail_text)

        # Incident numbering
        if args.category == "INCIDENT":
            last_incident = _find_last_incident_in_text(tail_text)
            if last_incident is None and has_entry:
                full_text = path.read_bytes().decode("utf-8", errors="replace")
                last_incident = _find_last_incident_in_text(full_text)
            if last_incident is None:
                print("Warning: no prior incident entries found, starting at #1", file=sys.stderr)
        else:
            last_incident = None

    # Ascending date check
    if last_date is not None and new_date < last_date:
        print(
            f"Error: new date {new_date} is before last entry date {last_date}",
            file=sys.stderr,
        )
        sys.exit(1)

    if args.category == "INCIDENT":
        incident_num = (last_incident + 1) if last_incident is not None else 1
    else:
        incident_num = None
    entry_bytes = _build_entry(args, incident_num, eol)

    # Normalize trailing newlines and append entry
    # Target: exactly one blank line (2 newlines) before new entry
    file_size = path.stat().st_size if path.exists() else 0
    with open(path, "r+b" if file_size > 0 else "ab") as f:
        if file_size > 0:
            # Count trailing newline bytes
            f.seek(0, 2)
            pos = f.tell()
            trailing = 0
            while pos > 0:
                pos -= 1
                f.seek(pos)
                ch = f.read(1)
                if ch in (b"\n", b"\r"):
                    trailing += 1
                else:
                    break
            # Truncate to remove all trailing newlines, then write exactly 2
            f.seek(file_size - trailing)
            f.truncate()
            f.write(eol + eol)
        f.write(entry_bytes)

    # Auto-rotate when file exceeds the warn threshold
    lines = _count_lines(path)
    if lines >= WARN_LINES:
        rotate_script = Path(__file__).parent / "doc-rotate.py"
        print(
            f"Note: {path} is now {lines} lines (>= {WARN_LINES}). "
            "Auto-rotating...",
            file=sys.stderr,
        )
        subprocess.run(
            [
                sys.executable,
                str(rotate_script),
                str(path),
                "--threshold-warn",
                str(WARN_LINES),
                "--floor",
                "20",
            ],
            check=False,
        )


if __name__ == "__main__":
    main()

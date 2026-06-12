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
from datetime import date as Date, timedelta
from pathlib import Path

DATE_RE = re.compile(r"\((\d{4}-\d{2}-\d{2})")
INCIDENT_RE = re.compile(r"^### (?:INCIDENT: )?#(\d+):", re.MULTILINE)
ENTRY_RE = re.compile(r"^### ", re.MULTILINE)

WARN_LINES = 500
DATE_ORDER_TOLERANCE_DAYS = 7


def _detect_line_ending(data: bytes) -> bytes:
    """Return b'\r\n' if CRLF detected, else b'\n'."""
    if b"\r\n" in data[-min(len(data), 512):][:512]:
        return b"\r\n"
    return b"\n"


def _detect_bom(data: bytes) -> bool:
    return data[:3] == b"\xef\xbb\xbf"


def _split_entries(data: bytes) -> list[bytes]:
    """Split file bytes into entry chunks on line-start '### ' boundaries.

    The preamble (content before the first '### ') is returned as the first
    element when non-empty. Each entry chunk starts with b'### '.
    """
    # Match '### ' at start of file or immediately after a newline. Tolerates
    # a leading UTF-8 BOM so callers may pass raw bytes without pre-stripping.
    body_start = 3 if data[:3] == b"\xef\xbb\xbf" else 0
    positions: list[int] = []
    if data[body_start : body_start + 4] == b"### ":
        positions.append(body_start)
    for m in re.finditer(rb"\n### ", data):
        positions.append(m.start() + 1)
    if not positions:
        return [data] if data else []
    result: list[bytes] = []
    if positions[0] > 0:
        result.append(data[: positions[0]])
    for i, start in enumerate(positions):
        end = positions[i + 1] if i + 1 < len(positions) else len(data)
        result.append(data[start:end])
    return result


def _sort_entries(entries: list[bytes], eol: bytes = b"\n") -> list[bytes]:
    """Stable-sort entry chunks by date (ascending).

    Chunks that lack a parseable date inherit the last-known date found by
    scanning backward, so they stay near their original position.
    Preamble chunks (not starting with b'### ') are left in place at index 0.
    """
    if not entries:
        return entries

    start = 0
    result: list[bytes] = []
    if entries and not entries[0].startswith(b"### "):
        result.append(entries[0])
        start = 1

    sortable = entries[start:]
    if len(sortable) <= 1:
        return result + sortable

    # Assign a sort key: date from header, or last-known date (backward search)
    keys: list[Date | None] = [None] * len(sortable)
    last_known: Date | None = None
    for i, chunk in enumerate(sortable):
        header_line = chunk.split(eol)[0].decode("utf-8", errors="replace")
        m = DATE_RE.search(header_line)
        if m:
            try:
                keys[i] = Date.fromisoformat(m.group(1))
                last_known = keys[i]
            except ValueError:
                pass

    # Backward pass: fill None keys with the next-known date (keeps them near
    # their original neighbour)
    fill: Date | None = None
    for i in range(len(keys) - 1, -1, -1):
        if keys[i] is not None:
            fill = keys[i]
        elif fill is not None:
            keys[i] = fill

    # Forward pass: any still-None keys get the last_known date found earlier
    for i, k in enumerate(keys):
        if k is None and last_known is not None:
            keys[i] = last_known

    # Stable sort (Python's sort is stable, so equal-date order preserved)
    indexed = sorted(enumerate(sortable), key=lambda x: (keys[x[0]] or Date.min,))
    return result + [chunk for _, chunk in indexed]


def _join_entries(entries: list[bytes], eol: bytes) -> bytes:
    """Join entry chunks with a blank line between each."""
    sep = eol + eol
    # Strip trailing eol from each chunk before joining so separators are clean
    stripped = [e.rstrip(b"\r\n") for e in entries]
    return sep.join(stripped)


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
    date_field = f"{args.date}, {args.commits}" if args.commits else args.date
    if args.category == "INCIDENT":
        header = f"### INCIDENT: #{incident_num}: {args.subject} ({date_field})"
        body = f"Cause: {args.cause}{e}Fix: {args.fix}"
    else:
        header = f"### {args.category}: {args.subject} ({date_field})"
        body = f"Background: {args.background}{e}Changes: {args.changes}"
        if args.test_gap is not None:
            body += f"{e}Test gap: {args.test_gap}"
    return (f"{header}{e}{body}{e}").encode("utf-8").replace(b"\n", eol)


def main():
    parser = argparse.ArgumentParser(description="Append entry to history.md")
    parser.add_argument("path", help="Path to history.md")
    parser.add_argument("--subject", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--commits", default=None)
    parser.add_argument(
        "--category",
        required=True,
        choices=["INCIDENT", "BUGFIX", "FEATURE", "REFACTOR", "CONFIG", "SECURITY"],
    )
    parser.add_argument("--background")
    parser.add_argument("--changes")
    parser.add_argument("--cause")
    parser.add_argument("--fix")
    parser.add_argument(
        "--test-gap",
        default=None,
        help="Test gap field (required on fix-of-fix BUGFIX; warn if omitted on BUGFIX)",
    )
    parser.add_argument(
        "--no-auto-rotate",
        action="store_true",
        help="Skip automatic rotation after appending",
    )
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

    if args.category == "INCIDENT" and args.test_gap is not None:
        print("Error: --test-gap cannot be combined with --category INCIDENT", file=sys.stderr)
        sys.exit(1)

    if args.category == "BUGFIX" and args.test_gap is None:
        print(
            "WARNING: BUGFIX entry without --test-gap. Required for fix-of-fix entries"
            " (see rules/docs/history.md).\nProceeding without Test gap: field.",
            file=sys.stderr,
        )

    path = Path(args.path)
    if not path.parent.exists():
        print(f"Error: parent directory does not exist: {path.parent}", file=sys.stderr)
        sys.exit(1)

    _needs_rewrite = False
    sorted_entries: list[bytes] = []

    # Handle empty / new file
    if not path.exists() or path.stat().st_size == 0:
        eol = b"\n"
        bom = False
        last_date = None
        last_incident = None
    else:
        raw = path.read_bytes()
        eol = _detect_line_ending(raw)
        bom = _detect_bom(raw)

        # Parse and sort in memory; actual rewrite deferred until after validation
        entries = _split_entries(raw[3:] if bom else raw)
        sorted_entries = _sort_entries(entries, eol)
        _needs_rewrite = sorted_entries != entries

        full_text = (
            (_join_entries(sorted_entries, eol) + eol + eol).decode("utf-8", errors="replace")
            if _needs_rewrite
            else raw.decode("utf-8", errors="replace")
        )

        # Derive last_date from the last entry after sort
        dates_found = list(DATE_RE.finditer(full_text))
        if dates_found:
            try:
                last_date = Date.fromisoformat(dates_found[-1].group(1))
            except ValueError:
                last_date = None
        else:
            last_date = None

        # Incident numbering
        if args.category == "INCIDENT":
            last_incident = _find_last_incident_in_text(full_text)
            if last_incident is None:
                print("Warning: no prior incident entries found, starting at #1", file=sys.stderr)
        else:
            last_incident = None

    # Ascending date check
    if last_date is not None and new_date < last_date - timedelta(days=DATE_ORDER_TOLERANCE_DAYS):
        print(
            f"Error: new date {new_date} is more than {DATE_ORDER_TOLERANCE_DAYS} days before last entry date {last_date}",
            file=sys.stderr,
        )
        sys.exit(1)

    # Apply deferred sort rewrite (validation passed — safe to mutate)
    if _needs_rewrite:
        rewritten = _join_entries(sorted_entries, eol) + eol + eol
        if bom:
            rewritten = b"\xef\xbb\xbf" + rewritten
        path.write_bytes(rewritten)

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
    if not args.no_auto_rotate:
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

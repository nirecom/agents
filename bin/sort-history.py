#!/usr/bin/env python3
"""Sort history.md entries in ascending chronological order within each ## section.

Uses an "anchor block" algorithm:
- Entries with resolvable commit hashes are "anchors" with known dates
- Dateless entries (no hash, empty parens, pending, uncommitted) attach to the
  preceding anchor, forming a block that moves together
- Leading dateless entries (before any anchor) form a floating block placed at the end
- Blocks are sorted by anchor date; intra-block order is preserved

Usage:
    uv run bin/sort-history.py docs/history.md
    uv run bin/sort-history.py docs/history.md --repo /path/to/repo
    uv run bin/sort-history.py docs/history.md --dry-run   # show diff only
"""

import argparse
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HASH_RE = re.compile(r"[0-9a-f]{7,40}")
DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")


def find_repo_root(start_path):
    """Find git repository root from a starting path."""
    try:
        result = subprocess.run(
            ["git", "-C", str(start_path), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def get_commit_date(repo_path, commit_hash):
    """Get the author date of a commit. Returns None if not found."""
    try:
        result = subprocess.run(
            ["git", "-C", repo_path, "log", "-1", "--format=%aI", commit_hash],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return datetime.fromisoformat(result.stdout.strip())
    except (subprocess.TimeoutExpired, FileNotFoundError, ValueError):
        pass
    return None


def resolve_entry_date(title_line, repo_path):
    """Try to resolve a date from a ### title line.

    Priority: commit hash dates (most accurate) > inline YYYY-MM-DD dates.
    Returns a datetime if any source resolves, None otherwise.
    """
    # Try commit hashes first (most accurate)
    if repo_path:
        hashes = HASH_RE.findall(title_line)
        dates = []
        for h in hashes:
            date = get_commit_date(repo_path, h)
            if date:
                dates.append(date)
        if dates:
            return min(dates)

    # Fallback: parse inline YYYY-MM-DD from title
    date_match = DATE_RE.search(title_line)
    if date_match:
        try:
            return datetime.strptime(date_match.group(1), "%Y-%m-%d").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            pass

    return None


def parse_sections(content):
    """Parse content into a list of (header_text, entries) tuples.

    header_text: everything before the first ### in this section (## heading + preamble)
    entries: list of entry strings (each starting with ### and including body lines)
    """
    lines = content.split("\n")
    sections = []
    current_header_lines = []
    current_entries = []
    current_entry_lines = []

    def flush_entry():
        nonlocal current_entry_lines
        if current_entry_lines:
            current_entries.append("\n".join(current_entry_lines))
            current_entry_lines = []

    def flush_section():
        nonlocal current_header_lines, current_entries
        flush_entry()
        if current_header_lines or current_entries:
            sections.append(("\n".join(current_header_lines), current_entries))
            current_header_lines = []
            current_entries = []

    for line in lines:
        if line.startswith("## "):
            flush_section()
            current_header_lines = [line]
        elif line.startswith("### "):
            flush_entry()
            current_entry_lines = [line]
        elif current_entry_lines:
            current_entry_lines.append(line)
        else:
            current_header_lines.append(line)

    flush_section()
    return sections


def build_anchor_blocks(entries, repo_path):
    """Group entries into anchor blocks.

    Returns a list of (anchor_date, block_entries) tuples.
    anchor_date is a datetime for dated blocks, or None for floating blocks.
    """
    blocks = []
    current_anchor_date = None
    current_block = []

    for entry in entries:
        title_line = entry.split("\n", 1)[0]
        date = resolve_entry_date(title_line, repo_path)

        if date is not None:
            # This entry is an anchor — start a new block
            if current_block:
                blocks.append((current_anchor_date, current_block))
            current_anchor_date = date
            current_block = [entry]
        else:
            # Dateless — attach to current block
            current_block.append(entry)

    if current_block:
        blocks.append((current_anchor_date, current_block))

    return blocks


def sort_section_entries(entries, repo_path):
    """Sort entries within a section using anchor blocks."""
    if len(entries) <= 1:
        return entries

    blocks = build_anchor_blocks(entries, repo_path)

    # Separate floating blocks (no anchor date) from dated blocks
    dated_blocks = [(d, i, b) for i, (d, b) in enumerate(blocks) if d is not None]
    floating_blocks = [(i, b) for i, (d, b) in enumerate(blocks) if d is None]

    # Sort dated blocks by anchor date, preserving original order for same date
    dated_blocks.sort(key=lambda x: (x[0], x[1]))

    # Reassemble: dated blocks first (ascending), then floating blocks at end
    result = []
    for _, _, block_entries in dated_blocks:
        result.extend(block_entries)
    for _, block_entries in floating_blocks:
        result.extend(block_entries)

    return result


def sort_history(content, repo_path):
    """Sort ### entries within each ## section by commit date (ascending)."""
    sections = parse_sections(content)
    output_parts = []

    for header_text, entries in sections:
        output_parts.append(header_text)
        if entries:
            sorted_entries = sort_section_entries(entries, repo_path)
            output_parts.append("\n".join(sorted_entries))

    return "\n".join(output_parts)


def main():
    parser = argparse.ArgumentParser(
        description="Sort history.md entries chronologically (ascending) using anchor blocks"
    )
    parser.add_argument("file", help="Path to history.md")
    parser.add_argument(
        "--repo",
        help="Git repository path for commit date lookup (default: auto-detect)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show unified diff instead of writing to stdout",
    )
    args = parser.parse_args()

    file_path = Path(args.file).resolve()
    if not file_path.exists():
        print(f"Error: {file_path} not found", file=sys.stderr)
        sys.exit(1)

    repo_path = args.repo
    if not repo_path:
        repo_path = find_repo_root(file_path.parent)
    if not repo_path:
        print(
            "Warning: no git repository found, cannot resolve commit dates",
            file=sys.stderr,
        )

    content = file_path.read_text(encoding="utf-8").replace("\r\n", "\n")
    result = sort_history(content, repo_path)

    # Use binary stdout to avoid CRLF conversion on Windows
    out = open(sys.stdout.fileno(), "wb", closefd=False)

    if args.dry_run:
        import difflib

        original_lines = content.splitlines(keepends=True)
        result_lines = result.splitlines(keepends=True)
        diff = difflib.unified_diff(
            original_lines,
            result_lines,
            fromfile=str(file_path),
            tofile=str(file_path) + " (sorted)",
        )
        for line in diff:
            out.write(line.encode("utf-8"))
    else:
        out.write(result.encode("utf-8"))


if __name__ == "__main__":
    main()

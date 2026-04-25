#!/usr/bin/env python3
"""Convert history.md table format to section format.

Handles any column structure generically:
- First non-special column = section title
- Column named "Commit" or "Key Commits" = parenthetical after title
- Column named "#" = numbered prefix (### #N: Title)
- All other columns = "ColumnName: value" body lines

Usage:
    python bin/convert-history-table.py > docs/history.md.new
    diff docs/history.md docs/history.md.new
    mv docs/history.md.new docs/history.md
"""

import re
import sys
from pathlib import Path

COMMIT_COLUMNS = {"Commit", "Key Commits", "Commits"}
NUMBER_COLUMN = "#"


def is_table_separator(line):
    """Check if a line is a markdown table separator (|---|---|)."""
    return bool(re.match(r"^\s*\|[\s:|-]+\|\s*$", line))


def is_table_row(line):
    """Check if a line is a markdown table row."""
    stripped = line.strip()
    return stripped.startswith("|") and stripped.endswith("|")


def parse_table(lines):
    """Parse markdown table lines into (headers, rows)."""
    headers = None
    rows = []
    for line in lines:
        stripped = line.strip()
        if not is_table_row(stripped):
            continue
        cells = [c.strip() for c in stripped.split("|")[1:-1]]
        if headers is None:
            headers = cells
            continue
        if is_table_separator(stripped):
            continue
        rows.append(dict(zip(headers, cells)))
    return headers or [], rows


def classify_columns(headers):
    """Classify columns into title, number, commit, and body columns."""
    commit_col = None
    number_col = None
    title_col = None
    body_cols = []

    for h in headers:
        if h in COMMIT_COLUMNS:
            commit_col = h
        elif h == NUMBER_COLUMN:
            number_col = h
        elif title_col is None:
            title_col = h
        else:
            body_cols.append(h)

    return title_col, number_col, commit_col, body_cols


def format_section(row, title_col, number_col, commit_col, body_cols):
    """Format a single table row as a markdown section."""
    title = row.get(title_col, "").strip() if title_col else ""
    commits = row.get(commit_col, "").strip() if commit_col else ""
    number = row.get(number_col, "").strip() if number_col else ""

    # Build heading
    if number:
        heading = f"### #{number}: {title}"
    else:
        heading = f"### {title}"

    if commits:
        heading += f" ({commits})"

    # Build body
    body_lines = []
    for col in body_cols:
        val = row.get(col, "").strip()
        if val:
            body_lines.append(f"{col}: {val}")

    if body_lines:
        return heading + "\n" + "\n".join(body_lines)
    return heading


def convert_content(content):
    """Convert markdown content, replacing tables with section format."""
    lines = content.split("\n")
    output = []
    i = 0

    while i < len(lines):
        line = lines[i]

        # Check if this line starts a table
        if is_table_row(line):
            # Collect all contiguous table lines
            table_lines = []
            while i < len(lines) and (is_table_row(lines[i]) or is_table_separator(lines[i])):
                table_lines.append(lines[i])
                i += 1

            headers, rows = parse_table(table_lines)
            if rows:
                title_col, number_col, commit_col, body_cols = classify_columns(headers)
                sections = []
                for row in rows:
                    sections.append(format_section(row, title_col, number_col, commit_col, body_cols))
                output.append("\n\n".join(sections))
            # else: empty table, just skip it
            continue

        output.append(line)
        i += 1

    return "\n".join(output)


def main():
    history_path = Path(__file__).resolve().parent.parent / "docs" / "history.md"
    if not history_path.exists():
        print(f"Error: {history_path} not found", file=sys.stderr)
        sys.exit(1)

    content = history_path.read_text(encoding="utf-8").replace("\r\n", "\n")
    result = convert_content(content)

    sys.stdout = open(sys.stdout.fileno(), "w", encoding="utf-8", closefd=False)
    sys.stdout.write(result)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Rotate a history.md by archiving old entries to history/YYYY.md files.

Undated entries are treated as oldest and archived to history/legacy.md.
Generates history/index.md with year-grouped list of all entries.

Rotation is triggered when the file exceeds --threshold-warn lines (default 0 = always).
Entries beyond the --floor most recent are archived.

Usage:
    uv run bin/doc-rotate.py <path> [--threshold-warn 500] [--floor 20] [--dry-run]
"""

import argparse
import re
import sys
from pathlib import Path

WARN_LINES = 500
HARD_LINES = 800
DEFAULT_FLOOR = 20

CATEGORIES = ("INCIDENT", "BUGFIX", "FEATURE", "REFACTOR", "CONFIG", "SECURITY")
CATEGORY_PREFIX_RE = re.compile(
    r"^### (?:(" + "|".join(CATEGORIES) + r"): )?(?:#\d+: )?"
)


def _extract_category(header: str) -> str:
    m = CATEGORY_PREFIX_RE.match(header)
    return m.group(1) if m and m.group(1) else ""


def _subject_from_header(header: str) -> str:
    s = CATEGORY_PREFIX_RE.sub("", header)
    if s == header:
        s = re.sub(r"^### ", "", header)
    return re.sub(r"\s*\(.*", "", s).strip()


def _parse_entries(content: str):
    """Parse history.md into (entries, preamble) tuple.

    Each entry dict: {header, body_lines, date (Date|None)}
    preamble: text before first ### entry (e.g. # title, ## section headings)
    """
    entries = []
    lines = content.split("\n")
    current = None
    preamble_lines = []

    for line in lines:
        if line.startswith("## "):
            if current is not None:
                entries.append(current)
                current = None
            preamble_lines.append(line)
        elif line.startswith("### "):
            if current is not None:
                entries.append(current)
            current = {"header": line, "body_lines": [], "date": _parse_date(line)}
        else:
            if current is not None:
                current["body_lines"].append(line)
            else:
                preamble_lines.append(line)

    if current is not None:
        entries.append(current)

    return entries, "\n".join(preamble_lines)


def _parse_date(header_line: str):
    from datetime import date as Date

    m = re.search(r"\((\d{4}-\d{2}-\d{2})", header_line)
    if not m:
        return None
    try:
        return Date.fromisoformat(m.group(1))
    except ValueError:
        return None


def _entry_text(entry: dict) -> str:
    body = "\n".join(entry["body_lines"])
    return f"{entry['header']}\n{body}" if body else entry["header"]


def _make_anchor(header: str) -> str:
    """Generate a GitHub-style markdown anchor from a ### header line."""
    text = re.sub(r"^### #?\d*:?\s*", "", header)
    text = re.sub(r"\s*\(.*?\)", "", text).strip().lower()
    text = re.sub(r"[^a-z0-9\s-]", "", text)
    text = re.sub(r"\s+", "-", text)
    return text


def _first_sentence(body_lines: list[str]) -> str:
    """Extract first sentence from Background/Cause line."""
    for line in body_lines:
        if line.startswith("Background:") or line.startswith("Cause:"):
            text = re.sub(r"^(?:Background|Cause):\s*", "", line)
            m = re.match(r"([^.!?]+[.!?]?)", text)
            if m:
                return m.group(1).strip()[:120]
    return ""


def rotate(
    path: Path,
    floor: int,
    dry_run: bool,
    threshold_warn: int = 0,
    threshold_hard: int = HARD_LINES,
) -> int:
    """Perform rotation. Returns 0 on success."""
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    content = path.read_text(encoding="utf-8")

    # Line-count gate: skip if under threshold-warn
    if threshold_warn > 0:
        line_count = len(content.splitlines())
        if line_count < threshold_warn:
            return 0

    entries, preamble = _parse_entries(content)

    if not entries:
        return 0

    # Order: undated first (treated as oldest), then dated ascending
    undated = [e for e in entries if e["date"] is None]
    dated = sorted(
        [e for e in entries if e["date"] is not None], key=lambda e: e["date"]
    )
    all_ordered = undated + dated  # oldest → newest

    # Floor: keep last `floor` entries, archive the rest
    if floor <= 0:
        to_keep = []
        to_archive = all_ordered
    elif len(all_ordered) <= floor:
        to_keep = all_ordered
        to_archive = []
    else:
        to_keep = all_ordered[-floor:]
        to_archive = all_ordered[:-floor]

    if not to_archive:
        return 0

    archive_dated = [e for e in to_archive if e["date"] is not None]
    archive_undated = [e for e in to_archive if e["date"] is None]

    by_year: dict[int, list] = {}
    for e in archive_dated:
        by_year.setdefault(e["date"].year, []).append(e)

    archive_dir = path.parent / "history"

    if dry_run:
        line_count = len(content.splitlines())
        if threshold_warn > 0:
            print(
                f"Lines: {line_count} (threshold-warn: {threshold_warn}) - rotation triggered"
            )
        print(
            f"Would archive {len(to_archive)} entries "
            f"({len(archive_dated)} dated, {len(archive_undated)} undated) to {archive_dir}/"
        )
        for y, es in sorted(by_year.items()):
            print(f"  {archive_dir}/{y}.md: {len(es)} entries")
        if archive_undated:
            print(f"  {archive_dir}/legacy.md: {len(archive_undated)} entries")
        print(f"Would keep {len(to_keep)} entries in body")
        print(f"Would generate/update {archive_dir}/index.md")
        return 0

    archive_dir.mkdir(exist_ok=True)

    # Archive dated entries by year
    for y, es in sorted(by_year.items()):
        archive_path = archive_dir / f"{y}.md"
        if archive_path.exists():
            existing = archive_path.read_text(encoding="utf-8")
            new_es = [e for e in es if _entry_text(e) not in existing]
            if not new_es:
                continue
            text = (
                existing.rstrip("\n")
                + "\n\n"
                + "\n\n".join(_entry_text(e) for e in new_es)
                + "\n"
            )
        else:
            text = (
                f"# History {y}\n\n"
                + "\n\n".join(_entry_text(e) for e in es)
                + "\n"
            )
        archive_path.write_text(text, encoding="utf-8")

    # Archive undated entries to legacy.md
    if archive_undated:
        legacy_path = archive_dir / "legacy.md"
        if legacy_path.exists():
            existing = legacy_path.read_text(encoding="utf-8")
            new_es = [e for e in archive_undated if _entry_text(e) not in existing]
            if new_es:
                text = (
                    existing.rstrip("\n")
                    + "\n\n"
                    + "\n\n".join(_entry_text(e) for e in new_es)
                    + "\n"
                )
                legacy_path.write_text(text, encoding="utf-8")
        else:
            text = (
                "# History (legacy — pre-dating convention)\n\n"
                + "\n\n".join(_entry_text(e) for e in archive_undated)
                + "\n"
            )
            legacy_path.write_text(text, encoding="utf-8")

    # Build ## Archived section
    archived_lines = ["## Archived"]
    for y in sorted(by_year.keys()):
        archived_lines.append(f"- [{y}](history/{y}.md) — {len(by_year[y])} entries")
    if archive_undated:
        archived_lines.append(
            f"- [legacy](history/legacy.md) — {len(archive_undated)} entries"
        )

    body_parts = []
    if preamble.strip():
        body_parts.append(preamble.strip())
    body_parts.append("\n".join(archived_lines))
    if to_keep:
        body_parts.append("\n".join(_entry_text(e) for e in to_keep))

    new_body = "\n\n".join(p for p in body_parts if p.strip()) + "\n"

    if new_body != content:
        path.write_text(new_body, encoding="utf-8")

    _write_index(archive_dir / "index.md", to_keep + to_archive, by_year, archive_dir)

    return 0


def _write_index(
    index_path: Path,
    entries: list[dict],
    archived_years: dict,
    archive_dir: Path,
):
    """Write history/index.md with year-grouped entry list (newest year first)."""
    by_year: dict[int, list] = {}
    undated = []
    for e in entries:
        if e["date"] is not None:
            by_year.setdefault(e["date"].year, []).append(e)
        else:
            undated.append(e)

    # Include any existing archive files not already in by_year
    for archive_file in sorted(archive_dir.glob("[0-9]*.md")):
        try:
            y = int(archive_file.stem)
        except ValueError:
            continue
        if y in by_year:
            continue
        arch_entries, _ = _parse_entries(archive_file.read_text(encoding="utf-8"))
        for e in arch_entries:
            if e["date"] is not None:
                by_year.setdefault(e["date"].year, []).append(e)

    from collections import Counter

    all_flat = [e for es in by_year.values() for e in es] + undated
    cat_counts = Counter(_extract_category(e["header"]) for e in all_flat)
    cat_counts.pop("", None)

    lines = ["# History Index", ""]

    if cat_counts:
        ordered = ["FEATURE", "BUGFIX", "INCIDENT", "REFACTOR", "CONFIG", "SECURITY"]
        parts = [f"{c}: {cat_counts[c]}" for c in ordered if c in cat_counts]
        extras = sorted(c for c in cat_counts if c not in ordered)
        parts.extend(f"{c}: {cat_counts[c]}" for c in extras)
        lines.append("## Category Distribution")
        lines.append("")
        lines.append(" | ".join(parts))
        lines.append("")

    for y in sorted(by_year.keys(), reverse=True):
        lines.append(f"## {y}")
        year_entries = sorted(by_year[y], key=lambda e: e["date"], reverse=True)
        for e in year_entries:
            anchor = _make_anchor(e["header"])
            link = (
                f"history/{y}.md#{anchor}"
                if y in archived_years
                else f"../history.md#{anchor}"
            )
            cat = _extract_category(e["header"])
            cat_prefix = f"{cat}: " if cat else ""
            subj = _subject_from_header(e["header"])
            date_str = e["date"].isoformat()
            lines.append(f"- {date_str}: {cat_prefix}[{subj}]({link})")
        lines.append("")

    if undated:
        lines.append("## (undated)")
        for e in undated:
            anchor = _make_anchor(e["header"])
            cat = _extract_category(e["header"])
            cat_prefix = f"{cat}: " if cat else ""
            subj = _subject_from_header(e["header"])
            lines.append(f"- {cat_prefix}[{subj}](../history.md#{anchor})")
        lines.append("")

    index_path.write_text("\n".join(lines), encoding="utf-8")


def rebuild_index(history_path: Path) -> int:
    """Rebuild history/index.md from existing archive files without rotating."""
    archive_dir = history_path.parent / "history"
    if not archive_dir.exists():
        print(f"Error: {archive_dir} not found", file=sys.stderr)
        return 1

    current_entries: list[dict] = []
    if history_path.exists():
        current_entries, _ = _parse_entries(
            history_path.read_text(encoding="utf-8")
        )

    archived_years: dict[int, list] = {}
    for arch_file in sorted(archive_dir.glob("[0-9]*.md")):
        try:
            y = int(arch_file.stem)
        except ValueError:
            continue
        arch_entries, _ = _parse_entries(arch_file.read_text(encoding="utf-8"))
        archived_years[y] = [e for e in arch_entries if e["date"] is not None]

    legacy_undated: list[dict] = []
    legacy_path = archive_dir / "legacy.md"
    if legacy_path.exists():
        legacy_entries, _ = _parse_entries(
            legacy_path.read_text(encoding="utf-8")
        )
        legacy_undated = [e for e in legacy_entries if e["date"] is None]

    all_entries = (
        [e for es in archived_years.values() for e in es]
        + legacy_undated
        + current_entries
    )

    _write_index(archive_dir / "index.md", all_entries, archived_years, archive_dir)
    print(f"Rebuilt {archive_dir / 'index.md'}")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Rotate history.md entries to archive files"
    )
    parser.add_argument("path", help="Path to history.md")
    parser.add_argument(
        "--threshold-warn",
        type=int,
        default=0,
        help="Skip rotation if file is under this many lines (0 = always rotate)",
    )
    parser.add_argument(
        "--threshold-hard",
        type=int,
        default=HARD_LINES,
        help="Hard line limit (informational only)",
    )
    parser.add_argument(
        "--floor",
        type=int,
        default=DEFAULT_FLOOR,
        help="Number of most recent entries to keep in body",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--rebuild-index",
        action="store_true",
        help="Rebuild history/index.md from existing archive files (no rotation)",
    )
    args = parser.parse_args()

    if args.rebuild_index:
        sys.exit(rebuild_index(Path(args.path)))

    sys.exit(
        rotate(
            Path(args.path),
            floor=args.floor,
            dry_run=args.dry_run,
            threshold_warn=args.threshold_warn,
            threshold_hard=args.threshold_hard,
        )
    )


if __name__ == "__main__":
    main()

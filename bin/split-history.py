#!/usr/bin/env python3
"""Split docs/history.md and archive files using classification indexes.

Usage:
    uv run bin/split-history.py

Reads:
    docs/history.md                      -- source history file
    docs/history-classification.md       -- classification table (@claude/@dotfiles/@both)
    docs/history/{stem}.md               -- archive files (auto-discovered)
    docs/history-classification-{stem}.md -- classification for each archive

Writes:
    docs/history-agents.md               -- @claude + @both entries (for agents repo)
    docs/history-dotfiles.md             -- @dotfiles + @both entries (for dotfiles repo)
    docs/history/{stem}-agents.md        -- same split for each archive file
    docs/history/{stem}-dotfiles.md

Adding a new archive year (e.g. 2027.md):
    1. Create docs/history/2027.md via doc-rotate
    2. Create docs/history-classification-2027.md with the same table format
    3. Re-run this script -- 2027 is auto-detected

Idempotent: re-running produces identical output (no appending).
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
HISTORY_PATH = REPO_ROOT / "docs" / "history.md"
CLASSIFICATION_PATH = REPO_ROOT / "docs" / "history-classification.md"
OUT_AGENTS = REPO_ROOT / "docs" / "history-agents.md"
OUT_DOTFILES = REPO_ROOT / "docs" / "history-dotfiles.md"
ARCHIVE_DIR = REPO_ROOT / "docs" / "history"

HEADER_RE = re.compile(r"^### ")
# Matches table rows: | N | subject | @tag |
ROW_RE = re.compile(r"^\|\s*\d+\s*\|\s*(.*?)\s*\|\s*(@\w+)\s*\|")
# Strip trailing date/commit suffix like (2026-04-12) or (2026-04-12, abc1234)
DATE_SUFFIX_RE = re.compile(r"\s*\([\d]{4}-[\d]{2}-[\d]{2}[^)]*\)\s*$")


def _normalize(s: str) -> str:
    """Normalize a history subject for fuzzy matching."""
    s = DATE_SUFFIX_RE.sub("", s)
    # Normalize "INCIDENT: #N:" → "INCIDENT #N:" for comparison
    s = re.sub(r"INCIDENT:\s*#(\d+):", r"INCIDENT #\1:", s)
    # Strip backtick code spans (legacy.md uses `cmd` formatting in headers)
    s = s.replace("`", "")
    return s.strip()


def load_classification(path: Path) -> dict[str, str]:
    """Return {subject_digest: tag} from the classification markdown table."""
    tags: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = ROW_RE.match(line)
        if m:
            subject = m.group(1).strip()
            tag = m.group(2).strip()
            tags[subject] = tag
    return tags


def split_entries(history_text: str) -> list[str]:
    """Split history.md into a list of raw entry blocks (including header line)."""
    lines = history_text.splitlines(keepends=True)
    entries: list[str] = []
    current: list[str] = []
    preamble: list[str] = []
    in_entries = False

    for line in lines:
        if HEADER_RE.match(line):
            in_entries = True
            if current:
                entries.append("".join(current))
            current = [line]
        elif not in_entries:
            preamble.append(line)
        else:
            current.append(line)

    if current:
        entries.append("".join(current))

    return preamble, entries


def match_entry(entry: str, tags: dict[str, str]) -> str:
    """Return the tag for this entry by fuzzy-matching the subject digest."""
    header_line = entry.splitlines()[0]
    # Strip leading "### " and trailing whitespace
    header = _normalize(header_line[4:].strip())

    # Exact match (after normalization)
    for subject, tag in tags.items():
        if _normalize(subject) == header:
            return tag

    # Fuzzy: classification key is a substring of the normalized header
    for subject, tag in tags.items():
        key = _normalize(subject)
        if key and (key in header or header.startswith(key[:50])):
            return tag

    return None


def write_output(path: Path, preamble: list[str], entries: list[str], label: str) -> None:
    header = f"# History ({label})\n\n"
    body = "".join(entries)
    path.write_text(header + body, encoding="utf-8", newline="\n")


def get_archive_sources() -> list[tuple[Path, Path, Path, Path, str]]:
    """Discover archive files in docs/history/ and pair with classification files.

    For each docs/history/{stem}.md found (excluding index and split outputs),
    expects docs/history-classification-{stem}.md to exist.
    """
    if not ARCHIVE_DIR.exists():
        return []
    docs_dir = REPO_ROOT / "docs"
    sources = []
    for hist_path in sorted(ARCHIVE_DIR.glob("*.md")):
        stem = hist_path.stem
        if stem == "index" or stem.endswith(("-agents", "-dotfiles")):
            continue
        class_path = docs_dir / f"history-classification-{stem}.md"
        out_agents = ARCHIVE_DIR / f"{stem}-agents.md"
        out_dotfiles = ARCHIVE_DIR / f"{stem}-dotfiles.md"
        sources.append((hist_path, class_path, out_agents, out_dotfiles, stem))
    return sources


def process_pair(
    hist_path: Path, class_path: Path, out_agents: Path, out_dotfiles: Path, label: str
) -> int:
    """Process one history/classification pair. Returns unmatched count, or -1 on error."""
    tags = load_classification(class_path)
    if not tags:
        print(f"ERROR: no classification entries found in {class_path}", file=sys.stderr)
        return -1

    history_text = hist_path.read_text(encoding="utf-8")
    preamble, entries = split_entries(history_text)

    agents_entries: list[str] = []
    dotfiles_entries: list[str] = []
    unmatched: list[str] = []

    for entry in entries:
        tag = match_entry(entry, tags)
        if tag is None:
            unmatched.append(entry.splitlines()[0])
            dotfiles_entries.append(entry)
            continue
        if tag in ("@claude", "@both"):
            agents_entries.append(entry)
        if tag in ("@dotfiles", "@both"):
            dotfiles_entries.append(entry)

    if unmatched:
        print(f"WARNING: unmatched entries in {hist_path.name} (defaulted to @dotfiles):", file=sys.stderr)
        for u in unmatched:
            print(f"  {u}", file=sys.stderr)

    agents_label = "agents" if label == "history" else f"agents/{label}"
    dotfiles_label = "dotfiles" if label == "history" else f"dotfiles/{label}"
    write_output(out_agents, preamble, agents_entries, agents_label)
    write_output(out_dotfiles, preamble, dotfiles_entries, dotfiles_label)

    print(f"{label} agents:   {out_agents} ({len(agents_entries)} entries)")
    print(f"{label} dotfiles: {out_dotfiles} ({len(dotfiles_entries)} entries)")
    return len(unmatched)


def main() -> int:
    sources = [
        (HISTORY_PATH, CLASSIFICATION_PATH, OUT_AGENTS, OUT_DOTFILES, "history"),
    ] + get_archive_sources()

    for hist_path, class_path, *_ in sources:
        if not hist_path.exists():
            print(f"ERROR: {hist_path} not found", file=sys.stderr)
            return 1
        if not class_path.exists():
            print(
                f"ERROR: {class_path} not found -- create a classification file for this archive",
                file=sys.stderr,
            )
            return 1

    total_unmatched = 0
    for hist_path, class_path, out_agents, out_dotfiles, label in sources:
        count = process_pair(hist_path, class_path, out_agents, out_dotfiles, label)
        if count < 0:
            return 1
        total_unmatched += count

    if total_unmatched:
        print(f"WARNING: {total_unmatched} total unmatched entry(s) -- review classification files")

    return 0


if __name__ == "__main__":
    sys.exit(main())

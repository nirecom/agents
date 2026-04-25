#!/usr/bin/env python3
"""Detect and translate Japanese entries in history.md files.

Two-phase workflow:
  1. Extract: detect Japanese entries and save a translation manifest (JSON)
  2. Apply: read completed manifest and replace Japanese with English

The manifest path defaults to <file>.translate.json (alongside the history file).
Override with -t / --translations.

Usage:
    uv run bin/translate-history.py docs/history.md --extract
    uv run bin/translate-history.py docs/history.md --extract --public
    uv run bin/translate-history.py docs/history.md --apply
    uv run bin/translate-history.py docs/history.md --apply -t custom.json
    uv run bin/translate-history.py docs/history.md --apply --dry-run
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# Unicode ranges for Japanese text detection
_JP_RANGES = (
    ("\u3040", "\u309F"),  # Hiragana
    ("\u30A0", "\u30FF"),  # Katakana
    ("\u4E00", "\u9FFF"),  # CJK Unified Ideographs (Kanji)
    ("\u3400", "\u4DBF"),  # CJK Extension A
    ("\uFF00", "\uFFEF"),  # Fullwidth forms
)


def contains_japanese(text):
    """Return True if text contains any Japanese characters."""
    for ch in text:
        for lo, hi in _JP_RANGES:
            if lo <= ch <= hi:
                return True
    return False


def parse_sections(content):
    """Parse content into a list of (header_text, entries) tuples.

    Identical to sort-history.py's parse_sections.
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


def find_japanese_entries(sections):
    """Find all entries containing Japanese text.

    Returns list of dicts with keys: title, original.
    """
    results = []
    for _, entries in sections:
        for entry in entries:
            if contains_japanese(entry):
                title = entry.split("\n", 1)[0]
                results.append({"title": title, "original": entry})
    return results


def extract_manifest(file_path, entries):
    """Generate a JSON manifest for translation."""
    manifest = []
    for e in entries:
        manifest.append({
            "title": e["title"],
            "original": e["original"],
            "translated": "",
        })
    return json.dumps(manifest, ensure_ascii=False, indent=2)


def apply_translations(content, translations):
    """Replace Japanese entries with their English translations.

    Matches by exact original text. Warns on stderr if original not found.
    """
    for t in translations:
        original = t.get("original", "")
        translated = t.get("translated", "")
        if not original or not translated:
            continue
        if original in content:
            content = content.replace(original, translated, 1)
        else:
            title = t.get("title", "(unknown)")
            print(f"Warning: original not found, skipping: {title}", file=sys.stderr)
    return content


def extract_host(remote_url):
    """Extract hostname from git remote URL."""
    # ssh://user@host:port/path or https://host/path
    m = re.match(r"^(?:ssh|https?)://(?:[^@]+@)?([^/:]+)", remote_url)
    if m:
        return m.group(1)
    # git@host:path (SCP-style)
    m = re.match(r"^[^@]+@([^:]+):", remote_url)
    if m:
        return m.group(1)
    return None


def extract_repo_id(remote_url):
    """Extract owner/repo from git remote URL."""
    m = re.search(r"[/:]([^/]+/[^/]+?)(?:\.git)?$", remote_url)
    return m.group(1) if m else None


def is_public_repo(repo_dir):
    """Check if a git repository is public.

    Returns True if public, False if private or on any error (fail-open → private).
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_dir), "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return False
        remote_url = result.stdout.strip()
        if not remote_url:
            return False

        host = extract_host(remote_url)
        # Non-GitHub hosts → treat as private
        if host and host != "github.com":
            return False

        repo_id = extract_repo_id(remote_url)
        if not repo_id:
            return False

        result = subprocess.run(
            ["gh", "api", f"repos/{repo_id}", "--jq", ".private"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return False
        return result.stdout.strip() == "false"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


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


def main():
    parser = argparse.ArgumentParser(
        description="Detect and translate Japanese entries in history.md"
    )
    parser.add_argument("file", help="Path to history.md")
    parser.add_argument(
        "--extract", action="store_true",
        help="Output translation manifest for Japanese entries",
    )
    parser.add_argument(
        "--apply", action="store_true",
        help="Apply translations from manifest",
    )
    parser.add_argument(
        "-t", "--translations",
        help="Path to completed manifest (for --apply)",
    )
    parser.add_argument(
        "--public", action="store_true",
        help="Force treat repo as public (requires English)",
    )
    parser.add_argument(
        "--private", action="store_true",
        help="Force treat repo as private (Japanese OK)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show unified diff instead of writing output",
    )
    args = parser.parse_args()

    if not args.extract and not args.apply:
        parser.error("one of --extract or --apply is required")

    file_path = Path(args.file).resolve()
    if not file_path.exists():
        print(f"Error: {file_path} not found", file=sys.stderr)
        sys.exit(1)

    # Repo visibility check
    if args.private:
        print("Private repo: Japanese is acceptable, skipping.", file=sys.stderr)
        sys.exit(0)

    if not args.public:
        repo_root = find_repo_root(file_path.parent)
        if repo_root and not is_public_repo(repo_root):
            print("Private repo: Japanese is acceptable, skipping.", file=sys.stderr)
            sys.exit(0)

    content = file_path.read_text(encoding="utf-8").replace("\r\n", "\n")
    out = open(sys.stdout.fileno(), "wb", closefd=False)

    default_manifest = file_path.with_suffix(".translate.json")

    if args.extract:
        sections = parse_sections(content)
        jp_entries = find_japanese_entries(sections)
        if not jp_entries:
            print("No Japanese entries found.", file=sys.stderr)
            sys.exit(0)
        manifest = extract_manifest(file_path, jp_entries)
        manifest_path = Path(args.translations).resolve() if args.translations else default_manifest
        manifest_path.write_text(manifest + "\n", encoding="utf-8")
        print(f"Manifest written to: {manifest_path} ({len(jp_entries)} entries)", file=sys.stderr)

    elif args.apply:
        manifest_path = Path(args.translations).resolve() if args.translations else default_manifest
        if not manifest_path.exists():
            print(f"Error: {manifest_path} not found", file=sys.stderr)
            sys.exit(1)

        manifest_text = manifest_path.read_text(encoding="utf-8")
        translations = json.loads(manifest_text)
        result = apply_translations(content, translations)

        if args.dry_run:
            import difflib

            original_lines = content.splitlines(keepends=True)
            result_lines = result.splitlines(keepends=True)
            diff = difflib.unified_diff(
                original_lines,
                result_lines,
                fromfile=str(file_path),
                tofile=str(file_path) + " (translated)",
            )
            for line in diff:
                out.write(line.encode("utf-8"))
        else:
            out.write(result.encode("utf-8"))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""One-time migration: add CATEGORY: prefix to existing history.md entries.

Usage:
    uv run bin/migrate-history-categories.py [--apply] [path ...]

Without --apply, prints proposed changes (dry-run).
"""

import io
import re
import sys
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

ALREADY_RE = re.compile(
    r"^### (INCIDENT:|BUGFIX:|FEATURE:|REFACTOR:|CONFIG:|SECURITY:)", re.MULTILINE
)
INCIDENT_OLD_RE = re.compile(r"^### (#\d+:.+)$", re.MULTILINE)
PLAIN_RE = re.compile(r"^### (.+)$", re.MULTILINE)

SECURITY_WORDS = [
    "security", "private info", "dotenv", "check-private-info",
    "scan-outbound", "block japanese", "private email", "email isolation",
    "leak prevention", "remove private email", "git: remove private",
    "enforce doc-append",
]
REFACTOR_WORDS = [
    "→", "rename", "cleanup", "reorganiz", "consolidat",
    "install-obsolete", "unified chronological", "commands → skills",
    "migration cleanup", "claude-code migration", "master → main",
    "history.md japanese translation", "refactor", "removal",
]
CONFIG_WORDS = [
    "command_timeout", "increase command", "token usage", "model pinning",
    "confirmation reduced", "suppress", "quiet-mode", "filter create",
    "timeout to",
]
BUGFIX_PATTERNS = [
    re.compile(r"^fix[\s:]", re.IGNORECASE),
    re.compile(r": fix\b", re.IGNORECASE),
    re.compile(r"\bfix\b.*(false.positive|early.exit|path|crash|missing|reliability)", re.IGNORECASE),
    re.compile(r"(false.positive|early.exit|pipefail.*fix|crash)"),
    re.compile(r"\bfix$", re.IGNORECASE),
    re.compile(r"\bbugfix\b", re.IGNORECASE),
]


def classify(subject: str) -> str:
    # Strip trailing (date, commits) suffix before classifying
    clean = re.sub(r"\s*\([^)]*\)\s*$", "", subject).strip()
    s = clean.lower()
    if any(w in s for w in SECURITY_WORDS):
        return "SECURITY"
    if any(p.search(s) for p in BUGFIX_PATTERNS):
        return "BUGFIX"
    if any(w in subject for w in REFACTOR_WORDS) or any(w in s for w in [
        "rename", "cleanup", "reorganiz", "consolidat", "install-obsolete",
        "unified chronological", "migration cleanup", "master → main",
        "refactor", "removal",
    ]):
        return "REFACTOR"
    if any(w in s for w in CONFIG_WORDS):
        return "CONFIG"
    return "FEATURE"


def migrate_text(text: str) -> tuple[str, list[tuple[str, str]]]:
    changes = []
    lines = text.split("\n")
    out = []
    for line in lines:
        # Already categorized
        if ALREADY_RE.match(line):
            out.append(line)
            continue
        # Old incident: ### #N: Subject ...
        m = re.match(r"^### (#\d+:.+)$", line)
        if m:
            new_line = f"### INCIDENT: {m.group(1)}"
            changes.append((line, new_line))
            out.append(new_line)
            continue
        # Plain entry: ### Subject ...
        m = re.match(r"^### (.+)$", line)
        if m:
            subject = m.group(1)
            cat = classify(subject)
            new_line = f"### {cat}: {subject}"
            changes.append((line, new_line))
            out.append(new_line)
            continue
        out.append(line)
    return "\n".join(out), changes


def process_file(path: Path, apply: bool) -> int:
    text = path.read_text(encoding="utf-8")
    new_text, changes = migrate_text(text)
    if not changes:
        print(f"{path}: no changes needed")
        return 0
    print(f"\n{path}: {len(changes)} change(s)")
    for old, new in changes:
        print(f"  - {old}")
        print(f"  + {new}")
    if apply:
        eol = b"\r\n" if b"\r\n" in path.read_bytes()[:512] else b"\n"
        path.write_bytes(new_text.encode("utf-8").replace(b"\n", eol))
        print(f"  => applied")
    return len(changes)


def main():
    apply = "--apply" in sys.argv
    paths_raw = [a for a in sys.argv[1:] if not a.startswith("--")]

    if paths_raw:
        paths = [Path(p) for p in paths_raw]
    else:
        repo = Path(__file__).parent.parent
        paths = [
            repo / "docs" / "history.md",
            repo / "docs" / "history" / "2026.md",
            repo / "docs" / "history" / "legacy.md",
        ]

    if not apply:
        print("=== DRY RUN (pass --apply to write) ===\n")

    total = 0
    for p in paths:
        if p.exists():
            total += process_file(p, apply)
        else:
            print(f"{p}: not found (skipped)")

    print(f"\nTotal: {total} change(s)")
    if not apply and total:
        print("Run with --apply to write changes.")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
normalize-harness-position.py
Normalize (and optionally add) tests/lib/harness.sh sourcing in test files.

Transformations applied to each file:
  1. Remove single-line pass()/fail()/skip() function defs (harness provides them)
  2. Remove bare PASS=0 / FAIL=0 / SKIP=0 init lines (compound forms too)
  3. Move (or add) `. "...tests/lib/harness.sh"` to the line immediately after
     the last AGENTS_DIR / REPO_ROOT definition
  4. Collapse consecutive blank lines down to one

Usage:
  python3 bin/normalize-harness-position.py [--dry-run] <file> [...]
  python3 bin/normalize-harness-position.py [--dry-run] --all-multi-path
  python3 bin/normalize-harness-position.py [--dry-run] --add-harness <file> [...]
  python3 bin/normalize-harness-position.py [--dry-run] --all-multi-path --add-harness

Flags:
  --dry-run       Show what would change without writing files
  --all-multi-path  Process all tests/ files with 2+ comma-separated # Tests: paths
  --add-harness   Also add harness to files that don't source it yet (NO-HARNESS)

Exit codes: 0=success, 1=errors found
"""

import re
import sys
from pathlib import Path

# Lines to remove — harness provides these
REMOVE_PATTERNS = [
    # single-line function defs: pass() { ... }
    re.compile(r'^pass\s*\(\)\s*\{[^}]*\}\s*$'),
    re.compile(r'^fail\s*\(\)\s*\{[^}]*\}\s*$'),
    re.compile(r'^skip\s*\(\)\s*\{[^}]*\}\s*$'),
    # bare init lines: PASS=0  or  PASS=0; FAIL=0  or  PASS=0; FAIL=0; SKIP=0
    re.compile(r'^PASS=0\s*(;\s*FAIL=0\s*)?(;\s*SKIP=0\s*)?$'),
    re.compile(r'^FAIL=0\s*(;\s*SKIP=0\s*)?$'),
    re.compile(r'^SKIP=0\s*$'),
]

HARNESS_RE = re.compile(r'^\.\s+"[^"]*tests/lib/harness\.sh"')
ROOT_VAR_RE = re.compile(r'^(AGENTS_DIR|REPO_ROOT)=')


def _make_harness_line(lines: list[str]) -> str:
    """Determine the correct harness source line based on root variable used."""
    uses_repo_root = any(ROOT_VAR_RE.match(ln.rstrip()) and 'REPO_ROOT' in ln for ln in lines)
    if uses_repo_root:
        return '. "$REPO_ROOT/tests/lib/harness.sh"\n'
    return '. "$AGENTS_DIR/tests/lib/harness.sh"\n'


def normalize(path: Path, dry_run: bool, add_harness: bool = False) -> str:
    """
    Returns one of:
      'modified'       — file was (or would be) changed
      'already-ok'     — harness is already in the right place, no removals needed
      'no-harness'     — file doesn't source harness.sh (skipped; use --add-harness)
      'no-root-var'    — AGENTS_DIR / REPO_ROOT not found (skip)
      'error:<msg>'    — unexpected problem
    """
    try:
        text = path.read_text(encoding='utf-8')
    except OSError as e:
        return f'error:{e}'

    lines = text.splitlines(keepends=True)

    # Locate harness line
    harness_idx = next(
        (i for i, ln in enumerate(lines) if HARNESS_RE.match(ln.rstrip())),
        None,
    )
    if harness_idx is None:
        if not add_harness:
            return 'no-harness'
        # Will add harness below — treat as if harness_idx = None (handled later)

    # Locate last ROOT variable line
    root_idx = next(
        (i for i in reversed(range(len(lines))) if ROOT_VAR_RE.match(lines[i].rstrip())),
        None,
    )
    if root_idx is None:
        return 'no-root-var'

    harness_line = lines[harness_idx] if harness_idx is not None else _make_harness_line(lines)

    # Detect lines that need removal
    def should_remove(ln: str) -> bool:
        s = ln.rstrip()
        return any(p.match(s) for p in REMOVE_PATTERNS)

    removals_present = any(
        should_remove(ln) for i, ln in enumerate(lines)
        if i != harness_idx
    )

    # Check if harness is already in the correct position:
    # immediately after root_idx (possibly with one blank line between)
    if harness_idx is not None:
        gap = lines[root_idx + 1: harness_idx]
        already_placed = (
            harness_idx == root_idx + 1
            or (harness_idx == root_idx + 2 and gap[0].strip() == '')
        )
        if already_placed and not removals_present:
            return 'already-ok'
    else:
        already_placed = False  # need to add harness

    # Build new file
    new_lines = []
    for i, ln in enumerate(lines):
        if harness_idx is not None and i == harness_idx:
            continue                   # remove from original position
        if should_remove(ln):
            continue                   # drop init/pass/fail lines
        new_lines.append(ln)
        if i == root_idx:
            new_lines.append(harness_line)   # insert right after root var

    # Collapse 2+ consecutive blank lines to 1
    final: list[str] = []
    blank_run = 0
    for ln in new_lines:
        if ln.strip() == '':
            blank_run += 1
            if blank_run == 1:
                final.append(ln)
        else:
            blank_run = 0
            final.append(ln)

    new_text = ''.join(final)
    if new_text == text:
        return 'already-ok'

    if not dry_run:
        path.write_text(new_text, encoding='utf-8')
    return 'modified'


def find_multi_path_files(repo_root: Path) -> list[Path]:
    """Return test files with 2+ comma-separated paths in # Tests:"""
    results = []
    tests_dir = repo_root / 'tests'
    for f in sorted(tests_dir.rglob('*.sh')):
        if '_archive' in f.parts:
            continue
        for ln in f.read_text(encoding='utf-8', errors='replace').splitlines()[:10]:
            if ln.startswith('# Tests:'):
                paths = [p.strip() for p in ln[len('# Tests:'):].split(',')]
                if len(paths) >= 2:
                    results.append(f)
                break
    return results


def main() -> int:
    argv = sys.argv[1:]
    dry_run = '--dry-run' in argv
    all_multi = '--all-multi-path' in argv
    add_harness = '--add-harness' in argv
    files_arg = [a for a in argv if not a.startswith('--')]

    if not files_arg and not all_multi:
        print(__doc__, file=sys.stderr)
        return 1

    if all_multi:
        repo_root = Path(__file__).resolve().parent.parent
        targets = find_multi_path_files(repo_root)
        print(f"Found {len(targets)} multi-path test files")
    else:
        targets = [Path(f) for f in files_arg]

    modified = already_ok = skipped = errors = 0
    for p in targets:
        result = normalize(p, dry_run, add_harness=add_harness)
        tag = 'DRY-RUN' if (dry_run and result == 'modified') else result.upper()
        print(f"{tag}: {p}")
        if result == 'modified':
            modified += 1
        elif result == 'already-ok':
            already_ok += 1
        elif result.startswith('error'):
            errors += 1
        else:
            skipped += 1

    print()
    print(f"modified={modified}  already-ok={already_ok}  skipped={skipped}  errors={errors}")
    if dry_run and modified:
        print("(dry-run: no files written)")
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

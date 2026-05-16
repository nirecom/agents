#!/usr/bin/env python3
"""Update Claude Code session title via custom-title JSONL records.

Usage:
    cc-session-title set-issue <N> "<issue-title>"
    cc-session-title add-pr <N>
    cc-session-title mark-complete
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

# Requires "#<digits><whitespace>" prefix or leading "✓".
# Rejects "# notes", "#hashtag", "#299" (no space) — those are user-set titles.
WORKFLOW_TITLE_RE = re.compile(r'^(#\d+\s|✓)')


def encode_cwd(path: str) -> str:
    # Mirrors hooks/lib/workflow-state.js:153:
    #   ctx.cwd.toLowerCase().replace(/[^a-zA-Z0-9]/g, "-")
    return re.sub(r'[^a-zA-Z0-9]', '-', path.lower())


def latest_custom_title(jsonl_text: str) -> str | None:
    last = None
    for line in jsonl_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get('type') == 'custom-title':
            ct = rec.get('customTitle')
            if isinstance(ct, str):
                last = ct
    return last


def is_workflow_generated(title: str | None) -> bool:
    if title is None:
        return True
    return bool(WORKFLOW_TITLE_RE.match(title))


def build_record(session_id: str, title: str) -> str:
    rec = {"type": "custom-title", "sessionId": session_id, "customTitle": title}
    return json.dumps(rec, ensure_ascii=False) + "\n"


def format_set_issue_title(n: int, issue_title: str) -> str:
    return f"#{n} {issue_title.strip()}"


# End-anchored: only a PR-list at the tail of the title counts as "already appended".
# Prevents PR-references embedded in the issue title body from corrupting detection.
PR_SUFFIX_RE = re.compile(r'( PR #\d+(?:, PR #\d+)*)$')


def format_add_pr_title(current_title: str | None, n: int) -> str | None:
    if current_title is None or not is_workflow_generated(current_title):
        return None
    suffix_match = PR_SUFFIX_RE.search(current_title)
    if suffix_match:
        suffix = suffix_match.group(1)
        if re.search(rf'PR #{n}(?!\d)', suffix):
            return None
        return f"{current_title}, PR #{n}"
    return f"{current_title} PR #{n}"


COMPLETE_MARKER = '✓'


def format_mark_complete_title(current_title: str | None) -> str | None:
    if current_title is None:
        return None
    if current_title.startswith(COMPLETE_MARKER):
        return None
    if not is_workflow_generated(current_title):
        return None
    return f"{COMPLETE_MARKER}{current_title}"


def _projects_dir() -> Path:
    override = os.environ.get('CLAUDE_PROJECTS_DIR')
    if override:
        return Path(override)
    return Path.home() / '.claude' / 'projects'


def _find_current_jsonl(cwd: str) -> Path | None:
    # CLAUDE_SESSION_ID is not propagated to Bash subprocesses (Anthropic bug #27987).
    # Use mtime-based discovery instead — consistent with workflow-state.js findLatestStateForContext().
    project_dir = _projects_dir() / encode_cwd(cwd)
    try:
        files = list(project_dir.glob('*.jsonl'))
    except OSError:
        return None
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_mtime)


def run_set_issue(n: int, issue_title: str, cwd: str) -> int:
    path = _find_current_jsonl(cwd)
    if path is None:
        print('cc-session-title: no JSONL found in project dir; skipping', file=sys.stderr)
        return 0
    session_id = path.stem
    existing = path.read_text(encoding='utf-8', errors='replace')
    current = latest_custom_title(existing)
    if not is_workflow_generated(current):
        return 0
    new_title = format_set_issue_title(n, issue_title)
    record = build_record(session_id, new_title)
    with open(path, 'a', encoding='utf-8', newline='') as f:
        f.write(record)
    return 0


def run_add_pr(n: int, cwd: str) -> int:
    path = _find_current_jsonl(cwd)
    if path is None:
        print('cc-session-title: no JSONL found in project dir; skipping', file=sys.stderr)
        return 0
    session_id = path.stem
    existing = path.read_text(encoding='utf-8', errors='replace')
    current = latest_custom_title(existing)
    new_title = format_add_pr_title(current, n)
    if new_title is None:
        return 0
    record = build_record(session_id, new_title)
    with open(path, 'a', encoding='utf-8', newline='') as f:
        f.write(record)
    return 0


def run_mark_complete(cwd: str) -> int:
    path = _find_current_jsonl(cwd)
    if path is None:
        print('cc-session-title: no JSONL found in project dir; skipping', file=sys.stderr)
        return 0
    session_id = path.stem
    existing = path.read_text(encoding='utf-8', errors='replace')
    current = latest_custom_title(existing)
    new_title = format_mark_complete_title(current)
    if new_title is None:
        return 0
    record = build_record(session_id, new_title)
    with open(path, 'a', encoding='utf-8', newline='') as f:
        f.write(record)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog='cc-session-title')
    sub = parser.add_subparsers(dest='cmd', required=True)
    p_set = sub.add_parser('set-issue')
    p_set.add_argument('number', type=int)
    p_set.add_argument('title')
    sub.add_parser('add-pr').add_argument('number', type=int)
    sub.add_parser('mark-complete')
    args = parser.parse_args(argv)
    cwd = os.getcwd()
    if args.cmd == 'set-issue':
        return run_set_issue(args.number, args.title, cwd)
    if args.cmd == 'add-pr':
        return run_add_pr(args.number, cwd)
    if args.cmd == 'mark-complete':
        return run_mark_complete(cwd)
    return 1


if __name__ == '__main__':
    sys.exit(main())

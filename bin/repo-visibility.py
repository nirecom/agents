#!/usr/bin/env python3
"""Report whether the current (or given) git repository is public or private."""
import os
import re
import subprocess
import sys


def normalize_path(path: str) -> str:
    """Normalize path for the current platform."""
    if sys.platform == "win32":
        # WSL path (/mnt/<drive>/...) → Windows path
        m = re.match(r"^/mnt/([a-zA-Z])/(.*)$", path)
        if m:
            drive = m.group(1).upper()
            rest = m.group(2).replace("/", "\\")
            return f"{drive}:\\{rest}"
        return path
    else:
        # Windows path (X:\... or X:/...) → WSL path (/mnt/<drive>/...)
        m = re.match(r"^([A-Za-z])[:\\/](.*)$", path)
        if m:
            drive = m.group(1).lower()
            rest = m.group(2).replace("\\", "/")
            return f"/mnt/{drive}/{rest}"
        return path.replace("\\", "/")


def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else "."
    cwd = os.path.abspath(normalize_path(path))

    try:
        result = subprocess.run(
            ["gh", "repo", "view", "--json", "visibility", "-q", ".visibility"],
            cwd=cwd,
            capture_output=True,
            text=True,
            check=True,
        )
        print(result.stdout.strip().lower())
    except subprocess.CalledProcessError as e:
        print(f"error: {e.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("error: gh not found — install GitHub CLI (gh)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

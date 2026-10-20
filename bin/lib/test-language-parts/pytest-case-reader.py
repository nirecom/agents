"""bin/lib/test-language-parts/pytest-case-reader.py <file> — the pytest entry's case reader child.

Parses the file with `ast` (never imports or runs it) and reports each module-level `test_*`
function or `Test*` class carrying `@pytest.mark.target("<path>")`. Prints
  FILE\\t<state>\\t<line>\\t<reason>   and, when conforming, one
  CASE\\t<name>\\t<target>\\t<begin>\\t<end>\\t\\t   per case, in file order
(begin = the first decorator line, end = the last body line). Exit 1: unreadable file.
The case enumeration lives in pytest_case_scan.py, shared with pytest-case-analyzer.py.
Keeps to Python 3.8, like the pytest wrapper: `uv run` picks the interpreter.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

from pytest_case_scan import read_cases


def main(path: str) -> int:
    try:
        source = Path(path).read_bytes()
    except OSError as err:
        print(f"pytest-case-reader: cannot read {path}: {err.strerror}", file=sys.stderr)
        return 1
    try:
        faults, cases = read_cases(ast.parse(source))
    except SyntaxError as err:
        faults, cases = [(err.lineno or 1, "grammar")], []
    except ValueError:
        faults, cases = [(1, "grammar")], []
    if faults:
        line, reason = min(faults)
        rows = [["FILE", "malformed", line, reason]]
    else:
        rows = [["FILE", "conforming" if cases else "none", "", ""]]
        rows += [["CASE", *case, "", ""] for case in cases]
    text = "".join("\t".join(str(col) for col in row) + "\n" for row in rows)
    sys.stdout.buffer.write(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

"""bin/lib/test-language-parts/pytest-case-analyzer.py <op> <file> [args] — the pytest entry's
caseEmbedRules analyzer child.

Parses the file with `ast` (never imports or runs it), enumerates the cases with
pytest_case_scan.py (the test case reader's own code) and prints:
  deps           ORDER\\t<idx>\\t<begin>\\t<end> per case, then <idx>\\t<csv> per case
  leftover-defs  <line>\\t<name> per module-level function no other code names
  self-impl <helper>  <line>\\t<kind>\\t<detail> per module-level counter-init / harness-redef
  skip-reason    parametrized-case when a test uses @pytest.mark.parametrize; else nothing
  syntax-check   nothing; exit 0 when the file parses, 1 with the reason on stderr otherwise
  case-count     the number of module-level cases (is_case); exit 1 when there is none
Exit 1: unreadable, a syntax error, not conforming (deps) or no unit (case-count); 2: unknown op.
Keeps to Python 3.8, like the pytest wrapper: `uv run` picks the interpreter.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

from pytest_case_scan import DEFINITIONS, is_case, scan_cases

ASSIGNMENTS = (ast.Assign, ast.AnnAssign, ast.AugAssign)
FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)
COUNTERS = ("PASS", "FAIL", "passed", "failed")


class NotConforming(Exception):
    """The file has no well-formed cases to answer for."""


def top_definitions(tree: ast.Module) -> list[tuple[str, int, bool]]:
    """Module-level (name, line, is_function) of every def, class and assigned name but the cases."""
    found: list[tuple[str, int, bool]] = []
    for node in tree.body:
        if isinstance(node, DEFINITIONS) and not is_case(node):
            found.append((node.name, node.lineno, not isinstance(node, ast.ClassDef)))
        elif isinstance(node, ASSIGNMENTS):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            found.extend((t.id, node.lineno, False) for t in targets if isinstance(t, ast.Name))
    return found


def used_names(node: ast.AST) -> set[str]:
    """The names a node reads, with the argument names of every function in it (pytest fixtures)."""
    names = {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}
    for fn in ast.walk(node):
        if isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            a = fn.args
            names.update(x.arg for x in [*a.posonlyargs, *a.args, *a.kwonlyargs])
    return names


def deps(tree: ast.Module) -> list[str]:
    faults, cases = scan_cases(tree)
    if faults or not cases:
        raise NotConforming("the file is not conforming")
    defs = top_definitions(tree)
    rows = [f"ORDER\t{i}\t{row[2]}\t{row[3]}" for i, (_, row) in enumerate(cases)]
    for i, (node, _) in enumerate(cases):
        used = used_names(node)
        picked: list[str] = []
        for name, _, _ in defs:
            if name in used and name not in picked:
                picked.append(name)
        rows.append(f"{i}\t{','.join(picked)}")
    return rows


def leftover_defs(tree: ast.Module) -> list[str]:
    defs = top_definitions(tree)
    rows = []
    for name, line, is_function in defs:
        if not is_function:
            continue
        own = next(n for n in tree.body if isinstance(n, DEFINITIONS) and n.name == name and n.lineno == line)
        others = [n for n in tree.body if n is not own]
        if not any(name in used_names(n) for n in others) and name not in used_names_inside(own):
            rows.append(f"{line}\t{name}")
    return rows


def used_names_inside(node: ast.AST) -> set[str]:
    """The names a definition's own body reads (a recursive call names the function)."""
    body = getattr(node, "body", [])
    return set().union(*(used_names(n) for n in body)) if body else set()


def helper_names(helper: str) -> set[str]:
    """The helper library's module-level function names; none when it is unreadable."""
    try:
        tree = ast.parse(Path(helper).read_bytes()) if helper else None
    except (OSError, SyntaxError, ValueError):
        tree = None
    return {n.name for n in tree.body if isinstance(n, FUNCTIONS)} if tree else set()


def is_zero(node: ast.AST) -> bool:
    return isinstance(node, ast.Constant) and type(node.value) is int and node.value == 0


def self_impl(tree: ast.Module, args: list[str]) -> list[str]:
    own = helper_names(args[0] if args else "")
    rows: list[tuple[int, str]] = []
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and is_zero(node.value):
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in COUNTERS:
                rows.append((node.lineno, f"{node.lineno}\tcounter-init\t{target.id}=0"))
        elif isinstance(node, FUNCTIONS) and node.name in own:
            rows.append((node.lineno, f"{node.lineno}\tharness-redef\t{node.name}"))
    return [text for _, text in sorted(rows)]


def is_parametrize(node: ast.AST) -> bool:
    """A `pytest.mark.parametrize` / `mark.parametrize` decorator, called or not."""
    target = node.func if isinstance(node, ast.Call) else node
    return (
        isinstance(target, ast.Attribute)
        and target.attr == "parametrize"
        and isinstance(target.value, ast.Attribute)
        and target.value.attr == "mark"
    )


def skip_reason(tree: ast.Module) -> list[str]:
    """parametrized-case: one function stands for several cases, so a case cannot be cut alone."""
    for node in ast.walk(tree):
        if isinstance(node, DEFINITIONS) and any(is_parametrize(d) for d in node.decorator_list):
            return ["parametrized-case"]
    return []


def case_count(tree: ast.Module) -> list[str]:
    """The module-level test_* functions and Test* classes; a class is one unit."""
    count = sum(1 for node in tree.body if is_case(node))
    if count == 0:
        raise NotConforming("no case unit")
    return [str(count)]


OPS = {
    "case-count": lambda tree, args: case_count(tree),
    "deps": lambda tree, args: deps(tree),
    "leftover-defs": lambda tree, args: leftover_defs(tree),
    "self-impl": self_impl,
    "skip-reason": lambda tree, args: skip_reason(tree),
    # main() parses the file before any op; a parse failure exits 1 with the reason.
    "syntax-check": lambda tree, args: [],
}


def main(argv: list[str]) -> int:
    op = argv[0] if argv else ""
    if op not in OPS:
        print(f"[pytest-case-analyzer] unknown op: {op}", file=sys.stderr)
        return 2
    path = argv[1] if len(argv) > 1 else ""
    try:
        source = Path(path).read_bytes()
    except OSError as err:
        print(f"pytest-case-analyzer: cannot read {path}: {err.strerror}", file=sys.stderr)
        return 1
    try:
        rows = OPS[op](ast.parse(source), argv[2:])
    except (SyntaxError, ValueError, NotConforming) as err:
        print(f"pytest-case-analyzer: {op} {path}: {err}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write("".join(f"{row}\n" for row in rows).encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

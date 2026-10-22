"""bin/lib/test-language-parts/pytest-case-analyzer.py <op> <file> [args] — the pytest entry's
caseEmbedRules analyzer child.

Parses the file with `ast` (never imports or runs it), enumerates the cases with
pytest_case_scan.py (the test case reader's own code) and prints:
  deps           ORDER\\t<idx>\\t<begin>\\t<end> per case, then <idx>\\t<csv> per case
  leftover-defs  <line>\\t<name> per module-level function no other code names, except the
                 ones pytest calls itself: a fixture (@pytest.fixture, its `import pytest as X`
                 alias @X.fixture, or @fixture), a pytest_* hook
                 or an xunit setup_module / teardown_module / setup_function / teardown_function
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
XUNIT_FUNCTIONS = ("setup_module", "teardown_module", "setup_function", "teardown_function")


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
    modules = pytest_modules(tree)
    rows = []
    for name, line, is_function in defs:
        if not is_function:
            continue
        own = next(n for n in tree.body if isinstance(n, DEFINITIONS) and n.name == name and n.lineno == line)
        if is_pytest_called(own, modules):
            continue
        others = [n for n in tree.body if n is not own]
        if not any(name in used_names(n) for n in others) and name not in used_names_inside(own):
            rows.append(f"{line}\t{name}")
    return rows


def pytest_modules(tree: ast.Module) -> set[str]:
    """The names the pytest module goes by in the file: `pytest` plus every `import pytest as X` alias."""
    return {"pytest"} | {
        alias.asname
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
        if alias.name == "pytest" and alias.asname
    }


def is_fixture(node: ast.AST, modules: set[str]) -> bool:
    """A `<pytest module>.fixture` (`pytest` or an alias in modules) or bare `fixture` decorator, called or not."""
    target = node.func if isinstance(node, ast.Call) else node
    if isinstance(target, ast.Attribute):
        return target.attr == "fixture" and isinstance(target.value, ast.Name) and target.value.id in modules
    return isinstance(target, ast.Name) and target.id == "fixture"


def is_pytest_called(node: ast.AST, modules: set[str]) -> bool:
    """pytest calls a fixture, a pytest_* hook or an xunit setup/teardown itself, with no name reference."""
    return node.name.startswith("pytest_") or node.name in XUNIT_FUNCTIONS or any(is_fixture(d, modules) for d in node.decorator_list)


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
    """A `<x>.mark.parametrize` or bare `mark.parametrize` (`from pytest import mark`) decorator, called or not."""
    target = node.func if isinstance(node, ast.Call) else node
    if not (isinstance(target, ast.Attribute) and target.attr == "parametrize"):
        return False
    mark = target.value
    return (isinstance(mark, ast.Attribute) and mark.attr == "mark") or (isinstance(mark, ast.Name) and mark.id == "mark")


def skip_reason(tree: ast.Module) -> list[str]:
    """parametrized-case: one function stands for several cases, so a case cannot be cut alone.

    Only a test case's parametrize counts: a module-level case (is_case) or a test_* method of a
    Test* class; a parametrized helper or nested function leaves every case cuttable.
    """
    for node in tree.body:
        if not is_case(node):
            continue
        methods = [m for m in node.body if isinstance(m, FUNCTIONS) and is_case(m)] if isinstance(node, ast.ClassDef) else []
        if any(is_parametrize(d) for case in [node, *methods] for d in case.decorator_list):
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

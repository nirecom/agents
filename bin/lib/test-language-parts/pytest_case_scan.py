"""bin/lib/test-language-parts/pytest_case_scan.py — the pytest case enumeration, shared by
pytest-case-reader.py and pytest-case-analyzer.py so both see one case order.

A case is a module-level `test_*` function or `Test*` class carrying `@pytest.mark.target("<path>")`.
Keeps to Python 3.8, like the pytest wrapper: `uv run` picks the interpreter.
"""

from __future__ import annotations

import ast
import re

# The "Case target path rule" section of docs/architecture/claude-code/test-language-registry.md owns TARGET_OK.
TARGET_OK = re.compile(r"[A-Za-z0-9._/-]+")
RECORD_DELIMITER = re.compile(r"[\t\r\n]")
DEFINITIONS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


def is_target_mark(decorator: ast.expr) -> bool:
    node = decorator.func if isinstance(decorator, ast.Call) else decorator
    return (
        isinstance(node, ast.Attribute)
        and node.attr == "target"
        and isinstance(node.value, ast.Attribute)
        and node.value.attr == "mark"
        and isinstance(node.value.value, ast.Name)
        and node.value.value.id == "pytest"
    )


def target_marks(node: ast.AST) -> list[ast.expr]:
    return [d for d in getattr(node, "decorator_list", []) if is_target_mark(d)]


def is_case(node: ast.stmt) -> bool:
    if isinstance(node, ast.ClassDef):
        return node.name.startswith("Test")
    return isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_")


def constant_target(mark: ast.expr) -> str | None:
    if not isinstance(mark, ast.Call) or len(mark.args) != 1 or mark.keywords:
        return None
    arg = mark.args[0]
    return arg.value if isinstance(arg, ast.Constant) and isinstance(arg.value, str) else None


def target_is_valid(target: str) -> bool:
    if not TARGET_OK.fullmatch(target) or target.startswith("/"):
        return False
    parts = target.split("/")
    return parts[0] != "." and ".." not in parts


def scan_cases(tree: ast.Module) -> tuple[list[tuple[int, str]], list[tuple[ast.stmt, list[object]]]]:
    """Every (line, reason) fault and every well-formed case as (node, [name, target, begin, end])."""
    faults: list[tuple[int, str]] = []
    cases: list[tuple[ast.stmt, list[object]]] = []
    unmarked: list[int] = []
    top = [node for node in tree.body if is_case(node)]
    for node in ast.walk(tree):
        if isinstance(node, DEFINITIONS) and not any(node is case for case in top):
            faults.extend((mark.lineno, "nested-target") for mark in target_marks(node))
    for node in top:
        begin = min([node.lineno, *(d.lineno for d in node.decorator_list)])
        marks = target_marks(node)
        if not marks:
            unmarked.append(begin)
        elif len(marks) > 1:
            faults.append((marks[1].lineno, "duplicate-target"))
        elif (target := constant_target(marks[0])) is None:
            faults.append((marks[0].lineno, "constant"))
        elif RECORD_DELIMITER.search(target):
            # A TAB, CR or LF would split the record line, so it reads grammar ahead of the target rule.
            faults.append((marks[0].lineno, "grammar"))
        elif not target_is_valid(target):
            faults.append((marks[0].lineno, "target"))
        else:
            cases.append((node, [node.name, target, begin, node.end_lineno]))
    if len(unmarked) < len(top):
        faults.extend((line, "missing-target") for line in unmarked)
    return faults, cases


def read_cases(tree: ast.Module) -> tuple[list[tuple[int, str]], list[list[object]]]:
    """Every (line, reason) fault and every well-formed case of the module."""
    faults, cases = scan_cases(tree)
    return faults, [row for _, row in cases]

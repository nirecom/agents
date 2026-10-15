> Notation file of `skills/_shared/test-design/case-markers.md` (common rules there). Read it when writing or editing a `test_*.py` test.

# Case markers in pytest tests

## Helper library

- Path line: `sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))`.
- Load line: `import harness` (or `from harness import <name>`), on a line of its own after the path line.
- Place both at module top, before the first `@pytest.mark.target`.
- Importing the helper library registers the `target` mark, so no unknown-mark warning appears.
- Call `harness.require_tl3()` as the first statement of a test that needs the real environment.
- Write a known failure as `@pytest.mark.xfail(strict=True)`; the helper library adds no wrapper for it.

## Notation

- A case is a module-level `test_*` function (sync or async) or a module-level `Test*` class.
- Decorate every case with `@pytest.mark.target("<path>")`, spelled with the `pytest.` prefix.
- Pass exactly one positional string literal and no keyword argument.
- Never put the mark on a method, a nested function, a fixture, or a helper.
- The case name is the function or class name; the range runs from the first decorator line to the last body line.
- The reader parses the file and never runs it, so a `pytestmark` variable or a mark added at run time is not seen.

## Malformed reasons

| Reason | Cause |
|---|---|
| `grammar` | The file does not parse |
| `constant` | A mark that is not a call with one string literal |
| `duplicate-target` | Two target marks on one case |
| `target` | A target that breaks the common path rule |
| `missing-target` | A module-level case without the mark beside one that has it |
| `nested-target` | The mark below module level or on a definition that is not a case |

- A machine without `uv` gets `CASE_MARKER_RUNTIME_UNAVAILABLE` (WARN): the markers are not checked there.

## Examples

Correct — after the path line and `import harness  # noqa: E402` at module top:

- `@pytest.mark.target("bin/normalize-harness-position.py")` at column 0.
- `def test_missing_header_blocks():` on the next line.
- A body such as `assert run_tool(FIXTURE) == 1`.

Incorrect (mark on a method — `nested-target`): the same mark on `def test_missing_header_blocks(self): ...` indented inside `class TestHeader:`.

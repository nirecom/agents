---
globs: "**/*.py,**/pyproject.toml,**/uv.lock,**/requirements.txt,**/setup.py,**/setup.cfg"
---

## Python

- Do not use bare `python`, `pip`, or `python3` commands. Always use `uv` (`uv run`, `uv pip`, etc.).
- For one-off scripts: `uv run script.py`
- For adding dependencies: `uv pip install` or `uv add`

### Review-relevant invariants (already followed in this repo)

- PEP 8 naming: `snake_case` for functions/variables, `PascalCase` for classes, `UPPER_SNAKE_CASE` for module-level constants.
- `except` clauses must name a specific exception type; bare `except:` is discouraged (top-level boundary handlers are exempt).
- Modern type-hint syntax: `list[int]`, `X | None` — not `List[int]`, `Optional[X]`.
- Mutable default arguments are forbidden; use `None` and assign inside the function body.
- No star imports (`from module import *`).
- f-strings preferred over `%-format` / `.format()`.
- `pathlib.Path` over `os.path` for filesystem operations.
- Docstrings on public callables: encouraged, not mandatory.
